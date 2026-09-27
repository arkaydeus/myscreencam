/// The export dialog's presets. Each one is a starting point: the UI copies ``settings`` and lets the
/// user change quality, frame rate and scale. `Codable` (as its raw value) so the last choice can be remembered.
public enum ExportPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    /// H.264 MP4, at most 1080p, 30 fps, high quality. Plays everywhere.
    case web
    /// As ``web`` but 60 fps, for fast pointer and scroll motion.
    case smooth
    /// HEVC MP4, at most 1080p, 24 fps, medium quality. Small files.
    case compact
    /// ProRes 422 MOV at full size and 60 fps with PCM audio, for further editing.
    case master
    /// Looping GIF, at most 720 px on the long edge, 15 fps.
    case gif

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .web: "Web"
        case .smooth: "Smooth"
        case .compact: "Compact"
        case .master: "Master"
        case .gif: "GIF"
        }
    }

    /// A one-line description for the preset menu.
    public var summary: String {
        switch self {
        case .web: "H.264 · up to 1080p · 30 fps"
        case .smooth: "H.264 · up to 1080p · 60 fps"
        case .compact: "HEVC · up to 1080p · 24 fps · smaller file"
        case .master: "ProRes 422 · full size · 60 fps"
        case .gif: "GIF · up to 720 px · 15 fps"
        }
    }

    public var settings: ExportSettings {
        switch self {
        case .web:
            ExportSettings(
                format: .h264, container: .mp4, quality: .high, frameRate: .fps30,
                maxLongEdge: 1920, maxShortEdge: 1080)
        case .smooth:
            ExportSettings(
                format: .h264, container: .mp4, quality: .high, frameRate: .fps60,
                maxLongEdge: 1920, maxShortEdge: 1080)
        case .compact:
            ExportSettings(
                format: .hevc, container: .mp4, quality: .medium, frameRate: .fps24,
                maxLongEdge: 1920, maxShortEdge: 1080)
        case .master:
            ExportSettings(format: .proRes422, container: .mov, quality: .max, frameRate: .fps60)
        case .gif:
            ExportSettings(
                format: .gif, container: .gif, quality: .high, frameRate: .fps15,
                maxLongEdge: 720, includesAudio: false)
        }
    }
}
