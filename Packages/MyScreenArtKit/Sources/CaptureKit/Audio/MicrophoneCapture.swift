import AVFoundation
import CoreMedia

/// Microphone capture through `AVCaptureSession` + `AVCaptureAudioDataOutput`, with timestamps converted to the
/// host clock.
///
/// Used by ``MicLevelMonitor`` for the recorder's meter, and as an alternative recording path when
/// ScreenCaptureKit's own microphone capture isn't wanted.
public final class MicrophoneCapture: NSObject, @unchecked Sendable {
    public typealias SampleHandler = @Sendable (CMSampleBuffer) -> Void

    public enum SampleFormat: Sendable {
        /// The device's native format (for encoding).
        case native
        /// Interleaved Float32 PCM (for metering).
        case float32
    }

    public let deviceID: String
    public let deviceName: String

    private let session: AVCaptureSession
    private let output: AVCaptureAudioDataOutput
    private let sessionQueue = DispatchQueue(label: "com.myscreenart.capture.mic.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "com.myscreenart.capture.mic.output", qos: .userInteractive)
    private let lock = NSLock()
    private var handler: SampleHandler?

    /// Opens the microphone (`nil` = system default). Needs microphone permission to deliver audio.
    public init(deviceID: String?, format: SampleFormat = .native) throws {
        let device = deviceID.map { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw CaptureError.deviceNotFound(deviceID ?? "default microphone") }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        if format == .float32 {
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw CaptureError.deviceUnavailable(error.localizedDescription)
        }
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.deviceUnavailable("microphone rejected by capture session")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        self.session = session
        self.output = output
        self.deviceID = device.uniqueID
        self.deviceName = device.localizedName
        super.init()
        output.setSampleBufferDelegate(self, queue: outputQueue)
    }

    /// Starts delivering buffers to `handler` on a serial queue (QoS `.userInteractive`).
    public func start(handler: @escaping SampleHandler) async {
        lock.withLock { self.handler = handler }
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
        await withCheckedContinuation { continuation in outputQueue.async { continuation.resume() } }
        lock.withLock { handler = nil }
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let handler = lock.withLock({ handler }) else { return }
        handler(CameraCapture.onHostClock(sampleBuffer, clock: session.synchronizationClock) ?? sampleBuffer)
    }
}
