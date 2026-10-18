import Foundation

/// `edit.json`: everything the editor changes. **All times are session (source) seconds.**
/// The edited timeline is the concatenation of `segments`; RenderKit maps edited time ↔ source time.
public struct EditConfig: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Kept source ranges: ascending, non-overlapping, each with positive length, within 0…duration.
    /// Trimming moves the first segment's start or the last segment's end.
    public var segments: [Segment]
    public var zoom: ZoomSettings
    public var webcam: WebcamSettings
    public var cursor: CursorSettings
    public var blur: [BlurMask]
    public var audio: AudioSettings
    public var background: BackgroundSettings
    /// Absent in files written before subtitles existed (decoded as the default).
    public var subtitles: SubtitleSettings

    public init(
        version: Int = EditConfig.currentVersion,
        segments: [Segment],
        zoom: ZoomSettings = ZoomSettings(),
        webcam: WebcamSettings = WebcamSettings(),
        cursor: CursorSettings = CursorSettings(),
        blur: [BlurMask] = [],
        audio: AudioSettings = AudioSettings(),
        background: BackgroundSettings = BackgroundSettings(),
        subtitles: SubtitleSettings = SubtitleSettings()
    ) {
        self.version = version
        self.segments = segments
        self.zoom = zoom
        self.webcam = webcam
        self.cursor = cursor
        self.blur = blur
        self.audio = audio
        self.background = background
        self.subtitles = subtitles
    }

    private enum CodingKeys: String, CodingKey {
        case version, segments, zoom, webcam, cursor, blur, audio, background, subtitles
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        segments = try c.decode([Segment].self, forKey: .segments)
        zoom = try c.decode(ZoomSettings.self, forKey: .zoom)
        webcam = try c.decode(WebcamSettings.self, forKey: .webcam)
        cursor = try c.decode(CursorSettings.self, forKey: .cursor)
        blur = try c.decode([BlurMask].self, forKey: .blur)
        audio = try c.decode(AudioSettings.self, forKey: .audio)
        background = try c.decode(BackgroundSettings.self, forKey: .background)
        subtitles = try c.decodeIfPresent(SubtitleSettings.self, forKey: .subtitles) ?? SubtitleSettings()
    }

    /// A fresh config for a recording: one segment covering everything, cursor overlay on if the system cursor
    /// was hidden, webcam shown if one was recorded.
    public static func initial(for meta: RecordingMeta) -> EditConfig {
        var config = EditConfig(segments: [Segment(start: 0, end: meta.duration)])
        config.webcam.enabled = meta.webcam != nil
        config.cursor.enabled = meta.systemCursorHidden
        config.audio.system.enabled = meta.capturedSystemAudio
        config.audio.microphone.enabled = meta.microphone != nil
        return config
    }
}

public struct Segment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

// MARK: - Zoom

public struct ZoomSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Values used for new keyframes (and auto-zoom seeding).
    public var defaults: ZoomTiming
    public var keyframes: [ZoomKeyframe]

    public init(enabled: Bool = true, defaults: ZoomTiming = ZoomTiming(), keyframes: [ZoomKeyframe] = []) {
        self.enabled = enabled
        self.defaults = defaults
        self.keyframes = keyframes
    }
}

public struct ZoomTiming: Codable, Sendable, Equatable {
    public var scale: Double
    public var easeIn: Double
    public var hold: Double
    public var easeOut: Double

    public init(scale: Double = 1.6, easeIn: Double = 0.32, hold: Double = 0.85, easeOut: Double = 0.48) {
        self.scale = scale
        self.easeIn = easeIn
        self.hold = hold
        self.easeOut = easeOut
    }
}

public enum ZoomMode: String, Codable, Sendable, CaseIterable {
    /// Fixed target chosen by the user.
    case manual
    /// Created from a click; fixed target at the click position.
    case click
    /// The zoom centre follows the (smoothed) cursor while held.
    case followMouse
}

