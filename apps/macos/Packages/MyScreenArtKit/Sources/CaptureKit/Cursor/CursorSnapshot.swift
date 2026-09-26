import AppKit
import CoreGraphics

/// A cursor image frozen at one scale: what ``CursorImageTracker`` stores and classifies.
public struct CursorSnapshot: Sendable {
    /// Bitmap at `scale` pixels per point.
    public var image: CGImage
    /// Size in points.
    public var size: CGSize
    /// Hotspot in points from the image's top-left corner.
    public var hotspot: CGPoint

    public init(image: CGImage, size: CGSize, hotspot: CGPoint) {
        self.image = image
        self.size = size
        self.hotspot = hotspot
    }

    /// Actual pixels per point of ``image``.
    public var scale: Double { size.width > 0 ? Double(image.width) / Double(size.width) : 1 }

    /// Renders an `NSCursor` at `scale` (picking the best bitmap representation for it). AppKit objects are
    /// only touched on the main actor. Returns nil for cursors without an image (e.g. before `NSApplication`
    /// has loaded the system cursors).
    @MainActor
    public init?(cursor: NSCursor, scale: Double) {
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        var rect = NSRect(origin: .zero, size: size)
        let hints: [NSImageRep.HintKey: Any] = [.ctm: NSAffineTransform(transform: AffineTransform(scale: scale))]
        guard let bitmap = image.cgImage(forProposedRect: &rect, context: nil, hints: hints) else { return nil }
        self.init(image: bitmap, size: size, hotspot: cursor.hotSpot)
    }

    /// The current system-wide cursor (whatever app is under the pointer), or nil if unavailable.
    @MainActor
    public static func currentSystem(scale: Double) -> CursorSnapshot? {
        NSCursor.currentSystem.flatMap { CursorSnapshot(cursor: $0, scale: scale) }
    }

    /// A content hash of the bitmap, hotspot and size, for de-duplication.
    func contentHash() -> Int {
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        hasher.combine(hotspot.x)
        hasher.combine(hotspot.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
        if let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: CFDataGetLength(data)))
        }
        return hasher.finalize()
    }
}
