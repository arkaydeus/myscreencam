import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ProjectKit

/// Rasterises one subtitle box (background, outline, text) with Core Text, once per text/style/canvas size.
/// Frames then only place the cached image, so subtitles cost a GPU composite per frame, not text layout.
final class SubtitleRasterCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let text: String
        let style: SubtitleStyle
        let width: Int
        let height: Int
    }

    struct Raster: @unchecked Sendable {
        /// The box image with its origin at zero (Core Image space).
        let image: CIImage
        let measured: SubtitleLayout.Measured
    }

    /// Enough for every cue on screen across several recent styles; cleared wholesale beyond it.
    static let capacity = 96
    private let lock = NSLock()
    private var storage: [Key: Raster] = [:]

    func raster(text: String, style: SubtitleStyle, canvasSize: CGSize) -> Raster? {
        let key = Key(text: text, style: style, width: Int(canvasSize.width), height: Int(canvasSize.height))
        if let cached = lock.withLock({ storage[key] }) { return cached }
        guard let raster = Self.render(text: text, style: style, canvasSize: canvasSize) else { return nil }
        lock.withLock {
            if storage.count >= Self.capacity { storage.removeAll(keepingCapacity: true) }
            storage[key] = raster
        }
        return raster
    }

    static func render(text: String, style: SubtitleStyle, canvasSize: CGSize) -> Raster? {
        let measured = SubtitleLayout.measure(text, style: style, canvasSize: canvasSize)
        let box = measured.boxSize
        let width = Int(ceil(box.width))
        let height = Int(ceil(box.height))
        guard width > 0, height > 0, width < 16_384, height < 16_384,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let size = measured.fontSize
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)

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
        let framesetter = CTFramesetterCreateWithAttributedString(SubtitleLayout.attributed(text, font: font))
        let textRect = CGRect(
            x: (box.width - measured.textSize.width) / 2, y: (box.height - measured.textSize.height) / 2,
            width: measured.textSize.width, height: measured.textSize.height)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)

        let outline = style.outlineWidth * size
        if outline > 0.05 {
            // The stroke is centred on the glyph edge; the fill drawn on top hides the inner half.
            let o = style.outlineColor
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineWidth(outline * 2)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(CGColor(srgbRed: o.r, green: o.g, blue: o.b, alpha: o.a))
            CTFrameDraw(frame, ctx)
        }
        let t = style.textColor
        ctx.setTextDrawingMode(.fill)
        ctx.setFillColor(CGColor(srgbRed: t.r, green: t.g, blue: t.b, alpha: t.a))
        CTFrameDraw(frame, ctx)

        guard let image = ctx.makeImage() else { return nil }
        return Raster(image: CIImage(cgImage: image).insertingIntermediate(cache: true), measured: measured)
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
            guard
                let raster = snapshot.resources.subtitleRasters.raster(
                    text: cue.text, style: settings.style, canvasSize: canvas)
            else { continue }
            let frame = SubtitleLayout.frame(
                for: cue, settings: settings, canvasSize: canvas, measured: raster.measured)
            let ci = CIHelpers.flip(frame, height: canvas.height)
            output = raster.image.transformed(by: CGAffineTransform(translationX: ci.minX, y: ci.minY))
                .composited(over: output)
        }
        return output
    }
}
