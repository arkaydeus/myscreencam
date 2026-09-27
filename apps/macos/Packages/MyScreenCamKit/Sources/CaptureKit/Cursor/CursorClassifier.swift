import AppKit
import CoreGraphics
import ProjectKit

/// Classifies captured cursor images as one of the standard ``CursorKind``s by comparing them with the
/// `NSCursor` set.
///
/// Matching is by shape, so it's scale- and colour-invariant: each image is reduced to its aspect ratio, its
/// hotspot relative to its size, and a 24×24 alpha mask. Enlarged pointers (Accessibility › Pointer size) and
/// custom pointer colours still classify. Colour only breaks ties between identical silhouettes (dragCopy vs
/// operationNotAllowed). Anything without a close shape match is `.other`.
public struct CursorClassifier: Sendable {
    struct Reference: Sendable {
        let kind: CursorKind
        let signature: CursorSignature
    }

    /// Mean alpha difference (0…1) below which an image counts as a match.
    public static let matchThreshold = 0.06

    let references: [Reference]

    public init(references: [(CursorKind, CursorSnapshot)]) {
        self.references = references.compactMap { kind, snapshot in
            CursorSignature(snapshot).map { Reference(kind: kind, signature: $0) }
        }
    }

    /// Number of usable reference images.
    public var referenceCount: Int { references.count }

    public func classify(_ snapshot: CursorSnapshot) -> CursorKind {
        guard let signature = CursorSignature(snapshot) else { return .other }
        let matches = references.compactMap { reference in
            signature.shapeDistance(to: reference.signature).map { (reference, $0) }
        }
        guard let bestShape = matches.map(\.1).min(), bestShape <= Self.matchThreshold else { return .other }
        // Some cursors share a silhouette and differ only in colour (the badges of dragCopy and
        // operationNotAllowed), so colour breaks ties between equally good shapes.
        let tied = matches.filter { $0.1 <= bestShape + Self.tieTolerance }
        let best = tied.min {
            signature.colorDistance(to: $0.0.signature) < signature.colorDistance(to: $1.0.signature)
        }
        return best?.0.kind ?? .other
    }

    /// Shapes this close to the best one count as tied and are separated by colour.
    static let tieTolerance = 0.01

    /// The standard AppKit cursors, rendered at `scale`. Needs AppKit's cursor images, which load with
    /// `NSApplication` (always present in the app).
    @MainActor
    public static func standard(scale: Double = 2) -> CursorClassifier {
        CursorClassifier(
            references: standardCursors().compactMap { kind, cursor in
                CursorSnapshot(cursor: cursor, scale: scale).map { (kind, $0) }
            })
    }

    @MainActor
    static func standardCursors() -> [(CursorKind, NSCursor)] {
        var cursors: [(CursorKind, NSCursor)] = [
            (.arrow, .arrow),
            (.pointingHand, .pointingHand),
            (.iBeam, .iBeam),
            (.iBeam, .iBeamCursorForVerticalLayout),
            (.crosshair, .crosshair),
            (.openHand, .openHand),
            (.closedHand, .closedHand),
            (.operationNotAllowed, .operationNotAllowed),
            (.dragCopy, .dragCopy),
            (.contextualMenu, .contextualMenu),
            (.resizeLeftRight, .resizeLeft),
            (.resizeLeftRight, .resizeRight),
            (.resizeLeftRight, .resizeLeftRight),
            (.resizeUpDown, .resizeUp),
            (.resizeUpDown, .resizeDown),
            (.resizeUpDown, .resizeUpDown),
            (.resizeLeftRight, .columnResize),
            (.resizeLeftRight, .columnResize(directions: .left)),
            (.resizeLeftRight, .columnResize(directions: .right)),
            (.resizeUpDown, .rowResize),
            (.resizeUpDown, .rowResize(directions: .up)),
            (.resizeUpDown, .rowResize(directions: .down)),
        ]
        let positions: [(NSCursor.FrameResizePosition, CursorKind)] = [
            (.top, .resizeUpDown), (.bottom, .resizeUpDown), (.left, .resizeLeftRight), (.right, .resizeLeftRight),
            (.topLeft, .resizeDiagonal), (.topRight, .resizeDiagonal), (.bottomLeft, .resizeDiagonal),
            (.bottomRight, .resizeDiagonal),
        ]
        for (position, kind) in positions {
            for directions: NSCursor.FrameResizeDirection.Set in [.all, .inward, .outward] {
                cursors.append((kind, .frameResize(position: position, directions: directions)))
            }
        }
        return cursors
    }
}

/// Scale-invariant fingerprint of a cursor image.
struct CursorSignature: Sendable {
    static let side = 24

    let aspect: Double
    let hotspotX: Double
    let hotspotY: Double
    let alpha: [UInt8]
    /// Premultiplied RGB, for tie-breaking only (pointer colours can be customised in Accessibility settings).
    let rgb: [UInt8]

    init?(_ snapshot: CursorSnapshot) {
        let size = snapshot.size
        guard size.width > 0, size.height > 0 else { return nil }
        aspect = Double(size.width / size.height)
        hotspotX = Double(snapshot.hotspot.x / size.width)
        hotspotY = Double(snapshot.hotspot.y / size.height)
        let side = Self.side
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(snapshot.image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        rgb = rgba.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
    }

    /// Mean absolute alpha difference (0…1), or nil if the shapes are incompatible (aspect or hotspot differ).
    func shapeDistance(to other: CursorSignature) -> Double? {
        guard abs(aspect - other.aspect) <= 0.08 * max(aspect, other.aspect),
            abs(hotspotX - other.hotspotX) <= 0.08, abs(hotspotY - other.hotspotY) <= 0.08
        else { return nil }
        return Self.meanDifference(alpha, other.alpha)
    }

    /// Mean absolute RGB difference (0…1).
    func colorDistance(to other: CursorSignature) -> Double {
        Self.meanDifference(rgb, other.rgb)
    }

    private static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(max(1, a.count) * 255)
    }
}
