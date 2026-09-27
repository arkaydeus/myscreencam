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

    public struct Measured: Sendable, Equatable {
        public var fontSize: Double
        /// Size of the laid-out text.
        public var textSize: CGSize
        /// Size of the whole box (text + padding).
        public var boxSize: CGSize
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

    /// Lays out `text` wrapped to the style's maximum width.
    public static func measure(_ text: String, style: SubtitleStyle, canvasSize: CGSize) -> Measured {
        let size = fontSize(style, canvasSize: canvasSize)
        let font = font(style, size: size)
        let maxText = max(size, style.maxWidth * canvasSize.width - 2 * paddingX * size)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text, font: font))
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: maxText, height: .greatestFiniteMagnitude),
            nil)
        let textSize = CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        let outline = style.outlineWidth * size
        let box = CGSize(
            width: textSize.width + 2 * paddingX * size + 2 * outline,
            height: textSize.height + 2 * paddingY * size + 2 * outline)
        return Measured(fontSize: size, textSize: textSize, boxSize: box)
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

    /// The box for `cue`, clamped inside the canvas.
    public static func frame(
        for cue: SubtitleCue, settings: SubtitleSettings, canvasSize: CGSize, measured: Measured? = nil
    ) -> CGRect {
        let m = measured ?? measure(cue.text, style: settings.style, canvasSize: canvasSize)
        let center: CGPoint =
            cue.position.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
            ?? defaultCenter(settings.placement, boxSize: m.boxSize, canvasSize: canvasSize)
        return clamped(
            CGRect(
                x: center.x - m.boxSize.width / 2, y: center.y - m.boxSize.height / 2, width: m.boxSize.width,
                height: m.boxSize.height), in: canvasSize)
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
