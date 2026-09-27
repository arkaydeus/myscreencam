import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ProjectKit

/// Rasterises one subtitle box (background, outline, text) with Core Text, once per text/style/canvas size and
/// highlighted word. Frames then only place the cached image, so subtitles cost a GPU composite per frame, not text
/// layout; with word highlighting a new raster is drawn only when the spoken word changes.
final class SubtitleRasterCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let text: String
        let style: SubtitleStyle
        let width: Int
        let height: Int
        /// How much a highlighted word grows (the box has room for it whichever word is lit).
        let grow: Double
        /// UTF-16 range of the highlighted word.
        let highlight: Range<Int>?
    }

    struct Raster: @unchecked Sendable {
        /// The box image with the box's origin at (`bleed`, `bleed`) (Core Image space).
        let image: CIImage
        let measured: SubtitleLayout.Measured
        /// Room around the box for the shadow and a grown word.
        let bleed: CGFloat
    }

    /// Enough for every cue on screen across several recent styles; cleared wholesale beyond it.
    static let capacity = 96
    private let lock = NSLock()
    private var storage: [Key: Raster] = [:]

    func raster(
        text: String, style: SubtitleStyle, canvasSize: CGSize, grow: Double = 0, highlight: Range<Int>? = nil
    ) -> Raster? {
        let key = Key(
            text: text, style: style, width: Int(canvasSize.width), height: Int(canvasSize.height), grow: grow,
            highlight: highlight)
        if let cached = lock.withLock({ storage[key] }) { return cached }
        guard
            let raster = Self.render(
                text: text, style: style, canvasSize: canvasSize, grow: grow, highlight: highlight)
        else { return nil }
        lock.withLock {
            if storage.count >= Self.capacity { storage.removeAll(keepingCapacity: true) }
            storage[key] = raster
        }
        return raster
    }

    /// `grow` sizes the box for any word grown (so it's the same whichever word is lit); `highlight` is the word
    /// drawn in the highlight colour, grown by `grow`.
    static func render(
        text: String, style: SubtitleStyle, canvasSize: CGSize, grow: Double = 0, highlight: Range<Int>? = nil
    ) -> Raster? {
        let measured = SubtitleLayout.measure(text, style: style, canvasSize: canvasSize, grow: grow)
        let box = measured.boxSize
        let bleed = ceil(Self.bleed(style: style, grow: grow, measured: measured))
        let width = Int(ceil(box.width + 2 * bleed))
        let height = Int(ceil(box.height + 2 * bleed))
        guard width > 0, height > 0, width < 16_384, height < 16_384,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let size = measured.fontSize
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.textMatrix = .identity
        // Box coordinates from here on.
        ctx.translateBy(x: bleed, y: bleed)

        if style.background, style.backgroundOpacity > 0 {
            let c = style.backgroundColor
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: style.backgroundOpacity))
            let radius = min(SubtitleLayout.cornerRadius * size, box.height / 2)
            ctx.addPath(
                CGPath(
                    roundedRect: CGRect(x: 0, y: 0, width: box.width, height: box.height), cornerWidth: radius,
                    cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }

        let font = SubtitleLayout.font(style, size: size)
        // Centred, with the room for a grown word above and below it (Core Graphics' y points up).
        let textRect = CGRect(
            x: (box.width - measured.textSize.width) / 2,
            y: (box.height - measured.textSize.height - measured.growAbove - measured.growBelow) / 2
                + measured.growBelow,
            width: measured.textSize.width, height: measured.textSize.height)
        func frame(_ string: NSAttributedString) -> CTFrame {
            CTFramesetterCreateFrame(
                CTFramesetterCreateWithAttributedString(string), CFRange(location: 0, length: 0),
                CGPath(rect: textRect, transform: nil), nil)
        }
        let plain = SubtitleLayout.attributed(text, font: font)
        let t = style.textColor
        let grown = highlight.flatMap { grow > 0 ? (range: $0, scale: 1 + grow) : nil }

        // One shadow for the text and its outline together (a transparency layer), not one per pass.
        let shadow = style.shadow
        let shadowed = shadow.enabled && shadow.opacity > 0
        if shadowed {
            let offset = shadow.offset
            let c = shadow.color
            // Shadow offsets are in the bitmap's base space, where y points up.
            ctx.setShadow(
                offset: CGSize(width: offset.dx * size, height: -offset.dy * size), blur: shadow.blur * size,
                color: CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * shadow.opacity))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        let outline = style.outlineWidth * size
        if outline > 0.05 {
            // The stroke is centred on the glyph edge; the fill drawn on top hides the inner half.
            let o = style.outlineColor
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineWidth(outline * 2)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(CGColor(srgbRed: o.r, green: o.g, blue: o.b, alpha: o.a))
            draw(frame(plain), in: ctx, grown: grown)
        }
        ctx.setTextDrawingMode(.fill)
        ctx.setFillColor(CGColor(srgbRed: t.r, green: t.g, blue: t.b, alpha: t.a))
        // Colour only changes the fill, never the layout, so the highlighted word sits exactly on its outline.
        let filled = highlight.map {
            SubtitleLayout.highlighting($0, in: plain, textColor: t, highlight: style.highlightColor)
        }
        draw(frame(filled ?? plain), in: ctx, grown: grown)

        if shadowed { ctx.endTransparencyLayer() }

        guard let image = ctx.makeImage() else { return nil }
        return Raster(
            image: CIImage(cgImage: image).insertingIntermediate(cache: true), measured: measured, bleed: bleed)
    }

    /// How far drawing can reach outside the box: the shadow's offset and blur, plus a margin for a grown word.
    /// The box already has room for any grown word (`SubtitleLayout.measure`); the margin only keeps ink that
    /// typographic bounds miss (italic overhang, glyph ink beyond advances) from being clipped.
    static func bleed(style: SubtitleStyle, grow: Double, measured: SubtitleLayout.Measured) -> CGFloat {
        let size = measured.fontSize
        var bleed = grow * size
        if style.shadow.enabled { bleed += (style.shadow.distance + 2 * style.shadow.blur) * size }
        return bleed
    }

    /// Draws `frame` like `CTFrameDraw`, except that on each line the glyphs of the UTF-16 `grown.range` are drawn
    /// `grown.scale` times bigger, centred horizontally on itself and sitting on the line's baseline (so it grows
    /// upwards, with only descenders reaching lower), and the words either side of it on that line move apart by
    /// half the extra width each (so nothing overlaps and the line stays centred). Line breaks and the box don't
    /// change; the raster's bleed has room for the wider line.
    static func draw(_ frame: CTFrame, in ctx: CGContext, grown: (range: Range<Int>, scale: Double)?) {
        guard let grown else {
            CTFrameDraw(frame, ctx)
            return
        }
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let rect = CTFrameGetPath(frame).boundingBoxOfPath
        for (line, lineOrigin) in zip(lines, origins) {
            let origin = CGPoint(x: rect.minX + lineOrigin.x, y: rect.minY + lineOrigin.y)
            var normal: [(run: CTRun, range: CFRange, x: CGFloat)] = []
            var big: [(CTRun, CFRange)] = []
            var minX = CGFloat.infinity
            var maxX = -CGFloat.infinity
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                // Split the run into consecutive glyphs inside and outside the grown word.
                var start = 0
                while start < count {
                    let inside = grown.range.contains(indices[start])
                    var end = start + 1
                    while end < count, grown.range.contains(indices[end]) == inside { end += 1 }
                    let range = CFRange(location: start, length: end - start)
                    if inside {
                        big.append((run, range))
                        let width = CTRunGetTypographicBounds(run, range, nil, nil, nil)
                        minX = min(minX, positions[start].x)
                        maxX = max(maxX, positions[start].x + width)
                    } else {
                        normal.append((run, range, positions[start].x))
                    }
                    start = end
                }
            }
            let extra = big.isEmpty ? 0 : (grown.scale - 1) * (maxX - minX)
            for part in normal {
                let shift = big.isEmpty ? 0 : (part.x < minX ? -extra / 2 : extra / 2)
                ctx.textPosition = CGPoint(x: origin.x + shift, y: origin.y)
                CTRunDraw(part.run, ctx, part.range)
            }
            guard !big.isEmpty else { continue }
            // Scale about the word's centre on the baseline, so it shares the baseline with the rest of the line.
            let center = CGPoint(x: origin.x + (minX + maxX) / 2, y: origin.y)
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: grown.scale, y: grown.scale)
            ctx.translateBy(x: -center.x, y: -center.y)
            for (run, range) in big {
                ctx.textPosition = origin
                CTRunDraw(run, ctx, range)
            }
            ctx.restoreGState()
        }
    }
}

