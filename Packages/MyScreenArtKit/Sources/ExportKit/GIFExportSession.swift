import AVFoundation
import MyScreenArtCore

/// Reader → ImageIO export to an animated GIF.
///
/// Frames are read from the video composition at the GIF size and frame rate as BGRA, and streamed
/// into the file one at a time (see ``GIFStreamWriter``). Memory use is about two frames whatever the
/// duration, so there is no duration cap; file size, not memory, is the practical limit.
final class GIFExportSession: @unchecked Sendable {
    // The reader output and GIF writer are confined to `queue` while frames are encoded; `run()`
    // cancels the reader only after the frame loop has returned.
    private let source: ExportSource
    private let settings: ExportSettings
    private let output: OutputFile
    private let control: ExportControl
    private let reporter: ProgressReporter
    private let options: VideoExporter.Options
    private let queue = DispatchQueue(label: "com.myscreenart.export.gif", qos: .userInitiated)

    init(
        source: ExportSource,
        settings: ExportSettings,
        output: OutputFile,
        control: ExportControl,
        reporter: ProgressReporter,
        options: VideoExporter.Options
    ) {
        self.source = source
        self.settings = settings
        self.output = output
        self.control = control
        self.reporter = reporter
        self.options = options
    }

    private struct Encoded: Sendable {
        var frames: Int
        var durationCentiseconds: Int
    }

    func run() async throws(ExportError) -> ExportResult {
        let size = source.renderSize
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw .readerFailed(underlying: error)
        }
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: source.videoTracks,
            videoSettings: EncoderConfiguration.readerVideoSettings(for: .gif))
        videoOutput.videoComposition = source.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw .readerFailed(underlying: reader.error) }
        reader.add(videoOutput)

        try control.checkCancelled()
        try output.prepare()
        guard reader.startReading() else { throw .readerFailed(underlying: reader.error) }

        reporter.beginEncoding(
            duration: source.duration.seconds, tracks: [.video], outputURL: output.temporaryURL,
            text: "Rendering GIF…")
        let watchdog = StallWatchdog(timeout: options.stallTimeout, reporter: reporter, control: control)
        let outputBox = UncheckedBox(videoOutput)
        let control = self.control

        // The frame loop checks for cancellation between frames. A stall (the loop stuck inside the
        // reader) can't be interrupted safely, so the job gives up on it instead.
        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Encoded, ExportError>?, Never>) in
            let resume = ResumeOnce(continuation)
            queue.async { [self] in
                resume(encodeFrames(from: outputBox.value, size: size))
            }
            control.setAbortHandler {
                if control.failure?.isStall == true { resume(nil) }
            }
        }
        watchdog.stop()
        control.setAbortHandler(nil)

        let encoded: Encoded
        switch outcome {
        case nil:
            output.discard()
            throw control.failure ?? .stalled(seconds: options.stallTimeout.seconds)
        case .success(let value):
            encoded = value
        case .failure(let error):
            reader.cancelReading()
            output.discard()
            throw error
        }
        if control.isCancelled || control.failure != nil || reader.status == .failed || encoded.frames == 0 {
            reader.cancelReading()
            output.discard()
            if control.isCancelled { throw .cancelled }
            if let failure = control.failure { throw failure }
            if reader.status == .failed { throw .readerFailed(underlying: reader.error) }
            throw .gifEncodingFailed("The video produced no frames.")
        }

        reporter.beginFinalizing()
        let fileSize = try output.commit()
        let result = ExportResult(
            url: output.finalURL,
            fileSize: fileSize,
            duration: Double(encoded.durationCentiseconds) / 100,
            dimensions: size,
            frameCount: encoded.frames,
            wallTime: reporter.elapsed,
            encoder: .imageIO,
            settings: settings
        )
        reporter.finish(bytesWritten: fileSize)
        return result
    }

    /// The frame loop. Runs synchronously on `queue`: read a frame, diff and encode it, write the
    /// previous one now that its delay is known.
    private func encodeFrames(from videoOutput: AVAssetReaderOutput, size: CGSize) -> Result<Encoded, ExportError> {
        let signpost = Log.signposter.beginInterval("ExportGIFPump", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("ExportGIFPump", signpost) }

        let writer: GIFStreamWriter
        do {
            writer = try GIFStreamWriter(
                url: output.temporaryURL, width: Int(size.width), height: Int(size.height))
        } catch {
            return .failure(.outputFailed(output.finalURL, underlying: error))
        }
        let encoder = GIFFrameEncoder(width: Int(size.width), height: Int(size.height))
        let frameDuration = settings.effectiveFrameRate.frameDuration.seconds

        // A frame is written once the next distinct frame arrives, because its delay (in whole
        // centiseconds, rounded on the cumulative timeline so there's no drift) depends on it.
        var pending: (frame: GIFFrame, startCentiseconds: Int)?
        var lastFrameEnd = 0.0
        do {
            while !control.shouldStop {
                let step: Bool = try autoreleasepool { () throws(ExportError) -> Bool in
                    guard let sample = videoOutput.copyNextSampleBuffer() else { return false }
                    guard let pixelBuffer = sample.imageBuffer else { return true }
                    let time = sample.presentationTimeStamp.seconds
                    lastFrameEnd = time + frameDuration
                    if let frame = try encoder.encode(pixelBuffer) {
                        let start = Int((time * 100).rounded())
                        if let previous = pending {
                            try append(previous.frame, delay: start - previous.startCentiseconds, to: writer)
                        }
                        pending = (frame, start)
                    }
                    reporter.didAppend(.video, endTime: lastFrameEnd)
                    return true
                }
                if !step { break }
            }
            if control.shouldStop {
                writer.abandon()
                return .success(Encoded(frames: writer.framesWritten, durationCentiseconds: 0))
            }
            let end = Int((max(lastFrameEnd, source.duration.seconds) * 100).rounded())
            if let last = pending {
                try append(last.frame, delay: end - last.startCentiseconds, to: writer)
            }
            do {
                try writer.close()
            } catch {
                throw ExportError.outputFailed(output.finalURL, underlying: error)
            }
            return .success(Encoded(frames: writer.framesWritten, durationCentiseconds: end))
        } catch {
            writer.abandon()
            return .failure(error as? ExportError ?? .gifEncodingFailed(error.localizedDescription))
        }
    }

    private func append(_ frame: GIFFrame, delay: Int, to writer: GIFStreamWriter) throws(ExportError) {
        do {
            try writer.append(frame, delayCentiseconds: delay)
        } catch {
            throw .outputFailed(output.finalURL, underlying: error)
        }
    }
}
