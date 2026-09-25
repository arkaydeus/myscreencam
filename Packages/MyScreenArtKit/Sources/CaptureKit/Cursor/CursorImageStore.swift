import CoreGraphics
import Foundation
import ImageIO
import ProjectKit
import UniformTypeIdentifiers

/// De-duplicates cursor images and writes each new one as `<directory>/<id>.png` plus a ``CursorImageInfo``.
/// Ids are 0, 1, 2… in order of first appearance, matching positions in `cursors/index.json`.
///
/// Not thread-safe: confine to one queue (``CursorImageTracker`` uses a utility queue).
public final class CursorImageStore {
    public let directory: URL
    public let relativePrefix: String
    private let classifier: CursorClassifier
    private var idsByHash: [Int: Int] = [:]
    public private(set) var index = CursorIndex()

    /// - Parameters:
    ///   - directory: where PNGs go (the package's `cursors/` folder).
    ///   - relativePrefix: prefix for `CursorImageInfo.file`, relative to the package.
    public init(
        directory: URL, relativePrefix: String = PackageLayout.cursorsDirectory, classifier: CursorClassifier
    ) {
        self.directory = directory
        self.relativePrefix = relativePrefix
        self.classifier = classifier
    }

    /// The id for this image, writing it first if it hasn't been seen.
    public func register(_ snapshot: CursorSnapshot) throws -> Int {
        let hash = snapshot.contentHash()
        if let id = idsByHash[hash] { return id }
        let id = index.cursors.count
        let fileName = "\(id).png"
        try Self.writePNG(snapshot, to: directory.appending(path: fileName))
        let info = CursorImageInfo(
            id: id, file: "\(relativePrefix)/\(fileName)", width: Double(snapshot.size.width),
            height: Double(snapshot.size.height), scale: snapshot.scale, hotspotX: Double(snapshot.hotspot.x),
            hotspotY: Double(snapshot.hotspot.y), kind: classifier.classify(snapshot))
        index.cursors.append(info)
        idsByHash[hash] = id
        return id
    }

    /// Writes a PNG tagged with its DPI (72 × scale), so viewers show it at its point size.
    static func writePNG(_ snapshot: CursorSnapshot, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CaptureError.failed("Can't create \(url.lastPathComponent)") }
        let dpi = 72 * snapshot.scale
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, snapshot.image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.failed("Can't write \(url.lastPathComponent)")
        }
    }
}
