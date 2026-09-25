import CoreGraphics
import CoreMedia

/// How to run a ``ScreenCapture``.
public struct ScreenCaptureConfiguration: Sendable, Hashable {
    public var source: ScreenSource
    /// Maximum frame rate (30 or 60). Frames are delivered only when content changes, so the output is VFR.
    public var frameRate: Int
    /// Draw the system cursor into the frames. Off when the editor draws a recorded cursor.
    public var showsCursor: Bool
    /// Capture system audio (48 kHz stereo, excluding this app's own audio).
    public var capturesSystemAudio: Bool
    /// Capture this microphone (`AVCaptureDevice.uniqueID`) through the same stream, on the same clock.
    public var microphoneDeviceID: String?
    /// Hide this app's windows from display and region capture.
    public var excludesOwnApplication: Bool
    /// Surfaces ScreenCaptureKit may have in flight. Deeper queues absorb encoder hiccups at the cost of memory.
    public var queueDepth: Int

    public init(
        source: ScreenSource, frameRate: Int = 60, showsCursor: Bool = true, capturesSystemAudio: Bool = false,
        microphoneDeviceID: String? = nil, excludesOwnApplication: Bool = true, queueDepth: Int = 5
    ) {
        self.source = source
        self.frameRate = frameRate
        self.showsCursor = showsCursor
        self.capturesSystemAudio = capturesSystemAudio
        self.microphoneDeviceID = microphoneDeviceID
        self.excludesOwnApplication = excludesOwnApplication
        self.queueDepth = queueDepth
    }

    /// `minimumFrameInterval` for the configured rate (30 or 60; anything else is clamped to 1…120).
    public var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(min(max(frameRate, 1), 120)))
    }
}

/// The resolved size and placement of a screen capture.
public struct ScreenCaptureGeometry: Sendable, Equatable {
    /// Pixel size of the delivered frames (even).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point of the captured content.
    public var scale: Double
    /// Captured area in global points (origin top-left of the main display) at start.
    public var contentRect: CGRect
    /// The captured display (nil for window capture).
    public var displayID: CGDirectDisplayID?

    public init(pixelWidth: Int, pixelHeight: Int, scale: Double, contentRect: CGRect, displayID: CGDirectDisplayID?) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.contentRect = contentRect
        self.displayID = displayID
    }
}

/// Which stream output a sample buffer came from.
public enum ScreenCaptureOutput: Sendable, Hashable {
    case video
    case systemAudio
    case microphone
}

/// Why a running screen capture ended on its own.
public enum ScreenCaptureStopReason: Sendable, Equatable {
    /// The captured window closed or its application quit.
    case sourceClosed
    /// The captured display was disconnected.
    case displayRemoved
    /// The user stopped sharing from the system UI (menu bar / Control Center).
    case stoppedByUser
    /// The system stopped the stream (e.g. sleep, another capture took over).
    case stoppedBySystem
    case failed(String)
}
