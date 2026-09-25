import AppKit
import CoreImage
import Foundation
import ImageIO
import ProjectKit

/// A rasterised cursor image ready to composite.
struct CursorSprite: Sendable {
    /// Image with its extent at the origin, in pixels (Core Image, y up).
    let image: CIImage
    /// Hotspot in pixels from the image's top-left corner (y down).
    let hotspot: CGPoint
    /// Pixel size of `image`.
    let size: CGSize
}

/// Which cursor image to draw.
enum CursorArtKey: Hashable, Sendable {
    /// The captured system cursor `cursors/<id>.png`.
    case captured(Int)
    /// Bundled (or generated) stylised artwork.
    case artwork(CursorKind)
}

/// Bundled stylised cursor artwork. The SVGs use a 32×32 view box; `pointSize` maps that box to points.
enum CursorArtwork {
    /// Size of the 32-unit artwork box in points (the arrow is then about 21 pt tall, like macOS).
    static let pointSize = 28.0

    /// Hotspot in SVG units (y down).
    static func hotspot(for kind: CursorKind) -> CGPoint {
        switch kind {
        case .arrow, .operationNotAllowed, .dragCopy, .contextualMenu, .other: CGPoint(x: 4, y: 4)
        case .pointingHand: CGPoint(x: 15, y: 3)
        case .iBeam, .crosshair, .openHand, .closedHand, .resizeLeftRight, .resizeUpDown, .resizeDiagonal:
            CGPoint(x: 16, y: 16)
        }
    }

    /// Whether stylised artwork exists for `kind` (`.other` falls back to the captured image).
    static func hasArtwork(for kind: CursorKind) -> Bool { kind != .other }

    /// SVG source for `kind`: the bundled file for arrow / pointingHand / iBeam, generated artwork otherwise.
    static func svgData(for kind: CursorKind) -> Data? {
        switch kind {
        case .arrow, .pointingHand, .iBeam:
            guard
                let url = Bundle.module.url(forResource: kind.rawValue, withExtension: "svg", subdirectory: "Cursors")
                    ?? Bundle.module.url(forResource: kind.rawValue, withExtension: "svg")
            else { return nil }
            return try? Data(contentsOf: url)
        default:
            return generatedSVG(for: kind).data(using: .utf8)
        }
    }

    private static let arrowPath = "M4 4 L4 26 L10 20 L14 28 L18 26 L14 18 L22 18 Z"
    private static let doubleArrowPath =
        "M3 16 L9 10 L9 13.5 L23 13.5 L23 10 L29 16 L23 22 L23 18.5 L9 18.5 L9 22 Z"

    /// Outline-then-fill so overlapping shapes read as one silhouette.
    private static func silhouette(_ shapes: [String]) -> String {
        let outlines = shapes.map {
            $0.replacingOccurrences(
                of: "/>", with: " fill=\"black\" stroke=\"black\" stroke-width=\"3\" stroke-linejoin=\"round\"/>")
        }
        let fills = shapes.map { $0.replacingOccurrences(of: "/>", with: " fill=\"white\"/>") }
        return (outlines + fills).joined()
    }

    private static func svg(_ body: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\" width=\"32\" height=\"32\">\(body)</svg>"
    }

    private static var arrowBody: String {
        "<path d=\"\(arrowPath)\" fill=\"white\" stroke=\"black\" stroke-width=\"1.5\" stroke-linejoin=\"round\"/>"
    }

    static func generatedSVG(for kind: CursorKind) -> String {
        switch kind {
        case .crosshair:
            return svg(
                "<path d=\"M16 3 L16 29 M3 16 L29 16\" stroke=\"white\" stroke-width=\"4\" stroke-linecap=\"round\"/>"
                    + "<path d=\"M16 3 L16 29 M3 16 L29 16\" stroke=\"black\" stroke-width=\"1.5\" stroke-linecap=\"round\"/>"
            )
        case .resizeLeftRight, .resizeUpDown, .resizeDiagonal:
            let angle = kind == .resizeLeftRight ? 0 : kind == .resizeUpDown ? 90 : 45
            return svg(
                "<g transform=\"rotate(\(angle) 16 16)\"><path d=\"\(doubleArrowPath)\" fill=\"white\" stroke=\"black\" "
                    + "stroke-width=\"1.5\" stroke-linejoin=\"round\"/></g>")
        case .openHand:
            return svg(
                silhouette([
                    "<rect x=\"8\" y=\"14\" width=\"17\" height=\"14\" rx=\"6\"/>",
                    "<rect x=\"8.5\" y=\"7\" width=\"3.5\" height=\"12\" rx=\"1.75\"/>",
                    "<rect x=\"12.5\" y=\"4\" width=\"3.5\" height=\"14\" rx=\"1.75\"/>",
                    "<rect x=\"16.5\" y=\"4.5\" width=\"3.5\" height=\"14\" rx=\"1.75\"/>",
                    "<rect x=\"20.5\" y=\"7\" width=\"3.5\" height=\"12\" rx=\"1.75\"/>",
                    "<rect x=\"3\" y=\"15\" width=\"9\" height=\"3.5\" rx=\"1.75\" transform=\"rotate(35 7 17)\"/>",
                ]))
        case .closedHand:
            return svg(
                silhouette([
                    "<rect x=\"8\" y=\"12\" width=\"17\" height=\"15\" rx=\"6\"/>",
                    "<rect x=\"8.5\" y=\"10\" width=\"3.5\" height=\"6\" rx=\"1.75\"/>",
                    "<rect x=\"12.5\" y=\"9\" width=\"3.5\" height=\"6\" rx=\"1.75\"/>",
                    "<rect x=\"16.5\" y=\"9\" width=\"3.5\" height=\"6\" rx=\"1.75\"/>",
                    "<rect x=\"20.5\" y=\"10\" width=\"3.5\" height=\"6\" rx=\"1.75\"/>",
                ]))
        case .operationNotAllowed:
            return svg(
                arrowBody + "<circle cx=\"23\" cy=\"23\" r=\"6\" fill=\"white\" stroke=\"#D92D20\" stroke-width=\"2\"/>"
                    + "<path d=\"M19 27 L27 19\" stroke=\"#D92D20\" stroke-width=\"2\"/>")
        case .dragCopy:
            return svg(
                arrowBody
                    + "<circle cx=\"23\" cy=\"23\" r=\"6.5\" fill=\"#22A04B\" stroke=\"white\" stroke-width=\"1\"/>"
                    + "<path d=\"M23 19.5 L23 26.5 M19.5 23 L26.5 23\" stroke=\"white\" stroke-width=\"2\"/>")
        case .contextualMenu:
            return svg(
                arrowBody
                    + "<rect x=\"18\" y=\"17\" width=\"12\" height=\"12\" rx=\"1.5\" fill=\"white\" stroke=\"black\" "
                    + "stroke-width=\"1.2\"/><path d=\"M20.5 20.5 L27.5 20.5 M20.5 23 L27.5 23 M20.5 25.5 L27.5 25.5\" "
                    + "stroke=\"black\" stroke-width=\"1\"/>")
        case .arrow, .pointingHand, .iBeam, .other:
            return svg(arrowBody)
        }
    }
}