public struct ZoomKeyframe: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Source time at which the ease-in starts.
    public var time: Double
    public var scale: Double
    public var target: NormPoint
    public var mode: ZoomMode
    public var easeIn: Double
    public var hold: Double
    public var easeOut: Double
    public var enabled: Bool
    /// Jump straight to `scale` (no easing).
    public var instant: Bool

    public init(
        id: UUID = UUID(), time: Double, scale: Double = 1.6, target: NormPoint = .center, mode: ZoomMode = .manual,
        easeIn: Double = 0.32, hold: Double = 0.85, easeOut: Double = 0.48, enabled: Bool = true, instant: Bool = false
    ) {
        self.id = id
        self.time = time
        self.scale = scale
        self.target = target
        self.mode = mode
        self.easeIn = easeIn
        self.hold = hold
        self.easeOut = easeOut
        self.enabled = enabled
        self.instant = instant
    }

    public var effectiveEaseIn: Double { instant ? 0 : easeIn }
    public var effectiveEaseOut: Double { instant ? 0 : easeOut }
    /// Source time when the zoom has fully returned to 1×.
    public var end: Double { time + effectiveEaseIn + hold + effectiveEaseOut }
}

// MARK: - Webcam

public struct WebcamSettings: Codable, Sendable, Equatable {
    public enum Aspect: String, Codable, Sendable, CaseIterable {
        /// The camera's own aspect ratio.
        case wide
        /// Centre-cropped to 1:1.
        case square
    }

    public var enabled: Bool
    /// Top-left corner, as a fraction of the output frame.
    public var origin: NormPoint
    /// Width as a fraction of the output frame's width; height follows from `aspect`.
    public var width: Double
    public var aspect: Aspect
    /// Corner radius as a fraction of the overlay's shorter side (0 = square, 0.5 = circle/pill).
    public var cornerRadius: Double
    public var mirrored: Bool
    public var shadow: Bool
    /// Manual sync nudge in seconds on top of the recorded offset. Positive = webcam appears later.
    public var syncOffset: Double

    public init(
        enabled: Bool = true, origin: NormPoint = NormPoint(x: 0.78, y: 0.72), width: Double = 0.2,
        aspect: Aspect = .wide, cornerRadius: Double = 0.1, mirrored: Bool = false, shadow: Bool = true,
        syncOffset: Double = 0
    ) {
        self.enabled = enabled
        self.origin = origin
        self.width = width
        self.aspect = aspect
        self.cornerRadius = cornerRadius
        self.mirrored = mirrored
        self.shadow = shadow
        self.syncOffset = syncOffset
    }
}

// MARK: - Cursor

public enum CursorStyle: Codable, Sendable, Hashable {
    /// The exact captured system cursor images.
    case system
    /// Bundled artwork chosen by each captured cursor's kind; unknown kinds fall back to the captured image.
    case stylised
    /// Always one bundled cursor.
    case fixed(CursorKind)
}

public enum CursorSize: String, Codable, Sendable, CaseIterable {
    case small
    case medium
    case large

    /// Multiplier applied to the cursor's native size.
    public var multiplier: Double {
        switch self {
        case .small: 0.75
        case .medium: 1.0
        case .large: 1.5
        }
    }
}

public enum CursorSmoothing: String, Codable, Sendable, CaseIterable {
    case none
    case rapid
    case medium
    case slow
}

public struct ClickHighlight: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var color: RGBAColor
    /// Radius in output points at 1× zoom.
    public var radius: Double
    public var duration: Double

    public init(
        enabled: Bool = true, color: RGBAColor = RGBAColor(hex: "#3B82F6")!, radius: Double = 30,
        duration: Double = 0.3
    ) {
        self.enabled = enabled
        self.color = color
        self.radius = radius
        self.duration = duration
    }
}

public struct DragTrail: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Number of trail samples.
    public var length: Int
    public var opacity: Double

    public init(enabled: Bool = false, length: Int = 5, opacity: Double = 0.5) {
        self.enabled = enabled
        self.length = length
        self.opacity = opacity
    }
}

