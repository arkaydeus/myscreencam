import AVFoundation
import CoreMedia
import MyScreenCamCore

/// Which camera to open and the format to aim for.
public struct CameraConfiguration: Sendable, Hashable {
    /// `AVCaptureDevice.uniqueID`.
    public var deviceID: String
    public var width: Int
    public var height: Int
    public var frameRate: Int

    public init(deviceID: String, width: Int = 1280, height: Int = 720, frameRate: Int = 30) {
        self.deviceID = deviceID
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

/// The format a ``CameraCapture`` actually runs at.
public struct CameraFormatInfo: Sendable, Equatable {
    public var deviceID: String
    public var name: String
    public var width: Int
    public var height: Int
    public var frameRate: Int
}

/// One `AVCaptureSession` for a camera that serves both the pre-recording preview and recording.
///
/// - Preview: build an `AVCaptureVideoPreviewLayer(session: camera.session)` (zero-copy) and call
///   ``startRunning()``.
/// - Recording: ``setSampleHandler(_:)`` receives `420v` IOSurface-backed sample buffers on a serial queue
///   (QoS `.userInteractive`), with presentation times already converted to the **host clock** so they line up
///   with ScreenCaptureKit and event timestamps. Late frames are discarded rather than queued.
public final class CameraCapture: NSObject, @unchecked Sendable {
    public typealias SampleHandler = @Sendable (CMSampleBuffer) -> Void

    /// The capture session, for `AVCaptureVideoPreviewLayer`. Don't reconfigure it.
    public let session: AVCaptureSession
    public let configuration: CameraConfiguration
    /// The format chosen for the device.
    public let format: CameraFormatInfo

    private let output: AVCaptureVideoDataOutput
    private let sessionQueue = DispatchQueue(label: "com.myscreencam.capture.camera.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "com.myscreencam.capture.camera.output", qos: .userInteractive)
    private let lock = NSLock()
    private var handler: SampleHandler?
    private var dropped = 0

    /// Opens the device and configures the session (not yet running). Needs camera permission to deliver frames.
    public init(configuration: CameraConfiguration) throws {
        self.configuration = configuration
        guard let device = AVCaptureDevice(uniqueID: configuration.deviceID) else {
            throw CaptureError.deviceNotFound(configuration.deviceID)
        }
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        try Self.configure(session, device: device, output: output)
        self.session = session
        self.output = output
        format = try Self.applyFormat(device: device, configuration: configuration)
        super.init()
        output.setSampleBufferDelegate(self, queue: outputQueue)
    }

    public var isRunning: Bool { session.isRunning }

    /// Frames the output discarded because the handler was late.
    public var droppedFrames: Int { lock.withLock { dropped } }

    /// Starts the session (off the calling thread; `startRunning` blocks).
    public func startRunning() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    public func stopRunning() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    /// Sets (or clears) the recording handler. Called on the camera output queue for every frame.
    public func setSampleHandler(_ handler: SampleHandler?) {
        lock.withLock { self.handler = handler }
    }

    private static func configure(
        _ session: AVCaptureSession, device: AVCaptureDevice, output: AVCaptureVideoDataOutput
    ) throws {
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw CaptureError.deviceUnavailable(error.localizedDescription)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw CaptureError.deviceUnavailable("input rejected") }
        session.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw CaptureError.deviceUnavailable("output rejected") }
        session.addOutput(output)
    }

    /// Chooses the device format closest to the configuration and locks the frame rate.
    static func applyFormat(
        device: AVCaptureDevice, configuration: CameraConfiguration
    ) throws -> CameraFormatInfo {
        let formats = device.formats
        let candidates = formats.map { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CameraFormatCandidate(
                width: Int(dimensions.width), height: Int(dimensions.height),
                maxFrameRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        guard
            let index = CameraFormatSelector.bestIndex(
                of: candidates, width: configuration.width, height: configuration.height,
                frameRate: Double(configuration.frameRate))
        else {
            throw CaptureError.deviceUnavailable("no video formats")
        }
        let chosen = formats[index]
        let duration = CameraFormatSelector.frameDuration(
            for: configuration.frameRate,
            in: chosen.videoSupportedFrameRateRanges.map {
                CameraFrameDurationRange(min: $0.minFrameDuration, max: $0.maxFrameDuration)
            })
        let rate = duration.map { 1 / $0.seconds } ?? candidates[index].maxFrameRate
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            if let duration {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            throw CaptureError.deviceUnavailable(error.localizedDescription)
        }
        return CameraFormatInfo(
            deviceID: device.uniqueID, name: device.localizedName, width: candidates[index].width,
            height: candidates[index].height, frameRate: Int(rate.rounded()))
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let handler = lock.withLock({ handler }) else { return }
        Log.signposter.emitEvent("camera.frame")
        handler(Self.onHostClock(sampleBuffer, clock: session.synchronizationClock) ?? sampleBuffer)
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        lock.withLock { dropped += 1 }
    }

    /// Converts the buffer's timestamps from the session's synchronisation clock to the host clock. Returns nil
    /// when no conversion is needed (the session already runs on the host clock).
    static func onHostClock(_ sampleBuffer: CMSampleBuffer, clock: CMClock?) -> CMSampleBuffer? {
        let host = CMClockGetHostTimeClock()
        guard let clock, clock != host else { return nil }
        return sampleBuffer.retimed { CMSyncConvertTime($0, from: clock, to: host) }
    }
}
