import CoreGraphics
import CoreText
import Foundation
import ProjectKit

/// Subtitle geometry in **canvas pixels** (origin top-left, y down). Shared by the renderer (where to draw) and the
/// preview (hit-testing and dragging), so the box you drag is exactly the box that's drawn.
///
/// Sizes scale with the canvas height: font size = `style.size × height`, so every output size looks the same.
/// A cue's own `position` is the centre of its box in normalised canvas coordinates; otherwise the placement
/// anchor decides. Boxes are kept inside the canvas.
public enum SubtitleLayout {
    /// Box padding around the text, in ems.
    static let paddingX = 0.4
    static let paddingY = 0.18
    /// Box corner radius, in ems.
    static let cornerRadius = 0.22
    /// Padding and corner radius of the box behind a highlighted word (`SubtitleHighlightMode.box`), in ems. It
    /// stays inside the subtitle box's padding, so it needs no extra room.
    static let wordBoxPaddingX = 0.2
    static let wordBoxPaddingY = 0.2
    static let wordBoxCornerRadius = 0.16

    public struct Measured: Sendable, Equatable {
        public var fontSize: Double
        /// Size of the laid-out text.
        public var textSize: CGSize
        /// Size of the whole box (text + padding + room for a grown word).
        public var boxSize: CGSize
        /// Room in the box above and below the text for a grown word on the top or bottom line (canvas pixels).
        public var growAbove: Double = 0
        public var growBelow: Double = 0
    }

    public static func fontSize(_ style: SubtitleStyle, canvasSize: CGSize) -> Double {
        max(1, style.size * canvasSize.height)
    }

    /// The font for `style` at `size` points: the named family (with bold/italic traits when the family has
    /// them) or the system UI font.
    public static func font(_ style: SubtitleStyle, size: Double) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        let base: CTFont
        if let family = style.fontFamily, !family.isEmpty {
            let descriptor = CTFontDescriptorCreateWithAttributes(
                [kCTFontFamilyNameAttribute: family] as CFDictionary)
            base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        } else {
            base =
                CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    /// Centred, wrapped text in `font`.
    static func attributed(_ text: String, font: CTFont) -> NSAttributedString {
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            CTParagraphStyleCreate(
                [
                    CTParagraphStyleSetting(
                        spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
                ],
                1)
        }
        return NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
    }

    /// `string` filled in `textColor`, with the UTF-16 `range` in `highlight`. Every run gets an explicit colour:
    /// Core Text leaves the context's fill set to the last explicit colour it drew, so text after the highlighted
    /// word would otherwise inherit the highlight colour.
    static func highlighting(
        _ range: Range<Int>, in string: NSAttributedString, textColor: RGBAColor, highlight: RGBAColor
    ) -> NSAttributedString {
        let r = NSRange(location: range.lowerBound, length: range.count)
        guard range.lowerBound >= 0, NSMaxRange(r) <= string.length else { return string }
        let copy = NSMutableAttributedString(attributedString: string)
        let all = NSRange(location: 0, length: copy.length)
        let key = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        copy.removeAttribute(NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String), range: all)
        copy.addAttribute(key, value: cgColor(textColor), range: all)
        copy.addAttribute(key, value: cgColor(highlight), range: r)
        return copy
    }

