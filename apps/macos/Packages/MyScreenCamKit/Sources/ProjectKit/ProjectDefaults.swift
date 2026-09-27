import Foundation

/// The zoom and subtitle settings a recording's first edit starts with (Settings › Defaults). Only the look: never
/// per-recording content such as keyframes or cues.
public struct ProjectDefaults: Codable, Sendable, Equatable {
    public var zoomEnabled: Bool
    /// Seed a zoom on every left click (``AutoZoom``).
    public var autoZoom: Bool
    /// Timing and scale of seeded zooms and of zooms added in the editor.
    public var zoomTiming: ZoomTiming
    public var subtitlesEnabled: Bool
    public var subtitleStyle: SubtitleStyle
    public var subtitlePlacement: SubtitlePlacement

    public init(
        zoomEnabled: Bool = true, autoZoom: Bool = true, zoomTiming: ZoomTiming = ZoomTiming(),
        subtitlesEnabled: Bool = true, subtitleStyle: SubtitleStyle = SubtitleStyle(),
        subtitlePlacement: SubtitlePlacement = SubtitlePlacement()
    ) {
        self.zoomEnabled = zoomEnabled
        self.autoZoom = autoZoom
        self.zoomTiming = zoomTiming
        self.subtitlesEnabled = subtitlesEnabled
        self.subtitleStyle = subtitleStyle
        self.subtitlePlacement = subtitlePlacement
    }

    private enum CodingKeys: String, CodingKey {
        case zoomEnabled, autoZoom, zoomTiming, subtitlesEnabled, subtitleStyle, subtitlePlacement
    }

    /// Missing keys take the built-in default, so values saved by an older version still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ProjectDefaults()
        zoomEnabled = try c.decodeIfPresent(Bool.self, forKey: .zoomEnabled) ?? base.zoomEnabled
        autoZoom = try c.decodeIfPresent(Bool.self, forKey: .autoZoom) ?? base.autoZoom
        zoomTiming = try c.decodeIfPresent(ZoomTiming.self, forKey: .zoomTiming) ?? base.zoomTiming
        subtitlesEnabled = try c.decodeIfPresent(Bool.self, forKey: .subtitlesEnabled) ?? base.subtitlesEnabled
        subtitleStyle = try c.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? base.subtitleStyle
        subtitlePlacement =
            try c.decodeIfPresent(SubtitlePlacement.self, forKey: .subtitlePlacement) ?? base.subtitlePlacement
    }

    /// The subtitle part as subtitle settings with no cues (for editing it with the subtitle style controls).
    public var subtitles: SubtitleSettings {
        get { SubtitleSettings(enabled: subtitlesEnabled, style: subtitleStyle, placement: subtitlePlacement) }
        set {
            subtitlesEnabled = newValue.enabled
            subtitleStyle = newValue.style
            subtitlePlacement = newValue.placement
        }
    }

    /// Sets `config`'s zoom and subtitle look to these defaults (keyframes and cues are kept).
    public func apply(to config: inout EditConfig) {
        config.zoom.enabled = zoomEnabled
        config.zoom.defaults = zoomTiming
        config.subtitles.enabled = subtitlesEnabled
        config.subtitles.style = subtitleStyle
        config.subtitles.placement = subtitlePlacement
    }
}
