import Foundation

/// `meta.json`: facts about a recording, written by RecordingKit and never edited afterwards (except `name`).
///
/// Time model: **session time** starts at 0 when recording starts and excludes paused spans, so every stream file
/// and `events.jsonl` share one continuous timeline. A stream file's own t=0 sits at `streams[kind].startOffset`
/// on that timeline.
public struct RecordingMeta: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Length of the session timeline in seconds (pauses excluded).
    public var duration: Double
    public var source: CaptureSource
    public var screen: ScreenStreamInfo
    public var webcam: WebcamStreamInfo?
    public var microphone: AudioDeviceInfo?
    public var capturedSystemAudio: Bool
    /// Where each stream file's t=0 sits on the session timeline.
    public var streams: [StreamKind: StreamTiming]
    /// Pauses, in session time (where the pause happened) with the wall-clock length that was skipped.
    public var pauses: [PauseRecord]
    /// True when the system cursor was hidden from the capture (the editor then draws the recorded cursor).
    public var systemCursorHidden: Bool
    public var appVersion: String?

    public init(
        version: Int = RecordingMeta.currentVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        duration: Double = 0,
        source: CaptureSource,
        screen: ScreenStreamInfo,
        webcam: WebcamStreamInfo? = nil,
        microphone: AudioDeviceInfo? = nil,
        capturedSystemAudio: Bool = false,
        streams: [StreamKind: StreamTiming] = [:],
        pauses: [PauseRecord] = [],
        systemCursorHidden: Bool = false,
        appVersion: String? = nil
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.screen = screen
        self.webcam = webcam
        self.microphone = microphone
        self.capturedSystemAudio = capturedSystemAudio
        self.streams = streams
        self.pauses = pauses
        self.systemCursorHidden = systemCursorHidden
        self.appVersion = appVersion
    }
}

public enum StreamKind: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case screen
    case webcam
    case systemAudio
    case microphone

    /// File name inside the package.
    public var fileName: String {
        switch self {
        case .screen: PackageLayout.screen
        case .webcam: PackageLayout.webcam
        case .systemAudio: PackageLayout.systemAudio
        case .microphone: PackageLayout.microphone
        }
    }
}

public struct StreamTiming: Codable, Sendable, Equatable {
    /// Session time (seconds) of the file's first sample.
    public var startOffset: Double

    public init(startOffset: Double) {
        self.startOffset = startOffset
    }
}

public struct PauseRecord: Codable, Sendable, Equatable {
    /// Session time at which recording was paused.
    public var at: Double
    /// Wall-clock seconds that were skipped.
    public var skipped: Double

    public init(at: Double, skipped: Double) {
        self.at = at
        self.skipped = skipped
    }
}

public enum CaptureSource: Codable, Sendable, Equatable {
    case display(displayID: UInt32, name: String)
    case window(windowID: UInt32, title: String?, appName: String?, bundleID: String?)
    /// A rectangle of a display, in that display's points (origin top-left).
    case region(displayID: UInt32, x: Double, y: Double, width: Double, height: Double)
}

public struct ScreenStreamInfo: Codable, Sendable, Equatable {
    /// Encoded pixel size of `screen.mov`.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Backing scale factor of the captured display (pixels per point).
    public var scale: Double
    /// Target capture rate; the file is variable frame rate.
    public var frameRate: Int
    /// e.g. "hvc1", "avc1", "apcn".
    public var codec: String
    /// The captured content's frame in global display points (origin top-left of the main display) at
    /// recording start. Input events are normalised against this rect.
    public var contentRectPoints: RectPoints

    public init(
        pixelWidth: Int, pixelHeight: Int, scale: Double, frameRate: Int, codec: String, contentRectPoints: RectPoints
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.frameRate = frameRate
        self.codec = codec
        self.contentRectPoints = contentRectPoints
    }
}

public struct RectPoints: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WebcamStreamInfo: Codable, Sendable, Equatable {
    public var deviceID: String
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var frameRate: Int

    public init(deviceID: String, name: String, pixelWidth: Int, pixelHeight: Int, frameRate: Int) {
        self.deviceID = deviceID
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameRate = frameRate
    }
}

public struct AudioDeviceInfo: Codable, Sendable, Equatable {
    public var deviceID: String
    public var name: String

    public init(deviceID: String, name: String) {
        self.deviceID = deviceID
        self.name = name
    }
}
