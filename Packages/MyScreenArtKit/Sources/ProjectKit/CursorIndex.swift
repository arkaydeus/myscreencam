import Foundation

/// `cursors/index.json`: the distinct system cursor images seen during a recording.
public struct CursorIndex: Codable, Sendable, Equatable {
    public var cursors: [CursorImageInfo]

    public init(cursors: [CursorImageInfo] = []) {
        self.cursors = cursors
    }

    public subscript(id: Int) -> CursorImageInfo? { cursors.first { $0.id == id } }
}

public struct CursorImageInfo: Codable, Sendable, Equatable {
    public var id: Int
    /// Path relative to the package, e.g. `cursors/3.png`.
    public var file: String
    /// Image size in points (the PNG is `size × scale` pixels).
    public var width: Double
    public var height: Double
    public var scale: Double
    /// Hotspot in points from the image's top-left corner.
    public var hotspotX: Double
    public var hotspotY: Double
    public var kind: CursorKind

    public init(
        id: Int, file: String, width: Double, height: Double, scale: Double, hotspotX: Double, hotspotY: Double,
        kind: CursorKind
    ) {
        self.id = id
        self.file = file
        self.width = width
        self.height = height
        self.scale = scale
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.kind = kind
    }
}

/// What a captured cursor image looks like. Used to swap in stylised artwork.
public enum CursorKind: String, Codable, Sendable, CaseIterable {
    case arrow
    case pointingHand
    case iBeam
    case crosshair
    case openHand
    case closedHand
    case resizeLeftRight
    case resizeUpDown
    case resizeDiagonal
    case operationNotAllowed
    case dragCopy
    case contextualMenu
    case other
}
