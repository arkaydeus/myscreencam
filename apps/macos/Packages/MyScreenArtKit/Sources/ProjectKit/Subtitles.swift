import Foundation

/// How subtitle text looks. Sizes are fractions of the output canvas, so every export size matches the preview.
public struct SubtitleStyle: Codable, Sendable, Hashable {
    /// Font family name (`NSFontManager` family), or nil for the system font.
    public var fontFamily: String?
    /// Font size as a fraction of the canvas height.
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var textColor: RGBAColor
    /// Outline stroke width as a fraction of the font size (0 = none).
    public var outlineWidth: Double
    public var outlineColor: RGBAColor
    public var background: Bool
    /// Box colour; its alpha is ignored in favour of `backgroundOpacity`.
    public var backgroundColor: RGBAColor
    public var backgroundOpacity: Double
    /// Longest line as a fraction of the canvas width; longer text wraps.
    public var maxWidth: Double

    public init(
        fontFamily: String? = nil, size: Double = 0.05, bold: Bool = true, italic: Bool = false,
        textColor: RGBAColor = .white, outlineWidth: Double = 0.06, outlineColor: RGBAColor = .black,
        background: Bool = true, backgroundColor: RGBAColor = .black, backgroundOpacity: Double = 0.55,
        maxWidth: Double = 0.8
    ) {
        self.fontFamily = fontFamily
        self.size = size
        self.bold = bold
        self.italic = italic
        self.textColor = textColor
        self.outlineWidth = outlineWidth
        self.outlineColor = outlineColor
        self.background = background
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.maxWidth = maxWidth
    }
}

/// Where cues without their own position sit.
public struct SubtitlePlacement: Codable, Sendable, Hashable {
    public enum Anchor: String, Codable, Sendable, CaseIterable {
        case bottom, middle, top
    }

    public var anchor: Anchor
    /// Gap between the box and the canvas edge (top/bottom anchors), as a fraction of the canvas height.
    public var margin: Double

    public init(anchor: Anchor = .bottom, margin: Double = 0.07) {
        self.anchor = anchor
        self.margin = margin
    }
}

/// One subtitle on screen. Times are **source** seconds, like every other effect.
public struct SubtitleCue: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    /// What's shown (the user's corrections included).
    public var text: String
    /// The text as generated from the transcript, or nil for a cue the user added. `text != generatedText` is a
    /// correction.
    public var generatedText: String?
    /// Transcript units the cue was built from (in the revision named by `SubtitleSettings.revisionID`).
    public var unitIDs: [String]
    /// Centre of the box in normalised canvas coordinates, when the user moved this cue.
    public var position: NormPoint?
    /// The user changed the timing by hand.
    public var timingEdited: Bool
    /// Built from a processing window only (no fine timing); shown as approximate.
    public var coarse: Bool

    public init(
        id: UUID = UUID(), start: Double, end: Double, text: String, generatedText: String? = nil,
        unitIDs: [String] = [], position: NormPoint? = nil, timingEdited: Bool = false, coarse: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.generatedText = generatedText
        self.unitIDs = unitIDs
        self.position = position
        self.timingEdited = timingEdited
        self.coarse = coarse
    }

    public var duration: Double { max(0, end - start) }
    public var isTextCorrected: Bool { generatedText.map { $0 != text } ?? true }
    /// Any change the user made that a regenerated transcript must not silently drop.
    public var isUserEdited: Bool { isTextCorrected || position != nil || timingEdited }
    public func isActive(at t: Double) -> Bool { t >= start && t < end }
}

/// `EditConfig.subtitles`.
public struct SubtitleSettings: Codable, Sendable, Hashable {
    /// Draw the cues (preview and export).
    public var enabled: Bool
    public var style: SubtitleStyle
    public var placement: SubtitlePlacement
    /// Sorted by start; may overlap only when the user makes them.
    public var cues: [SubtitleCue]
    /// The transcript revision the cues came from.
    public var revisionID: String?
    /// A newer revision waiting for the user to adopt or discard it.
    public var candidateRevisionID: String?
    /// Track to transcribe; nil = microphone if recorded, else system audio.
    public var audioSource: TranscriptAudioSource?

    public init(
        enabled: Bool = true, style: SubtitleStyle = SubtitleStyle(),
        placement: SubtitlePlacement = SubtitlePlacement(),
        cues: [SubtitleCue] = [], revisionID: String? = nil, candidateRevisionID: String? = nil,
        audioSource: TranscriptAudioSource? = nil
    ) {
        self.enabled = enabled
        self.style = style
        self.placement = placement
        self.cues = cues
        self.revisionID = revisionID
        self.candidateRevisionID = candidateRevisionID
        self.audioSource = audioSource
    }

    /// Cues showing at source time `t` (later cues draw on top).
    public func activeCues(at t: Double) -> [SubtitleCue] {
        guard enabled else { return [] }
        return cues.filter { $0.isActive(at: t) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension EditLimits {
    /// Subtitle font size as a fraction of the canvas height.
    public static let subtitleSize: ClosedRange<Double> = 0.02...0.15
    /// Outline width as a fraction of the font size.
    public static let subtitleOutline: ClosedRange<Double> = 0...0.25
    /// Margin from the top/bottom edge as a fraction of the canvas height.
    public static let subtitleMargin: ClosedRange<Double> = 0...0.4
    /// Longest line as a fraction of the canvas width.
    public static let subtitleMaxWidth: ClosedRange<Double> = 0.3...1
    /// Shortest cue the editor produces (seconds).
    public static let minimumCueLength = 0.2
}

extension SubtitleSettings {
    func normalized(duration: Double) -> SubtitleSettings {
        var settings = self
        let fallback = SubtitleStyle()
        settings.style.size = clamp(style.size, EditLimits.subtitleSize, fallback: fallback.size)
        settings.style.outlineWidth = clamp(
            style.outlineWidth, EditLimits.subtitleOutline, fallback: fallback.outlineWidth)
        settings.style.backgroundOpacity = clamp(style.backgroundOpacity, 0...1, fallback: fallback.backgroundOpacity)
        settings.style.maxWidth = clamp(style.maxWidth, EditLimits.subtitleMaxWidth, fallback: fallback.maxWidth)
        settings.placement.margin = clamp(placement.margin, EditLimits.subtitleMargin, fallback: 0.07)
        settings.cues =
            cues
            .compactMap { cue in
                var c = cue
                c.start = clamp(cue.start, 0...duration, fallback: 0)
                c.end = clamp(cue.end, 0...duration, fallback: 0)
                guard c.end > c.start else { return nil }
                c.position = cue.position.map {
                    NormPoint(x: clamp($0.x, 0...1, fallback: 0.5), y: clamp($0.y, 0...1, fallback: 0.9))
                }
                return c
            }
            .sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
        return settings
    }
}
