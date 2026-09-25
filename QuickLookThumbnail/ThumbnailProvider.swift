import AVFoundation
import CoreGraphics
import ProjectKit
import QuickLookThumbnailing

/// Finder / Quick Look thumbnails for `com.myscreenart.recording` packages (`*.msarec`).
///
/// Uses the cached still the app writes (HEIC or JPEG) when present; otherwise grabs a frame
/// near the start of `screen.mov` with `AVAssetImageGenerator` (nearest keyframe, so it stays cheap).
final class ThumbnailProvider: QLThumbnailProvider {
    enum ThumbnailError: Error {
        case noMedia
    }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
    ) {
        let package = RecordingPackage(url: request.fileURL)
        if let cached = ThumbnailGenerator.cachedThumbnailURL(for: package) {
            handler(QLThumbnailReply(imageFileURL: cached), nil)
            return
        }

        let movie = package.url(PackageLayout.screen)
        guard FileManager.default.fileExists(atPath: movie.path) else {
            handler(nil, ThumbnailError.noMedia)
            return
        }

        let maximumSize = request.maximumSize
        let scale = request.scale
        let reply = ReplyHandler(handler)
        Task {
            do {
                let image = try await Self.frame(
                    of: movie,
                    maximumPixelSize: CGSize(width: maximumSize.width * scale, height: maximumSize.height * scale))
                let size = ThumbnailGeometry.fit(CGSize(width: image.width, height: image.height), in: maximumSize)
                reply.send(
                    QLThumbnailReply(contextSize: size) { context in
                        context.interpolationQuality = .high
                        context.draw(image, in: CGRect(origin: .zero, size: size))
                        return true
                    }, nil)
            } catch {
                reply.send(nil, error)
            }
        }
    }

    private static func frame(of movie: URL, maximumPixelSize: CGSize) async throws -> CGImage {
        let asset = AVURLAsset(url: movie)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumPixelSize
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let duration = try await asset.load(.duration)
        // Skip the very first frames (often a countdown overlay or a black frame): 10% in, at most 1 s.
        let seconds = duration.isNumeric ? min(1, duration.seconds * 0.1) : 0
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return image
    }

}

/// Quick Look's completion handler isn't `Sendable`; it may be called from any thread, exactly once.
private struct ReplyHandler: @unchecked Sendable {
    let handler: (QLThumbnailReply?, (any Error)?) -> Void

    init(_ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void) {
        self.handler = handler
    }

    func send(_ reply: QLThumbnailReply?, _ error: (any Error)?) {
        handler(reply, error)
    }
}
