import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ProjectKit

/// Rasterises one subtitle box (background, outline, text) with Core Text, once per text/style/canvas size and
/// highlighted word. Frames then only place the cached image, so subtitles cost a GPU composite per frame, not text
/// layout; with word highlighting or dimmed upcoming words a new raster is drawn only when the spoken word changes.
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
        /// UTF-16 offset where the dimmed words not spoken yet begin.
        let spoken: Int?
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
        text: String, style: SubtitleStyle, canvasSize: CGSize, grow: Double = 0, highlight: Range<Int>? = nil,
        spoken: Int? = nil
    ) -> Raster? {
        let key = Key(
            text: text, style: style, width: Int(canvasSize.width), height: Int(canvasSize.height), grow: grow,
            highlight: highlight, spoken: spoken)
        if let cached = lock.withLock({ storage[key] }) { return cached }
        guard
            let raster = Self.render(
                text: text, style: style, canvasSize: canvasSize, grow: grow, highlight: highlight, spoken: spoken)
        else { return nil }
        lock.withLock {
            if storage.count >= Self.capacity { storage.removeAll(keepingCapacity: true) }
            storage[key] = raster
        }
        return raster
    }

    /// `grow` sizes the box for any word grown (so it's the same whichever word is lit); `highlight` is the word
    /// drawn in the highlight colour (or on a box of it), grown by `grow`. With `style.dimUpcoming`, the text from
    /// the UTF-16 offset `spoken` on is drawn at the style's upcoming opacity.
    static func render(
        text: String, style: SubtitleStyle, canvasSize: CGSize, grow: Double = 0, highlight: Range<Int>? = nil,
        spoken: Int? = nil
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
        let plain = frame(SubtitleLayout.attributed(text, font: font))
        let t = style.textColor
        let scale = 1 + grow
        let outline = style.outlineWidth * size

        // One shadow for the text, its outline and the word's box together (a transparency layer), not one per pass.
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

        // The word's box sits under the text.
        if let highlight, style.highlightMode == .box {
            let c = style.highlightColor
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a))
            for rect in wordBoxes(plain, word: highlight, scale: scale, font: font, outline: outline) {
                let radius = min(SubtitleLayout.wordBoxCornerRadius * size * scale, rect.height / 2)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
            ctx.fillPath()
        }

        // Colour only changes the fill, never the layout, so the highlighted word sits exactly on its outline.
        let filled =
            style.highlightMode == .text
            ? highlight.map {
                frame(
                    SubtitleLayout.highlighting(
                        $0, in: SubtitleLayout.attributed(text, font: font), textColor: t,
                        highlight: style.highlightColor))
            } : nil
        /// Outline, then fill, of the glyphs in the UTF-16 range `glyphs` (nil = all).
        func drawText(_ glyphs: Range<Int>?) {
            if outline > 0.05 {
                // The stroke is centred on the glyph edge; the fill drawn on top hides the inner half.
                let o = style.outlineColor
                ctx.setTextDrawingMode(.stroke)
                ctx.setLineWidth(outline * 2)
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(CGColor(srgbRed: o.r, green: o.g, blue: o.b, alpha: o.a))
                draw(plain, in: ctx, word: highlight, scale: scale, glyphs: glyphs)
            }
            ctx.setTextDrawingMode(.fill)
            ctx.setFillColor(CGColor(srgbRed: t.r, green: t.g, blue: t.b, alpha: t.a))
            draw(filled ?? plain, in: ctx, word: highlight, scale: scale, glyphs: glyphs)
        }
        if let spoken, style.dimUpcoming, style.upcomingOpacity < 1 {
            drawText(0..<spoken)
            // Faded as a whole (a transparency layer), so the outline doesn't show through the faded fill.
            ctx.setAlpha(style.upcomingOpacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawText(spoken..<Int.max)
            ctx.endTransparencyLayer()
            ctx.setAlpha(1)
        } else {
            drawText(nil)
        }

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

    /// One line of a frame, split into pieces of consecutive glyphs that are all inside or all outside a word and a
    /// glyph range (UTF-16 ranges).
    struct Line {
        var origin: CGPoint
        var pieces: [(run: CTRun, range: CFRange, x: CGFloat, index: Int, inWord: Bool)] = []
        /// Where the word's glyphs start and end on the line, from its origin.
        var word: (minX: CGFloat, maxX: CGFloat)?
    }

    static func lines(_ frame: CTFrame, word: Range<Int>?, glyphs: Range<Int>? = nil) -> [Line] {
        let ctLines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let rect = CTFrameGetPath(frame).boundingBoxOfPath
        return zip(ctLines, origins).map { ctLine, lineOrigin in
            var line = Line(origin: CGPoint(x: rect.minX + lineOrigin.x, y: rect.minY + lineOrigin.y))
            for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                func kind(_ k: Int) -> (Bool, Bool) {
                    (word?.contains(indices[k]) ?? false, glyphs?.contains(indices[k]) ?? true)
                }
                var start = 0
                while start < count {
                    let first = kind(start)
                    var end = start + 1
                    while end < count, kind(end) == first { end += 1 }
                    let range = CFRange(location: start, length: end - start)
                    let x = positions[start].x
                    if first.0 {
                        let width = CTRunGetTypographicBounds(run, range, nil, nil, nil)
                        let w = line.word ?? (.infinity, -.infinity)
                        line.word = (min(w.minX, x), max(w.maxX, x + width))
                    }
                    line.pieces.append((run, range, x, indices[start], first.0))
                    start = end
                }
            }
            return line
        }
    }

    /// Draws `frame` like `CTFrameDraw`, but only the glyphs of the UTF-16 range `glyphs` (nil = all), and with the
    /// glyphs of `word` drawn `scale` times bigger, centred horizontally on itself and sitting on the line's
    /// baseline (so it grows upwards, with only descenders reaching lower). The words either side of it on that
    /// line move apart by half the extra width each (so nothing overlaps and the line stays centred). Line breaks
    /// and the box don't change; the raster's bleed has room for the wider line.
    static func draw(_ frame: CTFrame, in ctx: CGContext, word: Range<Int>?, scale: Double, glyphs: Range<Int>? = nil) {
        let grown = scale == 1 ? nil : word
        guard grown != nil || glyphs != nil else {
            CTFrameDraw(frame, ctx)
            return
        }
        for line in lines(frame, word: grown, glyphs: glyphs) {
            let extra = line.word.map { (scale - 1) * ($0.maxX - $0.minX) } ?? 0
            for piece in line.pieces where glyphs?.contains(piece.index) ?? true {
                if piece.inWord, let w = line.word {
                    // Scale about the word's centre on the baseline, so it shares the baseline with the rest of the
                    // line.
                    let center = CGPoint(x: line.origin.x + (w.minX + w.maxX) / 2, y: line.origin.y)
                    ctx.saveGState()
                    ctx.translateBy(x: center.x, y: center.y)
                    ctx.scaleBy(x: scale, y: scale)
                    ctx.translateBy(x: -center.x, y: -center.y)
                    ctx.textPosition = line.origin
                    CTRunDraw(piece.run, ctx, piece.range)
                    ctx.restoreGState()
                } else {
                    let shift = line.word.map { piece.x < $0.minX ? -extra / 2 : extra / 2 } ?? 0
                    ctx.textPosition = CGPoint(x: line.origin.x + shift, y: line.origin.y)
                    CTRunDraw(piece.run, ctx, piece.range)
                }
            }
        }
    }

    /// The rounded box behind `word` on each line it's on (bitmap space): centred on the letters (baseline to cap
    /// height) with the same padding above and below, plus room for the outline, grown by `scale` about the word's
    /// centre on the baseline like the word.
    static func wordBoxes(
        _ frame: CTFrame, word: Range<Int>, scale: Double, font: CTFont, outline: Double
    ) -> [CGRect] {
        let size = CTFontGetSize(font)
        let padX = SubtitleLayout.wordBoxPaddingX * size + outline
        let padY = SubtitleLayout.wordBoxPaddingY * size + outline
        let above = CTFontGetCapHeight(font) + padY
        let below = padY
        return lines(frame, word: word).compactMap { line in
            guard let w = line.word else { return nil }
            let halfWidth = ((w.maxX - w.minX) / 2 + padX) * scale
            return CGRect(
                x: line.origin.x + (w.minX + w.maxX) / 2 - halfWidth, y: line.origin.y - below * scale,
                width: 2 * halfWidth, height: (above + below) * scale)
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
            let progress =
                style.highlightWords || style.dimUpcoming
                ? SubtitleWords.progress(in: text, words: cue.words, at: t) : nil
            guard
                let raster = snapshot.resources.subtitleRasters.raster(
                    text: text, style: style, canvasSize: canvas, grow: SubtitleLayout.grow(for: cue, style: style),
                    highlight: style.highlightWords ? progress?.highlight : nil,
                    spoken: style.dimUpcoming ? progress?.spoken : nil)
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