/// Loads and rasterises cursor images once per (image, pixel size) and caches them as cached Core Image
/// intermediates. Thread-safe.
final class CursorImageCache: Sendable {
    private struct Key: Hashable {
        var art: CursorArtKey
        /// Pixels per point × 8, rounded, so the cache doesn't grow with every tiny size change.
        var density: Int
    }

    private let package: RecordingPackage
    private let index: CursorIndex
    private let cache = LockedDictionary<Key, CursorSprite?>()

    init(package: RecordingPackage, index: CursorIndex) {
        self.package = package
        self.index = index
    }

    /// Picks the image for `style` given the captured cursor id at this moment.
    func artKey(style: CursorStyle, cursorID: Int?) -> CursorArtKey {
        let info = cursorID.flatMap { index[$0] }
        switch style {
        case .system:
            if let info { return .captured(info.id) }
            return .artwork(.arrow)
        case .stylised:
            if let info {
                return CursorArtwork.hasArtwork(for: info.kind) ? .artwork(info.kind) : .captured(info.id)
            }
            return .artwork(.arrow)
        case .fixed(let kind):
            return .artwork(CursorArtwork.hasArtwork(for: kind) ? kind : .arrow)
        }
    }

    /// The sprite for `art` at `pixelsPerPoint`, rasterised on first use.
    func sprite(for art: CursorArtKey, pixelsPerPoint: Double) -> CursorSprite? {
        let density = max(1, Int((pixelsPerPoint * 8).rounded()))
        let key = Key(art: art, density: density)
        if let cached = cache[key] { return cached }
        let sprite =
            makeSprite(art: art, pixelsPerPoint: Double(density) / 8)
            ?? (art == .artwork(.arrow) ? nil : makeSprite(art: .artwork(.arrow), pixelsPerPoint: Double(density) / 8))
        cache[key] = .some(sprite)
        return sprite
    }

    private func makeSprite(art: CursorArtKey, pixelsPerPoint: Double) -> CursorSprite? {
        switch art {
        case .captured(let id):
            guard let info = index[id],
                let source = CGImageSourceCreateWithURL(package.url(info.file) as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            let size = CGSize(
                width: max(1, (info.width * pixelsPerPoint).rounded()),
                height: max(1, (info.height * pixelsPerPoint).rounded()))
            guard
                let raster = Self.rasterise(
                    size: size, draw: { ctx in ctx.draw(image, in: CGRect(origin: .zero, size: size)) })
            else { return nil }
            let sx = size.width / max(info.width, 1e-6)
            let sy = size.height / max(info.height, 1e-6)
            return CursorSprite(
                image: raster, hotspot: CGPoint(x: info.hotspotX * sx, y: info.hotspotY * sy), size: size)
        case .artwork(let kind):
            guard let data = CursorArtwork.svgData(for: kind), let svg = NSImage(data: data) else { return nil }
            let side = max(1, (CursorArtwork.pointSize * pixelsPerPoint).rounded())
            let size = CGSize(width: side, height: side)
            var rect = CGRect(origin: .zero, size: size)
            guard let cg = svg.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                let raster = Self.rasterise(
                    size: size, draw: { ctx in ctx.draw(cg, in: CGRect(origin: .zero, size: size)) })
            else { return nil }
            let hotspot = CursorArtwork.hotspot(for: kind)
            return CursorSprite(
                image: raster, hotspot: CGPoint(x: hotspot.x * side / 32, y: hotspot.y * side / 32), size: size)
        }
    }

    /// Draws into an sRGB premultiplied bitmap and wraps it as a cached Core Image intermediate.
    private static func rasterise(size: CGSize, draw: (CGContext) -> Void) -> CIImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        draw(ctx)
        guard let image = ctx.makeImage() else { return nil }
        return CIImage(cgImage: image).insertingIntermediate(cache: true)
    }
}

/// A small thread-safe dictionary for render caches.
final class LockedDictionary<Key: Hashable & Sendable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { lock.withLock { storage[key] } }
        set { lock.withLock { storage[key] = newValue } }
    }
}
