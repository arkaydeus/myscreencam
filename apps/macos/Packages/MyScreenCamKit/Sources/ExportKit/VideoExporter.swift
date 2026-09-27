import AVFoundation
import MyScreenCamCore

/// Starts exports.
///
/// ```swift
/// let settings = ExportPreset.web.settings
/// let size = settings.outputSize(forSource: recordingSize)
/// let (composition, videoComposition, audioMix) = renderer.makeExport(renderSize: size, ...)
/// let job = VideoExporter().start(
///     asset: composition, videoComposition: videoComposition, audioMix: audioMix,
///     to: url, settings: settings)
/// Task { for await p in job.progress { bar.update(p.fraction, p.stageText) } }
/// let result = try await job.result
/// ```
///
/// **What the caller guarantees**
/// - `videoComposition.renderSize` is exactly `settings.outputSize(forSource:)` (positive, whole and
///   **even** on both sides). Anything else fails up front with `ExportError.invalidRenderSize`,
///   before any file is created.
/// - A custom compositor supports `settings.format.compositorPixelFormat` as its render-context pixel
///   format (`420v` H.264/HEVC, `x420` HEVC 10-bit, `x422` ProRes, `BGRA` GIF), IOSurface-backed.
/// - The composition's instructions cover the asset's whole duration.
/// - The asset, composition and audio mix aren't mutated while the export runs.
///
/// On a copy of the composition, ExportKit sets `frameDuration` to the export frame rate and the colour
/// properties to BT.709, which is what the file is tagged with. Without a video composition, the first
/// video track is scaled to `outputSize(forSource:)`.
public struct VideoExporter: Sendable {
    public struct Options: Sendable, Hashable {
        /// Abandon the export with `ExportError.stalled` if no frame is appended for this long.
        public var stallTimeout: Duration
        /// The minimum spacing of progress updates.
        public var progressInterval: Duration

        public init(stallTimeout: Duration = .seconds(30), progressInterval: Duration = .milliseconds(100)) {
            self.stallTimeout = stallTimeout
            self.progressInterval = progressInterval
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Starts exporting `asset` to `url` and returns immediately.
    ///
    /// The file is written next to `url` under a hidden temporary name and moved into place only when
    /// complete, replacing any existing file. A cancelled or failed export leaves nothing behind (and
    /// an existing file at `url` untouched).
    ///
    /// - Parameters:
    ///   - asset: usually the renderer's `AVComposition`.
    ///   - videoComposition: how frames are rendered; `nil` scales the first video track.
    ///   - audioMix: volume ramps etc. for the audio tracks; `nil` mixes them at unity gain.
    ///   - url: the destination file. Its directory is created if missing.
    ///   - settings: what to encode. Validated when the job starts.
    public func start(
        asset: AVAsset,
        videoComposition: AVVideoComposition? = nil,
        audioMix: AVAudioMix? = nil,
        to url: URL,
        settings: ExportSettings
    ) -> ExportJob {
        ExportJob(
            asset: asset, videoComposition: videoComposition, audioMix: audioMix,
            url: url, settings: settings, options: options)
    }
}

/// A running export: observe ``progress``, ``cancel()`` it, await its ``result``.
public final class ExportJob: Sendable, Identifiable {
    public let id = UUID()
    /// The destination passed to `start`.
    public let outputURL: URL
    public let settings: ExportSettings
    /// Progress snapshots: throttled to ~10 Hz, `fraction` never decreases, and it always ends with a
    /// `.finished` 1.0 value on success. The stream finishes when the job ends (success, failure or
    /// cancellation). Single consumer; late subscribers get the most recent value first.
    public let progress: AsyncStream<ExportProgress>

    private let control: ExportControl
    private let reporter: ProgressReporter
    private let task: Task<Result<ExportResult, ExportError>, Never>

    init(
        asset: AVAsset,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        url: URL,
        settings: ExportSettings,
        options: VideoExporter.Options
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ExportProgress.self, bufferingPolicy: .bufferingNewest(1))
        let control = ExportControl()
        let reporter = ProgressReporter(continuation: continuation, interval: options.progressInterval)
        self.outputURL = url
        self.settings = settings
        self.progress = stream
        self.control = control
        self.reporter = reporter
        let assetBox = UncheckedBox(asset)
        let audioMixBox = UncheckedBox(audioMix)
        task = Task.detached(priority: .userInitiated) {
            let result = await Self.run(
                asset: assetBox.value, videoComposition: videoComposition, audioMix: audioMixBox.value,
                url: url, settings: settings, options: options, control: control, reporter: reporter)
            if case .failure(let error) = result {
                reporter.close()
                Log.app.error("Export to \(url.lastPathComponent, privacy: .public) failed: \(error, privacy: .public)")
            }
            return result
        }
    }

    /// The latest progress snapshot, for callers that don't consume the stream.
    public var latestProgress: ExportProgress { reporter.latest }

    public var isCancelled: Bool { control.isCancelled }

    /// Cancels the export. Reading and writing stop, the partial file is deleted, and ``result``
    /// throws `ExportError.cancelled`. Safe to call from any thread, any number of times.
    public func cancel() {
        control.cancel()
    }

    /// The completed export, or the error that ended it.
    ///
    /// Cancelling the awaiting task cancels the export.
    public var result: ExportResult {
        get async throws(ExportError) {
            let outcome = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                control.cancel()
            }
            return try outcome.get()
        }
    }

    private static func run(
        asset: AVAsset,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        url: URL,
        settings: ExportSettings,
        options: VideoExporter.Options,
        control: ExportControl,
        reporter: ProgressReporter
    ) async -> Result<ExportResult, ExportError> {
        do throws(ExportError) {
            try settings.validate()
            try control.checkCancelled()
            let source = try await ExportSource.load(
                asset: asset, videoComposition: videoComposition, settings: settings)
            try control.checkCancelled()
            let output = OutputFile(finalURL: url)
            if settings.format.isGIF {
                let session = GIFExportSession(
                    source: source, settings: settings, output: output, control: control,
                    reporter: reporter, options: options)
                return .success(try await session.run())
            } else {
                let session = MovieExportSession(
                    source: source, audioMix: audioMix, settings: settings, output: output,
                    control: control, reporter: reporter, options: options)
                return .success(try await session.run())
            }
        } catch {
            return .failure(error)
        }
    }
}
