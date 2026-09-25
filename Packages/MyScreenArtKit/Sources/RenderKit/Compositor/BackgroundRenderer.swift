import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ProjectKit

/// Core Image helpers shared by the compositor.
enum CIHelpers {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let itur709 = CGColorSpace(name: CGColorSpace.itur_709)!

    /// An sRGB colour with its alpha multiplied by `opacity`.
    static func color(_ c: RGBAColor, opacity: Double = 1) -> CIColor {
        CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * opacity, colorSpace: sRGB)
            ?? CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * opacity)
    }

    /// Converts a y-down rect in a space of height `height` to Core Image's y-up space.
    static func flip(_ rect: CGRect, height: Double) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// An anti-aliased filled rounded rect (`rect` in Core Image space).
    static func roundedRect(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        let r = min(max(radius, 0), min(rect.width, rect.height) / 2)
        if r < 0.5 { return CIImage(color: color).cropped(to: rect) }
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(r)
        filter.color = color
        return filter.outputImage?.cropped(to: rect.insetBy(dx: -1, dy: -1)) ?? CIImage(color: color).cropped(to: rect)
    }

    /// `image` shown only where `mask` is opaque (both in the same space).
    static func masked(_ image: CIImage, by mask: CIImage) -> CIImage {
        let filter = CIFilter.sourceInCompositing()
        filter.inputImage = image
        filter.backgroundImage = mask
        return filter.outputImage ?? image
    }

    /// Multiplies `image`'s alpha by `opacity`.
    static func fade(_ image: CIImage, opacity: Double) -> CIImage {
        if opacity >= 0.999 { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity)))
        return filter.outputImage ?? image
    }

    /// A soft drop shadow of `shape` (its alpha), blurred by `sigma`, moved down by `offsetDown`, at `opacity`.
    static func shadow(of shape: CIImage, sigma: Double, offsetDown: Double, opacity: Double) -> CIImage {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: sRGB) ?? .black)
        let silhouette = masked(black, by: shape)
        return fade(silhouette, opacity: opacity)
            .applyingGaussianBlur(sigma: sigma)
            .transformed(by: CGAffineTransform(translationX: 0, y: -offsetDown))
    }

    /// Scales `image` by `sx`/`sy`; Lanczos when shrinking a lot, bilinear otherwise.
    static func scaled(_ image: CIImage, sx: Double, sy: Double, highQuality: Bool) -> CIImage {
        if highQuality, sx < 0.75, sy < 0.75 {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(sy)
            filter.aspectRatio = Float(sx / sy)
            if let output = filter.outputImage { return output }
        }
        return image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }
}

/// Builds the static background layer (fill + content shadow) and the content corner mask for a layout.
struct BackgroundRenderer {
    let layout: CanvasLayout
    let settings: BackgroundSettings
    let resources: ProjectResources

    private var canvasRect: CGRect { CGRect(origin: .zero, size: layout.canvasSize) }
    private var contentRectCI: CGRect { CIHelpers.flip(layout.contentRect, height: layout.canvasSize.height) }

    /// Fill plus the content's drop shadow, cached as a GPU intermediate. Nil when the background is off.
    func backgroundLayer() -> CIImage? {
        guard settings.enabled else { return nil }
        var layer = fill()
        let strength = min(max(settings.shadow, 0), 1)
        if strength > 0 {
            let unit = layout.outputUnit
            let shape = CIHelpers.roundedRect(
                contentRectCI, radius: layout.contentCornerRadius(settings), color: CIColor(red: 0, green: 0, blue: 0))
            let shadow = CIHelpers.shadow(
                of: shape, sigma: 28 * unit * (0.5 + strength), offsetDown: 12 * unit, opacity: 0.65 * strength)
            layer = shadow.composited(over: layer)
        }
        return layer.cropped(to: canvasRect).insertingIntermediate(cache: true)
    }

    /// Alpha mask for rounded content corners, or nil when they're square.
    func contentMask() -> CIImage? {
        let radius = layout.contentCornerRadius(settings)
        guard settings.enabled, radius >= 0.5 else { return nil }
        return CIHelpers.roundedRect(contentRectCI, radius: radius, color: CIColor(red: 1, green: 1, blue: 1))
            .insertingIntermediate(cache: true)
    }

    private func fill() -> CIImage {
        let rect = canvasRect
        switch settings.fill {
        case .solid(let color):
            return CIImage(color: CIHelpers.color(color)).cropped(to: rect)
        case .linearGradient(let from, let to, let angle):
            // 0° = left→right, 90° = top→bottom (y down); Core Image is y up.
            let radians = angle * .pi / 180
            let dx = cos(radians)
            let dy = -sin(radians)
            let length = abs(rect.width * dx) + abs(rect.height * dy)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let filter = CIFilter.linearGradient()
            filter.point0 = CGPoint(x: center.x - dx * length / 2, y: center.y - dy * length / 2)
            filter.point1 = CGPoint(x: center.x + dx * length / 2, y: center.y + dy * length / 2)
            filter.color0 = CIHelpers.color(from)
            filter.color1 = CIHelpers.color(to)
            return (filter.outputImage ?? CIImage(color: CIHelpers.color(from))).cropped(to: rect)
        case .image(let path):
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
            guard let image = resources.imageFill(path: path), image.extent.width > 0, image.extent.height > 0
            else { return black }
            let e = image.extent
            let s = max(rect.width / e.width, rect.height / e.height)
            let placed = CIHelpers.scaled(
                image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)), sx: s, sy: s,
                highQuality: true)
            let w = e.width * s
            let h = e.height * s
            return placed.transformed(
                by: CGAffineTransform(translationX: (rect.width - w) / 2, y: (rect.height - h) / 2)
            )
            .composited(over: black).cropped(to: rect)
        }
    }
}