public struct CursorSettings: Codable, Sendable, Equatable {
    /// Draw the recorded cursor. Only meaningful when the system cursor was hidden during capture.
    public var enabled: Bool
    public var style: CursorStyle
    public var size: CursorSize
    public var smoothing: CursorSmoothing
    public var hideWhenIdle: Bool
    /// Seconds without movement before the cursor fades out (when `hideWhenIdle`).
    public var idleDelay: Double
    /// Scale pulse (1 → 1.3 → 1 over 0.3 s, about the hotspot) on mouse-down.
    public var clickPulse: Bool
    public var clickHighlight: ClickHighlight
    public var dragTrail: DragTrail

    public init(
        enabled: Bool = false, style: CursorStyle = .system, size: CursorSize = .medium,
        smoothing: CursorSmoothing = .medium, hideWhenIdle: Bool = false, idleDelay: Double = 2,
        clickPulse: Bool = true, clickHighlight: ClickHighlight = ClickHighlight(), dragTrail: DragTrail = DragTrail()
    ) {
        self.enabled = enabled
        self.style = style
        self.size = size
        self.smoothing = smoothing
        self.hideWhenIdle = hideWhenIdle
        self.idleDelay = idleDelay
        self.clickPulse = clickPulse
        self.clickHighlight = clickHighlight
        self.dragTrail = dragTrail
    }
}

// MARK: - Blur

public struct BlurMask: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    /// Region in normalised source (screen) coordinates.
    public var rect: NormRect
    /// Gaussian radius in source pixels (1…50).
    public var intensity: Double

    public init(
        id: UUID = UUID(), start: Double, end: Double, rect: NormRect = NormRect(x: 0.3, y: 0.3, w: 0.2, h: 0.15),
        intensity: Double = 20
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.rect = rect
        self.intensity = intensity
    }
}

// MARK: - Audio

public struct TrackAudio: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var muted: Bool
    /// −20…+10 dB.
    public var gainDB: Double

    public init(enabled: Bool = true, muted: Bool = false, gainDB: Double = 0) {
        self.enabled = enabled
        self.muted = muted
        self.gainDB = gainDB
    }

    public var isAudible: Bool { enabled && !muted }
    public var linearGain: Double { pow(10, gainDB / 20) }
}

public struct AudioSettings: Codable, Sendable, Equatable {
    public var system: TrackAudio
    public var microphone: TrackAudio

    public init(system: TrackAudio = TrackAudio(), microphone: TrackAudio = TrackAudio(gainDB: -3)) {
        self.system = system
        self.microphone = microphone
    }
}

// MARK: - Background / canvas

public enum OutputAspect: String, Codable, Sendable, CaseIterable {
    /// Same as the recording.
    case source
    case landscape16x9
    case standard4x3
    case square
    case portrait9x16

    /// Width / height, or nil for `source`.
    public var ratio: Double? {
        switch self {
        case .source: nil
        case .landscape16x9: 16.0 / 9.0
        case .standard4x3: 4.0 / 3.0
        case .square: 1
        case .portrait9x16: 9.0 / 16.0
        }
    }
}

public enum BackgroundFill: Codable, Sendable, Hashable {
    case solid(RGBAColor)
    /// Linear gradient; angle in degrees, 0 = left→right, 90 = top→bottom.
    case linearGradient(from: RGBAColor, to: RGBAColor, angle: Double)
    /// An image file (absolute path), scaled to fill.
    case image(path: String)
}

/// Frames the recording on a canvas. When disabled the output is exactly the source frame.
public struct BackgroundSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var aspect: OutputAspect
    /// Gap around the content as a fraction of the canvas's shorter side (0…0.3).
    public var padding: Double
    /// Content corner radius as a fraction of the content's shorter side (0…0.2).
    public var cornerRadius: Double
    /// Drop-shadow strength 0…1.
    public var shadow: Double
    public var fill: BackgroundFill

    public init(
        enabled: Bool = false, aspect: OutputAspect = .source, padding: Double = 0.06, cornerRadius: Double = 0.02,
        shadow: Double = 0.5,
        fill: BackgroundFill = .linearGradient(
            from: RGBAColor(hex: "#4F46E5")!, to: RGBAColor(hex: "#DB2777")!, angle: 45)
    ) {
        self.enabled = enabled
        self.aspect = aspect
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.fill = fill
    }
}
