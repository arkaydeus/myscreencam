import AVFoundation
import MyScreenArtCore
import os

/// Moves samples from one reader output to one writer input whenever the input can take more.
///
/// Driven by `requestMediaDataWhenReady` on its own serial queue: no polling, and at most the
/// reader's and encoder's own small queues of frames are in flight, so memory stays bounded.
/// All mutable state is confined to `queue`.
final class SamplePump: @unchecked Sendable {
    let track: ProgressReporter.Track
    private let input: AVAssetWriterInput
    private let output: AVAssetReaderOutput
    private let queue: DispatchQueue
    private var finished = false
    private var completion: (@Sendable () -> Void)?
    private var signpost: OSSignpostIntervalState?

    init(track: ProgressReporter.Track, input: AVAssetWriterInput, output: AVAssetReaderOutput) {
        self.track = track
        self.input = input
        self.output = output
        self.queue = DispatchQueue(
            label: "com.myscreenart.export.\(track == .video ? "video" : "audio")", qos: .userInitiated)
    }

    /// Starts pumping. `completion` runs exactly once, on the pump queue, when the pump ends.
    func start(
        control: ExportControl,
        reporter: ProgressReporter,
        writerError: @escaping @Sendable () -> (any Error)?,
        completion: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            self.completion = completion
            signpost = Log.signposter.beginInterval(
                track == .video ? "ExportVideoPump" : "ExportAudioPump", id: Log.signposter.makeSignpostID())
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while !finished && input.isReadyForMoreMediaData {
                    let keepGoing = autoreleasepool { () -> Bool in
                        if control.shouldStop {
                            return false
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            // End of data, or the reader failed/was cancelled; the session checks which.
                            return false
                        }
                        guard input.append(sample) else {
                            control.fail(.writerFailed(underlying: writerError()))
                            return false
                        }
                        let end = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
                        reporter.didAppend(track, endTime: end.isNumeric ? end.seconds : 0)
                        return true
                    }
                    if !keepGoing {
                        finish(markInput: true, reporter: reporter)
                    }
                }
            }
        }
    }

    /// Ends the pump from outside (cancellation or failure), even if its input is waiting for
    /// readiness and its callback would never run again. Serialised with the callback on `queue`.
    func forceFinish(reporter: ProgressReporter) {
        queue.async { [self] in
            finish(markInput: false, reporter: reporter)
        }
    }

    private func finish(markInput: Bool, reporter: ProgressReporter) {
        guard !finished else { return }
        finished = true
        if markInput {
            input.markAsFinished()
        }
        if let signpost {
            Log.signposter.endInterval(track == .video ? "ExportVideoPump" : "ExportAudioPump", signpost)
        }
        reporter.didFinish(track)
        let completion = self.completion
        self.completion = nil
        completion?()
    }
}

/// Reader → writer export to MP4/MOV.
final class MovieExportSession: @unchecked Sendable {
    // AVAssetReader/Writer aren't Sendable. They're created in `run()`; while the pumps run, their
    // inputs/outputs are touched only by the pumps (each on its own queue), and the reader/writer are
    // cancelled or finished by `run()` only after every pump has returned. (`cancelReading()` while
    // another thread is inside `copyNextSampleBuffer()` crashes AVFoundation.)
    private let source: ExportSource
    private let audioMix: AVAudioMix?
    private let settings: ExportSettings
    private let output: OutputFile
    private let control: ExportControl
    private let reporter: ProgressReporter
    private let options: VideoExporter.Options

    init(
        source: ExportSource,
        audioMix: AVAudioMix?,
        settings: ExportSettings,
        output: OutputFile,
        control: ExportControl,
        reporter: ProgressReporter,
        options: VideoExporter.Options
    ) {
        self.source = source
        self.audioMix = audioMix
        self.settings = settings
        self.output = output
        self.control = control
        self.reporter = reporter
        self.options = options
    }

