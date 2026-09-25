import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension PackageLayout {
    /// Fallback thumbnail path, used only when this Mac can't encode HEIC. Readers should check
    /// ``thumbnail`` first (``ThumbnailGenerator/cachedThumbnailURL(for:)`` does both).
    public static let thumbnailFallback = "cache/thumbnail.jpg"
}

/// Aspect-fit dimensions shared by Finder's thumbnail extension and package thumbnail tests.
public enum ThumbnailGeometry {
    public static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let ratio = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
    }
}

/// Renders the library still for a recording into `cache/thumbnail.heic` (or `cache/thumbnail.jpg` where HEIC
/// encoding isn't available), decoding a single frame of `screen.mov`.
public struct ThumbnailGenerator: Sendable {
    public enum ThumbnailError: Error, Sendable, Equatable {
        case missingScreen(URL)
        case encodingFailed(URL)
    }

    /// Longest side of the thumbnail in pixels.
    public var maxPixelSize: Int
    /// Encoder quality 0…1.
    public var quality: Double

    public init(maxPixelSize: Int = 640, quality: Double = 0.7) {
        self.maxPixelSize = maxPixelSize
        self.quality = quality
    }

    /// The cached thumbnail file if one exists (HEIC preferred), without generating anything.
    public static func cachedThumbnailURL(for package: RecordingPackage) -> URL? {
        [PackageLayout.thumbnail, PackageLayout.thumbnailFallback]
            .map { package.url($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Returns the cached thumbnail, generating it first if it's missing.
    public func thumbnail(for package: RecordingPackage) async throws -> URL {
        if let cached = Self.cachedThumbnailURL(for: package) { return cached }
        return try await generate(for: package)
    }

    /// Always (re)renders the thumbnail from `screen.mov` at `min(1 s, 10 %)` of its duration.
    public func generate(for package: RecordingPackage) async throws -> URL {
        let screen = package.url(for: .screen)
        guard FileManager.default.fileExists(atPath: screen.path) else { throw ThumbnailError.missingScreen(screen) }

        let asset = AVURLAsset(url: screen)
        let duration = try await asset.load(.duration).seconds
        let seconds = duration.isFinite && duration > 0 ? min(1, duration * 0.1) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Accept a nearby frame so the decoder can stop at (or near) a sync sample instead of decoding a GOP.
        let tolerance = CMTime(seconds: max(0.5, seconds), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let image = try await generator.image(at: time).image

        let cache = package.url(PackageLayout.cacheDirectory)
        if !FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        }
        if try write(image, to: package.url(PackageLayout.thumbnail), type: .heic) {
            try? FileManager.default.removeItem(at: package.url(PackageLayout.thumbnailFallback))
            return package.url(PackageLayout.thumbnail)
        }
        let fallback = package.url(PackageLayout.thumbnailFallback)
        guard try write(image, to: fallback, type: .jpeg) else { throw ThumbnailError.encodingFailed(fallback) }
        return fallback
    }

    /// Encodes to a temp file then moves it into place. Returns false if the encoder for `type` is unavailable.
    private func write(_ image: CGImage, to url: URL, type: UTType) throws -> Bool {
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard
            let destination = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil)
        else { return false }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return false }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        return true
    }
}
