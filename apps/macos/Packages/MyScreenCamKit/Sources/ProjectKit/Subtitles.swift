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
    /// Colour the word being spoken in `highlightColor` (cues with word timing only; see ``SubtitleWords``).
    public var highlightWords: Bool
    public var highlightColor: RGBAColor
    /// How the spoken word stands out: drawn in `highlightColor`, or on a box of it.
    public var highlightMode: SubtitleHighlightMode
    /// How much bigger the highlighted word is drawn (0.1 = 10%). It grows in place, so the layout doesn't move.
    public var highlightGrow: Double
    /// Draw the words not spoken yet at `upcomingOpacity` (cues with word timing only).
    public var dimUpcoming: Bool
    public var upcomingOpacity: Double
    /// Drop shadow behind the text (and its outline).
    public var shadow: SubtitleShadow
    /// Show every cue in capitals. Display only: the cue text (and the .srt) keep the case as written.
    public var uppercase: Bool

    /// Yellow (#FFD60A), the usual karaoke colour, readable over the default black box and outline. Exact 8-bit
    /// values, as colours are stored.
    public static let defaultHighlightColor = RGBAColor(r: 1, g: 214 / 255, b: 10 / 255)

    public init(
        fontFamily: String? = nil, size: Double = 0.05, bold: Bool = true, italic: Bool = false,
        textColor: RGBAColor = .white, outlineWidth: Double = 0.06, outlineColor: RGBAColor = .black,
        background: Bool = true, backgroundColor: RGBAColor = .black, backgroundOpacity: Double = 0.55,
        maxWidth: Double = 0.8, highlightWords: Bool = false,
        highlightColor: RGBAColor = SubtitleStyle.defaultHighlightColor, highlightMode: SubtitleHighlightMode = .text,
        highlightGrow: Double = 0.1, dimUpcoming: Bool = false, upcomingOpacity: Double = 0.5,
        shadow: SubtitleShadow = SubtitleShadow(), uppercase: Bool = false
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
        self.highlightWords = highlightWords
        self.highlightColor = highlightColor
        self.highlightMode = highlightMode
        self.highlightGrow = highlightGrow
        self.dimUpcoming = dimUpcoming
        self.upcomingOpacity = upcomingOpacity
        self.shadow = shadow
        self.uppercase = uppercase
    }

    /// `text` as it's drawn in this style.
    public func displayText(_ text: String) -> String {
        uppercase ? text.uppercased() : text
    }
}

extension SubtitleStyle {
    /// Word highlighting (and its mode), dimming upcoming words, the shadow and uppercase are absent from files
    /// written before they existed (decoded as the defaults: off).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        size = try c.decode(Double.self, forKey: .size)
        bold = try c.decode(Bool.self, forKey: .bold)
        italic = try c.decode(Bool.self, forKey: .italic)
        textColor = try c.decode(RGBAColor.self, forKey: .textColor)
        outlineWidth = try c.decode(Double.self, forKey: .outlineWidth)
        outlineColor = try c.decode(RGBAColor.self, forKey: .outlineColor)
        background = try c.decode(Bool.self, forKey: .background)
        backgroundColor = try c.decode(RGBAColor.self, forKey: .backgroundColor)
        backgroundOpacity = try c.decode(Double.self, forKey: .backgroundOpacity)
        maxWidth = try c.decode(Double.self, forKey: .maxWidth)
        highlightWords = try c.decodeIfPresent(Bool.self, forKey: .highlightWords) ?? false
        highlightColor =
            try c.decodeIfPresent(RGBAColor.self, forKey: .highlightColor) ?? SubtitleStyle.defaultHighlightColor
        highlightMode = try c.decodeIfPresent(SubtitleHighlightMode.self, forKey: .highlightMode) ?? .text
        highlightGrow = try c.decodeIfPresent(Double.self, forKey: .highlightGrow) ?? 0.1
        dimUpcoming = try c.decodeIfPresent(Bool.self, forKey: .dimUpcoming) ?? false
        upcomingOpacity = try c.decodeIfPresent(Double.self, forKey: .upcomingOpacity) ?? 0.5
        shadow = try c.decodeIfPresent(SubtitleShadow.self, forKey: .shadow) ?? SubtitleShadow()
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? false
    }
}

/// How the spoken word stands out when words are highlighted.
public enum SubtitleHighlightMode: String, Codable, Sendable, CaseIterable {
    /// The word is drawn in the highlight colour.
    case text
    /// The word keeps the text colour, on a rounded box in the highlight colour.
    case box
}

