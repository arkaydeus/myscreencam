import AVFoundation
import CaptureKit
import MyScreenCamCore
import ProjectKit

/// Writes one stream file (`screen.mov`, `webcam.mov`, `sysaudio.m4a` or `mic.m4a`) with its own
/// `AVAssetWriter` on its own serial queue (QoS `.userInitiated`).
///
/// Capture buffers are appended **as-is**: video pixel buffers are IOSurfaces handed straight to VideoToolbox,
/// audio PCM goes to the AAC encoder. The only transformation is a timing-only copy after a pause
/// (`CMSampleBufferCreateCopyWithNewTiming`, which shares the media data). If the encoder can't keep up the
/// buffer is dropped and counted; capture is never blocked.
///
/// Files are fragmented (`movieFragmentInterval` 2 s), so a crash leaves a playable file.
final class StreamWriter: @unchecked Sendable {
    struct Statistics: Sendable, Equatable {
        var appended = 0
        /// Encoder not ready (`isReadyForMoreMediaData == false`).
        var droppedNotReady = 0
        /// Timestamp not after the previous one.
        var droppedOutOfOrder = 0
        /// Arrived after the writer failed.
        var droppedAfterFailure = 0

        var dropped: Int { droppedNotReady + droppedOutOfOrder + droppedAfterFailure }
    }

    struct Result: Sendable {
        let kind: StreamKind
        /// Session time of the file's first sample; nil if nothing was written (no file).
        let startOffset: Double?
        let statistics: Statistics
        let error: String?
    }

    let kind: StreamKind
    let url: URL
    private let fileType: AVFileType
    private let queue: DispatchQueue
    private let onFailure: @Sendable (StreamKind, String) -> Void
    private let videoSettings: [String: Any]?
    private let lock = NSLock()
    private var stats = Statistics()

    // Confined to `queue`.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstSessionTime: Double?
    private var hasAppended = false
    private var sessionStarted = false
    private var lastPresentationTime = CMTime.negativeInfinity
    private var failure: String?

    /// - Parameters:
    ///   - videoSettings: output settings for a video stream (the writer is created up front by ``prepare()``).
    ///     Nil for audio: AAC settings are derived from the first buffer's format.
    init(
        kind: StreamKind, url: URL, videoSettings: [String: Any]?,
        onFailure: @escaping @Sendable (StreamKind, String) -> Void
    ) {
        self.kind = kind
        self.url = url
        self.videoSettings = videoSettings
        self.fileType = videoSettings == nil ? .m4a : .mov
        self.onFailure = onFailure
        self.queue = DispatchQueue(label: "com.myscreencam.recording.writer.\(kind.rawValue)", qos: .userInitiated)
    }

    var statistics: Statistics { lock.withLock { stats } }

    /// Creates the writer and starts writing, so the first frame doesn't pay for encoder set-up.
    /// Only for video streams (audio writers start on their first buffer).
    func prepare() throws {
        guard let videoSettings else { return }
        try queue.sync { try makeWriter(settings: videoSettings, mediaType: .video, formatHint: nil) }
    }

    /// Queues a capture buffer. Returns immediately.
    func append(_ buffer: CMSampleBuffer, placement: SessionClock.Placement) {
        let transfer = UncheckedSendable(buffer)
        queue.async { [self] in write(transfer.value, placement: placement) }
    }

    /// Finishes the file. `endFileTime` (session end on the file's time base) extends the last video frame to
    /// the stop time, so a static screen still lasts the whole recording.
    func finish(endFileTime: CMTime?) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finishOnQueue(endFileTime: endFileTime) { continuation.resume(returning: $0) }
            }
        }
    }

    // MARK: - Queue-confined

    private func write(_ buffer: CMSampleBuffer, placement: SessionClock.Placement) {
        guard failure == nil else {
            count { $0.droppedAfterFailure += 1 }
            return
        }
        guard let format = buffer.formatDescription,
            CMFormatDescriptionGetMediaType(format) == (videoSettings == nil ? kCMMediaType_Audio : kCMMediaType_Video)
        else {
            fail("Unexpected sample media type")
            return
        }
        do {
            if writer == nil {
                let channels = format.audioStreamBasicDescription.map { Int($0.mChannelsPerFrame) } ?? 2
                try makeWriter(
                    settings: EncoderSettings.aac(sourceChannels: channels), mediaType: .audio, formatHint: format)
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard let writer, let input else { return }

        let sample =
            placement.shift == 0 ? buffer : (buffer.shifted(by: HostClock.time(seconds: placement.shift)) ?? buffer)
        let time = sample.presentationTimeStamp
        guard time > lastPresentationTime else {
            count { $0.droppedOutOfOrder += 1 }
            return
        }
        guard input.isReadyForMoreMediaData else {
            count { $0.droppedNotReady += 1 }
            return
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        let signpost = Log.signposter.beginInterval(
            "append", id: Log.signposter.makeSignpostID(), "\(self.kind.rawValue)")
        let appended = input.append(sample)
        Log.signposter.endInterval("append", signpost)
        if appended {
            hasAppended = true
            if firstSessionTime == nil { firstSessionTime = placement.sessionTime }
            lastPresentationTime = time
            count { $0.appended += 1 }
        } else {
            fail(writer.error?.localizedDescription ?? "append failed (status \(writer.status.rawValue))")
        }
    }

    private func makeWriter(settings: [String: Any], mediaType: AVMediaType, formatHint: CMFormatDescription?) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.movieFragmentInterval = CMTime(value: 2, timescale: 1)
        let settings = mediaType == .video ? EncoderSettings.validated(settings, for: writer) : settings
        guard writer.canApply(outputSettings: settings, forMediaType: mediaType) else {
            throw RecordingError.writerFailed(kind, "unsupported output settings")
        }
        let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings, sourceFormatHint: formatHint)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writerFailed(kind, "can't add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecordingError.writerFailed(kind, writer.error?.localizedDescription ?? "can't start writing")
        }
        self.writer = writer
        self.input = input
    }

    private func finishOnQueue(endFileTime: CMTime?, completion: @escaping @Sendable (Result) -> Void) {
        let kind = kind
        guard let writer, let input, hasAppended else {
            // No samples were appended, so this file cannot be salvaged.
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(Result(kind: kind, startOffset: nil, statistics: statistics, error: failure))
            return
        }
        guard writer.status == .writing else {
            // A fragmented file may already contain playable samples. Keep it for recovery.
            completion(
                Result(
                    kind: kind, startOffset: nil, statistics: statistics,
                    error: failure ?? writer.error?.localizedDescription ?? "Writer failed"))
            return
        }
        if let endFileTime {
            writer.endSession(atSourceTime: CMTimeMaximum(endFileTime, lastPresentationTime))
        }
        input.markAsFinished()
        let startOffset = firstSessionTime
        let transfer = UncheckedSendable(writer)
        writer.finishWriting { [self] in
            let writer = transfer.value
            let error =
                failure ?? (writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "finish failed"))
            completion(
                Result(
                    kind: kind, startOffset: error == nil ? startOffset : nil, statistics: statistics,
                    error: error))
        }
    }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        Log.app.error("\(self.kind.rawValue, privacy: .public) writer failed: \(message, privacy: .public)")
        onFailure(kind, message)
    }

    private func count(_ update: (inout Statistics) -> Void) {
        lock.withLock { update(&stats) }
    }
}
