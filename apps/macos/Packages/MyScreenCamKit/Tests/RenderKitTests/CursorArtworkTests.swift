import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import ProjectKit
import Testing
import UniformTypeIdentifiers

@testable import RenderKit

struct CursorArtworkTests {
    private func packageWithCursor() throws -> (RecordingPackage, CursorIndex) {
        let root = FileManager.default.temporaryDirectory.appending(path: "RenderKitCursor-\(UUID().uuidString)")
        let package = try RecordingPackage.create(in: root)
        // A 20×20 px (10×10 pt @2x) opaque red square.
        let ctx = CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let url = package.url("cursors/7.png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let index = CursorIndex(cursors: [
            CursorImageInfo(
                id: 7, file: "cursors/7.png", width: 10, height: 10, scale: 2, hotspotX: 2, hotspotY: 3, kind: .other),
            CursorImageInfo(
                id: 8, file: "cursors/8.png", width: 10, height: 10, scale: 2, hotspotX: 0, hotspotY: 0,
                kind: .pointingHand),
        ])
        return (package, index)
    }

    @Test func styleResolution() throws {
        let (package, index) = try packageWithCursor()
        let cache = CursorImageCache(package: package, index: index)
        #expect(cache.artKey(style: .system, cursorID: 7) == .captured(7))
        #expect(cache.artKey(style: .system, cursorID: nil) == .artwork(.arrow))
        #expect(cache.artKey(style: .stylised, cursorID: 7) == .captured(7))  // `.other` has no artwork
        #expect(cache.artKey(style: .stylised, cursorID: 8) == .artwork(.pointingHand))
        #expect(cache.artKey(style: .fixed(.iBeam), cursorID: 7) == .artwork(.iBeam))
        #expect(cache.artKey(style: .fixed(.other), cursorID: 7) == .artwork(.arrow))
    }

    @Test func capturedSpriteScalesWithHotspot() throws {
        let (package, index) = try packageWithCursor()
        let cache = CursorImageCache(package: package, index: index)
        let sprite = try #require(cache.sprite(for: .captured(7), pixelsPerPoint: 3))
        #expect(sprite.size == CGSize(width: 30, height: 30))
        #expect(sprite.hotspot == CGPoint(x: 6, y: 9))
        // A missing PNG falls back to the arrow artwork instead of drawing nothing.
        let missing = try #require(cache.sprite(for: .captured(8), pixelsPerPoint: 1))
        #expect(missing.size == CGSize(width: CursorArtwork.pointSize, height: CursorArtwork.pointSize))
    }

    @Test(arguments: CursorKind.allCases)
    func everyKindHasRenderableArtwork(kind: CursorKind) throws {
        let (package, index) = try packageWithCursor()
        let cache = CursorImageCache(package: package, index: index)
        let sprite = try #require(cache.sprite(for: .artwork(kind), pixelsPerPoint: 2))
        #expect(sprite.size == CGSize(width: CursorArtwork.pointSize * 2, height: CursorArtwork.pointSize * 2))
        #expect(sprite.hotspot.x > 0 && sprite.hotspot.y > 0)
    }

    @Test(arguments: [2.0, 4.0])
    func pointingHandHotspotStaysOnIndexFingertip(pixelsPerPoint: Double) throws {
        #expect(CursorArtwork.hotspot(for: .pointingHand) == CGPoint(x: 14.75, y: 2.5))
        let (package, index) = try packageWithCursor()
        let cache = CursorImageCache(package: package, index: index)
        let sprite = try #require(cache.sprite(for: .artwork(.pointingHand), pixelsPerPoint: pixelsPerPoint))
        let scale = sprite.size.width / 32
        #expect(sprite.hotspot == CGPoint(x: 14.75 * scale, y: 2.5 * scale))

        let image = try #require(CIContext().createCGImage(sprite.image, from: sprite.image.extent))
        let bitmap = Bitmap(cgImage: image)
        // The topmost white row is the rounded index-finger tip. Ignore the black outline and shadow.
        let tipY = try #require(
            (0..<bitmap.height).first { y in
                (0..<bitmap.width).contains { x in
                    let pixel = bitmap.pixel(x, y)
                    return pixel.r > 200 && pixel.g > 200 && pixel.b > 200
                }
            })
        let tipXs = (0..<bitmap.width).filter { x in
            let pixel = bitmap.pixel(x, tipY)
            return pixel.r > 200 && pixel.g > 200 && pixel.b > 200
        }
        let left = try #require(tipXs.first)
        let right = try #require(tipXs.last)
        let tipCenterX = Double(left + right + 1) / 2
        // Allow subpixel rasterisation differences, while keeping the hotspot within one SVG unit of the tip.
        #expect(abs(tipCenterX - sprite.hotspot.x) < scale / 2)
        #expect(abs(Double(tipY) + 0.5 - sprite.hotspot.y) < scale)
    }
}
