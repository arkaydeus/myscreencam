import CaptureKit
import Foundation

/// Everything a ``RecordingSession`` needs to know up front.
public struct RecordingOptions: Sendable, Hashable {
    /// Where the microphone is captured from.
    public enum MicrophoneBackend: Sendable, Hashable {
        /// Through the screen's `SCStream` (macOS 15): one callback path and clock for screen and audio.
        case screenCaptureKit
        /// Through an `AVCaptureSession` (timestamps converted to the host clock). A fallback if the
        /// ScreenCaptureKit path misbehaves with a particular device.
        case captureSession
    }

    public var source: ScreenSource
    /// 30 or 60 (default 60). The file is variable frame rate: static content produces no frames.
    public var frameRate: Int
    /// Hide the system cursor from the capture; the editor draws the recorded cursor instead. Needs Input
    /// Monitoring; without it the system cursor stays visible so the recording isn't cursor-less.
    public var hideSystemCursor: Bool
    public var captureSystemAudio: Bool
    /// `AVCaptureDevice.uniqueID` of the microphone, or nil for none.
    public var microphoneDeviceID: String?
    public var microphoneBackend: MicrophoneBackend
    /// `AVCaptureDevice.uniqueID` of the camera, or nil for none.
    public var cameraDeviceID: String?
    /// Desired camera format (closest available is used).
    public var cameraWidth: Int
    public var cameraHeight: Int
    public var cameraFrameRate: Int
    public var videoCodec: VideoCodec
    /// Folder that receives the new `.mscam` package.
    public var recordingsRoot: URL
    /// Display name; defaults to "Recording <date>".
    public var name: String?
    /// Record pointer events and cursor images (needs Input Monitoring; skipped silently without it).
    public var recordsInputEvents: Bool

    public init(
        source: ScreenSource, recordingsRoot: URL, frameRate: Int = 60, hideSystemCursor: Bool = false,
        captureSystemAudio: Bool = true, microphoneDeviceID: String? = nil,
        microphoneBackend: MicrophoneBackend = .screenCaptureKit, cameraDeviceID: String? = nil,
        cameraWidth: Int = 1280, cameraHeight: Int = 720, cameraFrameRate: Int = 30, videoCodec: VideoCodec = .hevc,
        name: String? = nil, recordsInputEvents: Bool = true
    ) {
        self.source = source
        self.recordingsRoot = recordingsRoot
        self.frameRate = frameRate
        self.hideSystemCursor = hideSystemCursor
        self.captureSystemAudio = captureSystemAudio
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneBackend = microphoneBackend
        self.cameraDeviceID = cameraDeviceID
        self.cameraWidth = cameraWidth
        self.cameraHeight = cameraHeight
        self.cameraFrameRate = cameraFrameRate
        self.videoCodec = videoCodec
        self.name = name
        self.recordsInputEvents = recordsInputEvents
    }

    /// "Recording 25 Sep 2026 at 14:03" in the user's locale.
    public static func defaultName(for date: Date) -> String {
        "Recording \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
