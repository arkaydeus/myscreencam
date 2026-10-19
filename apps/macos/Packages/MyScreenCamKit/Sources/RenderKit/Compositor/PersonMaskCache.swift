import CoreImage
import CoreVideo
import Foundation

/// Person masks rendered once per webcam frame and reused.
///
/// The composition usually runs faster than the webcam (60 fps output, 24–30 fps camera), so each camera frame is
/// composited two or three times, and segmentation is the expensive part. Entries are keyed by the decoded
/// `CVPixelBuffer` and hold on to it: while it's retained here its pool can't recycle it for another frame, so a
/// key never matches different pixels. Images not backed by a pixel buffer aren't cached.
final class PersonMaskCache: @unchecked Sendable {
    private struct Entry {
        let buffer: CVPixelBuffer
        let mask: CIImage?
    }

    /// A few frames, so frames composited out of order (or on two compositor queues) still hit.
    private static let capacity = 4
    private let lock = NSLock()
    private var entries: [Entry] = []

    /// The mask for `camera`, made with `make` and rendered into a texture the first time this frame is seen.
    func mask(for camera: CIImage, make: (CIImage) -> CIImage?) -> CIImage? {
        guard let buffer = camera.pixelBuffer else { return make(camera) }
        if let hit = lock.withLock({ entries.first { $0.buffer === buffer } }) { return hit.mask }
        let mask = make(camera).map(RenderContext.rasterize)
        lock.withLock {
            entries.removeAll { $0.buffer === buffer }
            entries.append(Entry(buffer: buffer, mask: mask))
            if entries.count > Self.capacity { entries.removeFirst() }
        }
        return mask
    }
}
