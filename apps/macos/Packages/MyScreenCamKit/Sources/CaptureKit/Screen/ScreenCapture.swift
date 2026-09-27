import AppKit
import CoreMedia
import MyScreenCamCore
import ScreenCaptureKit

/// Zero-copy screen capture with ScreenCaptureKit: video (`420v`, native pixel resolution, VFR), and optionally
/// system audio and a microphone on the same host clock.
///
/// Sample buffers are handed to the sample handler **as delivered** (IOSurface-backed pixel buffers, PCM audio)
/// on serial capture queues (QoS `.userInteractive`): video on one queue, audio and microphone on another.
/// Only frames with new content (`SCFrameStatus.complete`/`.started`) are delivered; idle frames are skipped,
/// so a static screen costs almost nothing downstream.
///
/// Lifecycle: ``prepare()`` → ``start(onSample:onStop:)`` → ``stop()``. Not restartable.
public final class ScreenCapture: NSObject, @unchecked Sendable {
    public typealias SampleHandler = @Sendable (CMSampleBuffer, ScreenCaptureOutput) -> Void
    public typealias StopHandler = @Sendable (ScreenCaptureStopReason) -> Void

    /// Frame counters for diagnostics.
    public struct Statistics: Sendable, Equatable {
        public var framesDelivered = 0
        public var idleFramesSkipped = 0
        public var audioBuffersDelivered = 0
        public var microphoneBuffersDelivered = 0
    }

    public let configuration: ScreenCaptureConfiguration

    private let videoQueue = DispatchQueue(label: "com.myscreencam.capture.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.myscreencam.capture.screen.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var resolved: ResolvedContent?
    private var geometry: ScreenCaptureGeometry?
    private var stream: SCStream?
    private var onSample: SampleHandler?
    private var onStop: StopHandler?
    private var isStopping = false
    private var stopReported = false
    private var stats = Statistics()
    private var sourceWatch: SourceWatch?

    public init(configuration: ScreenCaptureConfiguration) {
        self.configuration = configuration
    }

    public var statistics: Statistics { lock.withLock { stats } }

    /// Resolves the source and returns the capture geometry. Needs Screen Recording permission.
    @discardableResult
    public func prepare() async throws -> ScreenCaptureGeometry {
        if let geometry = lock.withLock({ geometry }) { return geometry }
        let resolved = try await ContentResolver.resolve(
            configuration.source, excludingOwnApplication: configuration.excludesOwnApplication)
        let pixels = CaptureGeometry.evenPixelSize(points: resolved.contentRect.size, scale: resolved.scale)
        let geometry = ScreenCaptureGeometry(
            pixelWidth: pixels.width, pixelHeight: pixels.height, scale: resolved.scale,
            contentRect: resolved.contentRect, displayID: resolved.displayID)
        lock.withLock {
            self.resolved = resolved
            self.geometry = geometry
        }
        return geometry
    }

    /// Starts the stream. Returns once ScreenCaptureKit has started; the first frame follows shortly after.
    /// - Parameters:
    ///   - onSample: called on a capture queue for every delivered buffer. Don't block it.
    ///   - onStop: called at most once if the stream ends on its own (source gone, user/system stop, error).
    public func start(onSample: @escaping SampleHandler, onStop: @escaping StopHandler) async throws {
        try await prepare()
        guard let resolved = lock.withLock({ resolved }), let geometry = lock.withLock({ geometry }) else { return }
        let streamConfiguration = makeStreamConfiguration(resolved: resolved, geometry: geometry)
        let stream = SCStream(filter: resolved.filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if configuration.microphoneDeviceID != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        lock.withLock {
            self.stream = stream
            self.onSample = onSample
            self.onStop = onStop
        }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock { self.stream = nil }
            throw error
        }
        let watch = await SourceWatch.start(
            displayID: resolved.displayID, windowOwnerPID: resolved.windowOwnerPID
        ) { [weak self] reason in self?.reportStop(reason) }
        lock.withLock { sourceWatch = watch }
        CaptureLog.capture.info(
            "Screen capture started \(geometry.pixelWidth)x\(geometry.pixelHeight) @\(self.configuration.frameRate)")
    }

    /// Stops the stream. In-flight buffers already queued are still delivered before this returns.
    public func stop() async {
        let (stream, watch) = lock.withLock {
            isStopping = true
            defer {
                self.stream = nil
                sourceWatch = nil
            }
            return (self.stream, sourceWatch)
        }
        await watch?.cancel()
        if let stream {
            do { try await stream.stopCapture() } catch {
                CaptureLog.capture.debug("stopCapture: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Drain buffers that were already dispatched to the capture queues.
        await withCheckedContinuation { continuation in videoQueue.async { continuation.resume() } }
        await withCheckedContinuation { continuation in audioQueue.async { continuation.resume() } }
        lock.withLock {
            onSample = nil
            onStop = nil
        }
    }

    private func makeStreamConfiguration(
        resolved: ResolvedContent, geometry: ScreenCaptureGeometry
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = geometry.pixelWidth
        config.height = geometry.pixelHeight
        if let sourceRect = resolved.sourceRect { config.sourceRect = sourceRect }
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = configuration.minimumFrameInterval
        config.queueDepth = min(max(configuration.queueDepth, 3), 8)
        config.showsCursor = configuration.showsCursor
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = false
        if configuration.capturesSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        if let microphone = configuration.microphoneDeviceID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = microphone
        }
        return config
    }

    private func reportStop(_ reason: ScreenCaptureStopReason) {
        let handler: StopHandler? = lock.withLock {
            guard !isStopping, !stopReported else { return nil }
            stopReported = true
            return onStop
        }
        guard let handler else { return }
        CaptureLog.capture.notice("Screen capture ended: \(String(describing: reason), privacy: .public)")
        handler(reason)
    }

    /// Maps a stream error to a stop reason, checking whether the source still exists.
    private func stopReason(for error: any Error) -> ScreenCaptureStopReason {
        let code = (error as NSError).domain == SCStreamErrorDomain ? (error as NSError).code : 0
        if code == SCStreamError.Code.userStopped.rawValue { return .stoppedByUser }
        switch configuration.source {
        case .window(let id) where !WindowList.exists(id):
            return .sourceClosed
        case .display(let id) where CGDisplayIsOnline(id) == 0 || CGDisplayIsActive(id) == 0,
            .region(let id, _) where CGDisplayIsOnline(id) == 0 || CGDisplayIsActive(id) == 0:
            return .displayRemoved
        default:
            break
        }
        if code == SCStreamError.Code.systemStoppedStream.rawValue { return .stoppedBySystem }
        return .failed(error.localizedDescription)
    }
}

extension ScreenCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        let output: ScreenCaptureOutput
        switch type {
        case .screen:
            switch Self.frameStatus(of: sampleBuffer) {
            case .complete, .started:
                guard sampleBuffer.imageBuffer != nil else { return }
                output = .video
            case .stopped:
                if case .window = configuration.source { reportStop(.sourceClosed) }
                return
            default:
                lock.withLock { stats.idleFramesSkipped += 1 }
                return
            }
        case .audio: output = .systemAudio
        case .microphone: output = .microphone
        @unknown default: return
        }
        let handler: SampleHandler? = lock.withLock {
            switch output {
            case .video: stats.framesDelivered += 1
            case .systemAudio: stats.audioBuffersDelivered += 1
            case .microphone: stats.microphoneBuffersDelivered += 1
            }
            return onSample
        }
        if output == .video { Log.signposter.emitEvent("screen.frame") }
        handler?(sampleBuffer, output)
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        reportStop(stopReason(for: error))
    }

    static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }
}
