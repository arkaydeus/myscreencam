import Foundation
import ImageIO
import Testing

@testable import ProjectKit

struct ThumbnailGeneratorTests {
    /// Decodes the centre pixel of an image file as (r, g, b) 0…255.
    func centrePixel(of url: URL) throws -> (width: Int, height: Int, rgb: [Int]) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            image,
            in: CGRect(
                x: -Double(image.width) / 2, y: -Double(image.height) / 2, width: Double(image.width),
                height: Double(image.height)))
        return (image.width, image.height, pixel.prefix(3).map(Int.init))
    }

    @Test(.timeLimit(.minutes(1)))
    func generatesDownscaledThumbnailOnce() async throws {
        let dir = try TempDirectory()
        let package = try Fixtures.package(in: dir.url, meta: Fixtures.meta())
        // Pure red (BGRA 0,0,255).
        try await Fixtures.writeSolidVideo(to: package.url(for: .screen), width: 1280, height: 720)
        #expect(ThumbnailGenerator.cachedThumbnailURL(for: package) == nil)

        let generator = ThumbnailGenerator()
        let url = try await generator.thumbnail(for: package)
        #expect(url == package.url(PackageLayout.thumbnail) || url == package.url(PackageLayout.thumbnailFallback))
        #expect(ThumbnailGenerator.cachedThumbnailURL(for: package) == url)

        let (width, height, rgb) = try centrePixel(of: url)
        #expect(width == 640 && height == 360)
        #expect(rgb[0] > 200 && rgb[1] < 60 && rgb[2] < 60, "expected red, got \(rgb)")

        // Cached: a second call returns the same file untouched.
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let again = try await generator.thumbnail(for: package)
        #expect(again == url)
        #expect(try again.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)

        // The library picks it up.
        #expect(try RecordingLibrary.loadItem(at: package.url).thumbnailURL == url)
    }

    @Test(.timeLimit(.minutes(1)))
    func respectsMaxPixelSizeForPortrait() async throws {
        let dir = try TempDirectory()
        let package = try Fixtures.package(in: dir.url, meta: Fixtures.meta())
        try await Fixtures.writeSolidVideo(
            to: package.url(for: .screen), width: 360, height: 800, frameCount: 3, bgra: (255, 0, 0, 255))
        let url = try await ThumbnailGenerator(maxPixelSize: 200).generate(for: package)
        let (width, height, rgb) = try centrePixel(of: url)
        #expect(height == 200 && width == 90)
        #expect(rgb[2] > 200 && rgb[0] < 60, "expected blue, got \(rgb)")
    }

    @Test func missingScreenThrows() async throws {
        let dir = try TempDirectory()
        let package = try Fixtures.package(in: dir.url, meta: Fixtures.meta())
        await #expect(throws: ThumbnailGenerator.ThumbnailError.missingScreen(package.url(for: .screen))) {
            try await ThumbnailGenerator().thumbnail(for: package)
        }
    }
}