    func run() async throws(ExportError) -> ExportResult {
        let size = source.renderSize
        let useHardware = EncoderConfiguration.hasHardwareEncoder(for: settings.format, size: size)
        guard let fileType = settings.container.avFileType else {
            throw .invalidSettings("\(settings.container.fileExtension) isn't a movie container.")
        }

        try control.checkCancelled()
        try output.prepare()

        // Writer.
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output.temporaryURL, fileType: fileType)
        } catch {
            throw .outputFailed(output.finalURL, underlying: error)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoSettings = EncoderConfiguration.writerVideoSettings(
            for: settings, size: size, requireHardware: useHardware)
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw .invalidSettings("The writer rejected the \(settings.format.displayName) video settings.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw .invalidSettings("\(settings.format.displayName) video can't be added to this container.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let codec = settings.audioCodec, !source.audioTracks.isEmpty {
            let audioSettings = EncoderConfiguration.writerAudioSettings(for: codec)
            if writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
            if audioInput == nil {
                throw .invalidSettings("The writer rejected the \(codec) audio settings.")
            }
        }

        // Reader.
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw .readerFailed(underlying: error)
        }
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: source.videoTracks,
            videoSettings: EncoderConfiguration.readerVideoSettings(for: settings.format))
        videoOutput.videoComposition = source.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw .readerFailed(underlying: reader.error)
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if audioInput != nil {
            let mixOutput = AVAssetReaderAudioMixOutput(
                audioTracks: source.audioTracks, audioSettings: EncoderConfiguration.readerAudioSettings)
            mixOutput.audioMix = audioMix
            mixOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(mixOutput) else {
                throw .readerFailed(underlying: reader.error)
            }
            reader.add(mixOutput)
            audioOutput = mixOutput
        }

        try control.checkCancelled()

        // Start.
        guard reader.startReading() else {
            throw .readerFailed(underlying: reader.error)
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            output.discard()
            throw .writerFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        var allPumps = [SamplePump(track: .video, input: videoInput, output: videoOutput)]
        if let audioInput, let audioOutput {
            allPumps.append(SamplePump(track: .audio, input: audioInput, output: audioOutput))
        }
        let pumps = allPumps
        reporter.beginEncoding(
            duration: source.duration.seconds,
            tracks: Set(pumps.map(\.track)),
            outputURL: output.temporaryURL,
            text: "Encoding video…")

        let signpostID = Log.signposter.makeSignpostID()
        let exportInterval = Log.signposter.beginInterval("Export", id: signpostID, "\(self.settings.format.rawValue)")
        defer { Log.signposter.endInterval("Export", exportInterval) }

        let reporter = self.reporter
        let control = self.control
        let writerBox = UncheckedBox(writer)
        let watchdog = StallWatchdog(timeout: options.stallTimeout, reporter: reporter, control: control)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<PumpOutcome, Never>) in
            let resume = ResumeOnce(continuation)
            let group = DispatchGroup()
            for pump in pumps {
                group.enter()
                pump.start(
                    control: control, reporter: reporter,
                    writerError: { writerBox.value.error },
                    completion: { group.leave() })
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                resume(.finished)
            }
            // Cancellation and failures stop each pump at its next sample; pumps waiting for their
            // input to become ready are ended on their own queue. A stall can't be interrupted safely.
            control.setAbortHandler {
                for pump in pumps {
                    pump.forceFinish(reporter: reporter)
                }
                if control.failure?.isStall == true {
                    resume(.abandoned)
                }
            }
        }
        watchdog.stop()
        control.setAbortHandler(nil)

        // Outcome.
        if outcome.isAbandoned {
            output.discard()
            if control.isCancelled { throw .cancelled }
            throw control.failure ?? .stalled(seconds: options.stallTimeout.seconds)
        }
        if control.isCancelled || control.failure != nil || reader.status == .failed {
            reader.cancelReading()
            if writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
            output.discard()
            if control.isCancelled { throw .cancelled }
            if let failure = control.failure { throw failure }
            throw .readerFailed(underlying: reader.error)
        }
        if writer.status == .failed {
            output.discard()
            throw .writerFailed(underlying: writer.error)
        }

        reporter.beginFinalizing()
        let finalizeInterval = Log.signposter.beginInterval("ExportFinalize", id: signpostID)
        await writer.finishWriting()
        Log.signposter.endInterval("ExportFinalize", finalizeInterval)
        guard writer.status == .completed else {
            output.discard()
            throw .writerFailed(underlying: writer.error)
        }
        if control.isCancelled {
            output.discard()
            throw .cancelled
        }

        let fileSize = try output.commit()
        let outputAsset = AVURLAsset(url: output.finalURL)
        let duration = (try? await outputAsset.load(.duration))?.seconds ?? source.duration.seconds
        let result = ExportResult(
            url: output.finalURL,
            fileSize: fileSize,
            duration: duration,
            dimensions: size,
            frameCount: reporter.latest.framesWritten,
            wallTime: reporter.elapsed,
            encoder: useHardware ? .hardware : .bestAvailable,
            settings: settings
        )
        reporter.finish(bytesWritten: fileSize)
        return result
    }
}

/// Carries a non-Sendable AVFoundation object into a `@Sendable` closure. Only used for calls that
/// AVFoundation documents as thread-safe (`cancelReading`, reading `error`).
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