enum SubtitleRenderer {
    /// Draws the cues active at source time `t` over `output` (canvas space, Core Image coordinates).
    static func draw(over output: CIImage, snapshot: RenderSnapshot, t: Double) -> CIImage {
        let settings = snapshot.edit.subtitles
        let cues = settings.activeCues(at: t)
        guard !cues.isEmpty else { return output }
        let canvas = snapshot.layout.canvasSize
        var output = output
        for cue in cues {
            // Highlight ranges index the text as drawn (uppercasing can change its length, e.g. ß → SS).
            let style = settings.style(for: cue)
            let text = style.displayText(cue.text)
            let highlight =
                style.highlightWords ? SubtitleWords.highlightedRange(in: text, words: cue.words, at: t) : nil
            guard
                let raster = snapshot.resources.subtitleRasters.raster(
                    text: text, style: style, canvasSize: canvas, grow: SubtitleLayout.grow(for: cue, style: style),
                    highlight: highlight)
            else { continue }
            let frame = SubtitleLayout.frame(
                for: cue, settings: settings, canvasSize: canvas, measured: raster.measured)
            let ci = CIHelpers.flip(frame, height: canvas.height)
            output = raster.image.transformed(
                by: CGAffineTransform(translationX: ci.minX - raster.bleed, y: ci.minY - raster.bleed)
            )
            .composited(over: output)
        }
        return output
    }
}