    private static func cgColor(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// Lays out `text` wrapped to the style's maximum width.
    ///
    /// With `grow` > 0 (word highlighting that enlarges the spoken word by that fraction) the box also has room for
    /// whichever word is grown, so it keeps one size for the whole cue. A grown word scales about its centre and
    /// pushes the rest of its line apart by half its growth each side (see `SubtitleRasterCache.draw`), so a line
    /// can widen by its widest word's growth (outline included). It grows from the shared baseline, so a word on
    /// the top line rises by the growth of the ascent and one on the bottom line drops by the growth of the descent
    /// (`growAbove`, `growBelow`). The text keeps its layout (`textSize`, so the same line breaks), centred
    /// horizontally with that room above and below it.
    public static func measure(_ text: String, style: SubtitleStyle, canvasSize: CGSize, grow: Double = 0) -> Measured {
        let size = fontSize(style, canvasSize: canvasSize)
        let font = font(style, size: size)
        let maxText = max(size, style.maxWidth * canvasSize.width - 2 * paddingX * size)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text, font: font))
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: maxText, height: .greatestFiniteMagnitude),
            nil)
        let textSize = CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        let outline = style.outlineWidth * size
        let room =
            grow > 0
            ? growthRoom(framesetter, text: text, width: maxText, grow: grow, outline: outline)
            : (width: textSize.width, above: 0, below: 0)
        let above = ceil(room.above)
        let below = ceil(room.below)
        let box = CGSize(
            width: max(textSize.width, ceil(room.width)) + 2 * paddingX * size + 2 * outline,
            height: textSize.height + above + below + 2 * paddingY * size + 2 * outline)
        return Measured(fontSize: size, textSize: textSize, boxSize: box, growAbove: above, growBelow: below)
    }

    /// The widest any line gets with its widest word grown, and how far a grown word on the top line rises above
    /// the text and one on the bottom line drops below it.
    static func growthRoom(
        _ framesetter: CTFramesetter, text: String, width: Double, grow: Double, outline: Double
    ) -> (width: Double, above: Double, below: Double) {
        // The same line breaks as the fitted frame the renderer draws.
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 1_000_000), transform: nil), nil)
        let tokens = SubtitleWords.tokens(in: text)
        var widest = 0.0
        var maxAscent = 0.0
        var maxDescent = 0.0
        for line in CTFrameGetLines(frame) as? [CTLine] ?? [] {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let full = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            maxAscent = max(maxAscent, ascent)
            maxDescent = max(maxDescent, descent)
            let r = CTLineGetStringRange(line)
            let range = r.location..<(r.location + r.length)
            var word = 0.0
            for token in tokens where token.overlaps(range) {
                let a = CTLineGetOffsetForStringIndex(line, max(token.lowerBound, range.lowerBound), nil)
                let b = CTLineGetOffsetForStringIndex(line, min(token.upperBound, range.upperBound), nil)
                word = max(word, abs(b - a))
            }
            let visible = full - CTLineGetTrailingWhitespaceWidth(line)
            widest = max(widest, visible + grow * (word + 2 * outline))
        }
        return (widest, grow * (maxAscent + outline), grow * (maxDescent + outline))
    }

    /// How much `cue`'s spoken word grows in `style`: 0 when the cue can't be highlighted (no word timing), so its
    /// box doesn't make room for a growth that never happens.
    public static func grow(for cue: SubtitleCue, style: SubtitleStyle) -> Double {
        style.highlightWords && !cue.words.isEmpty ? style.highlightGrow : 0
    }

    /// Centre of a box of `boxSize` for the placement (canvas pixels).
    public static func defaultCenter(_ placement: SubtitlePlacement, boxSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let x = canvasSize.width / 2
        let margin = placement.margin * canvasSize.height
        let y: Double =
            switch placement.anchor {
            case .bottom: canvasSize.height - margin - boxSize.height / 2
            case .middle: canvasSize.height / 2
            case .top: margin + boxSize.height / 2
            }
        return CGPoint(x: x, y: y)
    }

    /// The box for `cue`, clamped inside the canvas. `measured` must be of the style's display text.
    public static func frame(
        for cue: SubtitleCue, settings: SubtitleSettings, canvasSize: CGSize, measured: Measured? = nil
    ) -> CGRect {
        let style = settings.style(for: cue)
        let m =
            measured
            ?? measure(
                style.displayText(cue.text), style: style, canvasSize: canvasSize, grow: grow(for: cue, style: style))
        let center: CGPoint =
            cue.position.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
            ?? defaultCenter(settings.placement, boxSize: m.boxSize, canvasSize: canvasSize)
        return clamped(
            CGRect(
                x: center.x - m.boxSize.width / 2, y: center.y - m.boxSize.height / 2, width: m.boxSize.width,
                height: m.boxSize.height), in: canvasSize)
    }

    /// The `maxWidth` (fraction of the canvas width) whose longest line gives a box `boxWidth` canvas pixels wide:
    /// the inverse of ``measure(_:style:canvasSize:)`` when the text fills its width. Clamped to the limits.
    public static func maxWidth(forBoxWidth boxWidth: Double, style: SubtitleStyle, canvasSize: CGSize) -> Double {
        let outline = style.outlineWidth * fontSize(style, canvasSize: canvasSize)
        let fraction = (boxWidth - 2 * outline) / max(canvasSize.width, 1)
        return min(max(fraction, EditLimits.subtitleMaxWidth.lowerBound), EditLimits.subtitleMaxWidth.upperBound)
    }

    /// Normalised centre for a box dragged to `frame` (what gets stored in `SubtitleCue.position`).
    public static func position(forFrame frame: CGRect, canvasSize: CGSize) -> NormPoint {
        let f = clamped(frame, in: canvasSize)
        return NormPoint(x: f.midX / max(canvasSize.width, 1), y: f.midY / max(canvasSize.height, 1))
    }

    static func clamped(_ rect: CGRect, in canvas: CGSize) -> CGRect {
        var r = rect
        r.origin.x = min(max(r.minX, 0), max(0, canvas.width - r.width))
        r.origin.y = min(max(r.minY, 0), max(0, canvas.height - r.height))
        return r
    }
}