/// A drop shadow behind subtitle text. Lengths are fractions of the font size, so it scales with the text.
public struct SubtitleShadow: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Direction the shadow falls, in degrees clockwise from the right (90 = straight down).
    public var angle: Double
    /// How far the shadow falls from the text ("depth").
    public var distance: Double
    public var blur: Double
    public var color: RGBAColor
    public var opacity: Double

    public init(
        enabled: Bool = false, angle: Double = 45, distance: Double = 0.08, blur: Double = 0.1,
        color: RGBAColor = .black, opacity: Double = 0.6
    ) {
        self.enabled = enabled
        self.angle = angle
        self.distance = distance
        self.blur = blur
        self.color = color
        self.opacity = opacity
    }

    /// Offset in ems, y down.
    public var offset: (dx: Double, dy: Double) {
        let radians = angle * .pi / 180
        return (distance * cos(radians), distance * sin(radians))
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
    /// This cue's widest line as a fraction of the canvas width, when the user resized its box (nil = the style's
    /// `maxWidth`).
    public var maxWidth: Double?
    /// The user changed the timing by hand.
    public var timingEdited: Bool
    /// Built from a processing window only (no fine timing); shown as approximate.
    public var coarse: Bool
    /// When each recognised word is spoken, for word highlighting (empty without acoustic word timing).
    public var words: [SubtitleWord]

    public init(
        id: UUID = UUID(), start: Double, end: Double, text: String, generatedText: String? = nil,
        unitIDs: [String] = [], position: NormPoint? = nil, timingEdited: Bool = false, coarse: Bool = false,
        words: [SubtitleWord] = [], maxWidth: Double? = nil
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
        self.words = words
        self.maxWidth = maxWidth
    }

    public var duration: Double { max(0, end - start) }
    public var isTextCorrected: Bool { generatedText.map { $0 != text } ?? true }
    /// Any change the user made that a regenerated transcript must not silently drop.
    public var isUserEdited: Bool { isTextCorrected || position != nil || maxWidth != nil || timingEdited }
    public func isActive(at t: Double) -> Bool { t >= start && t < end }
}

extension SubtitleCue {
    /// Word timing and the cue's own width are absent from files written before they existed (decoded as none).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        generatedText = try c.decodeIfPresent(String.self, forKey: .generatedText)
        unitIDs = try c.decode([String].self, forKey: .unitIDs)
        position = try c.decodeIfPresent(NormPoint.self, forKey: .position)
        timingEdited = try c.decode(Bool.self, forKey: .timingEdited)
        coarse = try c.decode(Bool.self, forKey: .coarse)
        words = try c.decodeIfPresent([SubtitleWord].self, forKey: .words) ?? []
        maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth)
    }
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

    /// The style `cue` is drawn in: the shared style with the cue's own width, if it has one.
    public func style(for cue: SubtitleCue) -> SubtitleStyle {
        guard let width = cue.maxWidth else { return style }
        var style = style
        style.maxWidth = width
        return style
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
    public static let subtitleMaxWidth: ClosedRange<Double> = 0.1...1
    /// How much bigger the highlighted word is drawn.
    public static let subtitleHighlightGrow: ClosedRange<Double> = 0...0.5
    /// Shadow distance and blur as fractions of the font size.
    public static let subtitleShadowDistance: ClosedRange<Double> = 0...0.5
    public static let subtitleShadowBlur: ClosedRange<Double> = 0...0.5
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
        settings.style.highlightGrow = clamp(
            style.highlightGrow, EditLimits.subtitleHighlightGrow, fallback: fallback.highlightGrow)
        settings.style.upcomingOpacity = clamp(style.upcomingOpacity, 0...1, fallback: fallback.upcomingOpacity)
        let shadow = SubtitleShadow()
        settings.style.shadow.angle = clamp(style.shadow.angle, 0...360, fallback: shadow.angle)
        settings.style.shadow.distance = clamp(
            style.shadow.distance, EditLimits.subtitleShadowDistance, fallback: shadow.distance)
        settings.style.shadow.blur = clamp(style.shadow.blur, EditLimits.subtitleShadowBlur, fallback: shadow.blur)
        settings.style.shadow.opacity = clamp(style.shadow.opacity, 0...1, fallback: shadow.opacity)
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
                c.words = cue.words.filter { $0.start.isFinite && $0.end.isFinite }
                c.maxWidth = cue.maxWidth.map { clamp($0, EditLimits.subtitleMaxWidth, fallback: style.maxWidth) }
                return c
            }
            .sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
        return settings
    }
}
