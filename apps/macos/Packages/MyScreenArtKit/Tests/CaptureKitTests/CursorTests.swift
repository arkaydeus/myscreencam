import AppKit
import ImageIO
import ProjectKit
import Testing

@testable import CaptureKit

/// AppKit loads the system cursor images with `NSApplication`; a test process has none until this runs.
@MainActor
private func appKitCursorsLoaded() {
    _ = NSApplication.shared
}

@MainActor
private func snapshot(_ cursor: NSCursor, scale: Double = 2) throws -> CursorSnapshot {
    appKitCursorsLoaded()
    return try #require(CursorSnapshot(cursor: cursor, scale: scale))
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "cursor-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Suite struct CursorClassifierTests {
    let classifier: CursorClassifier

    init() {
        appKitCursorsLoaded()
        classifier = CursorClassifier.standard(scale: 2)
    }

    @Test func buildsReferencesForTheStandardSet() {
        #expect(classifier.referenceCount >= 30)
    }

    @Test(arguments: [
        ("arrow", CursorKind.arrow),
        ("pointingHand", .pointingHand),
        ("iBeam", .iBeam),
        ("crosshair", .crosshair),
        ("openHand", .openHand),
        ("closedHand", .closedHand),
        ("operationNotAllowed", .operationNotAllowed),
        ("dragCopy", .dragCopy),
        ("contextualMenu", .contextualMenu),
        ("resizeLeftRight", .resizeLeftRight),
        ("resizeUpDown", .resizeUpDown),
        ("frameResizeTopLeft", .resizeDiagonal),
        ("frameResizeRight", .resizeLeftRight),
        ("frameResizeBottom", .resizeUpDown),
        ("columnResize", .resizeLeftRight),
        ("rowResize", .resizeUpDown),
    ])
    func classifiesStandardCursors(name: String, kind: CursorKind) throws {
        let cursors: [String: NSCursor] = [
            "arrow": .arrow, "pointingHand": .pointingHand, "iBeam": .iBeam, "crosshair": .crosshair,
            "openHand": .openHand, "closedHand": .closedHand, "operationNotAllowed": .operationNotAllowed,
            "dragCopy": .dragCopy, "contextualMenu": .contextualMenu, "resizeLeftRight": .resizeLeftRight,
            "resizeUpDown": .resizeUpDown, "frameResizeTopLeft": .frameResize(position: .topLeft, directions: .all),
            "frameResizeRight": .frameResize(position: .right, directions: .all),
            "frameResizeBottom": .frameResize(position: .bottom, directions: .inward),
            "columnResize": .columnResize, "rowResize": .rowResize,
        ]
        let cursor = try #require(cursors[name])
        #expect(classifier.classify(try snapshot(cursor)) == kind)
    }

    @Test func classificationIgnoresScale() throws {
        // A 1× capture (non-Retina display) against 2× references, and an enlarged 3× pointer.
        #expect(classifier.classify(try snapshot(.arrow, scale: 1)) == .arrow)
        #expect(classifier.classify(try snapshot(.iBeam, scale: 3)) == .iBeam)
        #expect(classifier.classify(try snapshot(.pointingHand, scale: 1)) == .pointingHand)
    }

    @Test func unknownImageIsOther() throws {
        let size = 20
        let context = try #require(
            CGContext(
                data: nil, width: size * 2, height: size * 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size * 2, height: size * 2))
        let image = try #require(context.makeImage())
        let square = CursorSnapshot(
            image: image, size: CGSize(width: size, height: size), hotspot: CGPoint(x: 10, y: 10))
        #expect(classifier.classify(square) == .other)
    }
}

@MainActor
struct CursorImageStoreTests {
    @Test func deduplicatesAndWritesPNGsWithIndex() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        appKitCursorsLoaded()
        let store = CursorImageStore(directory: directory, classifier: CursorClassifier.standard(scale: 2))

        // `NSCursor` hands out fresh objects; identical images must still share an id.
        let arrow1 = try store.register(try snapshot(.arrow))
        let beam = try store.register(try snapshot(.iBeam))
        let arrow2 = try store.register(try snapshot(.arrow))
        #expect(arrow1 == 0)
        #expect(beam == 1)
        #expect(arrow2 == arrow1)
        #expect(store.index.cursors.count == 2)

        let info = try #require(store.index[beam])
        #expect(info.file == "cursors/1.png")
        #expect(info.kind == .iBeam)
        #expect(info.scale == 2)
        #expect(info.width == Double(NSCursor.iBeam.image.size.width))
        #expect(info.hotspotX == Double(NSCursor.iBeam.hotSpot.x))

        let png = directory.appending(path: "1.png")
        let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == Int(info.width * 2))
        #expect(image.height == Int(info.height * 2))
    }

    @Test func indexRoundTripsThroughPackage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try RecordingPackage.create(in: root)
        appKitCursorsLoaded()
        let store = CursorImageStore(
            directory: package.url(PackageLayout.cursorsDirectory), classifier: CursorClassifier.standard())
        _ = try store.register(try snapshot(.pointingHand))
        try package.saveCursorIndex(store.index)
        let loaded = try package.loadCursorIndex()
        #expect(loaded == store.index)
        #expect(loaded.cursors.first?.kind == .pointingHand)
        #expect(FileManager.default.fileExists(atPath: package.url("cursors/0.png").path))
    }
}

@MainActor
struct CursorImageTrackerTests {
    @Test func samplesOnActivityThrottledAndDeduplicated() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        appKitCursorsLoaded()
        let arrow = try snapshot(.arrow)
        let beam = try snapshot(.iBeam)
        final class Script: @unchecked Sendable { var next: [CursorSnapshot] = [] }
        let script = Script()
        script.next = [arrow, arrow, beam, beam, arrow]
        let tracker = CursorImageTracker(
            directory: directory, scale: 2, maximumRate: 1000, classifier: CursorClassifier.standard()
        ) { _ in script.next.isEmpty ? nil : script.next.removeFirst() }

        await tracker.start()  // first sample: arrow
        for _ in 0..<4 {
            tracker.noteActivity()
            try await Task.sleep(for: .milliseconds(20))
        }
        let index = await tracker.finish()
        #expect(tracker.sampleCount == 5)
        #expect(index.cursors.map(\.kind) == [.arrow, .iBeam])
        #expect(tracker.currentCursorID == 0)
    }

    @Test func burstOfActivityIsThrottled() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        appKitCursorsLoaded()
        let arrow = try snapshot(.arrow)
        let tracker = CursorImageTracker(
            directory: directory, scale: 2, maximumRate: 30, classifier: CursorClassifier.standard()
        ) { _ in arrow }
        await tracker.start()
        // A burst of pointer events must cause at most one sample per 1/30 s (plus the first and a trailing one).
        let began = ContinuousClock.now
        for _ in 0..<200 {
            tracker.noteActivity()
            try await Task.sleep(for: .microseconds(500))
        }
        let elapsed = (ContinuousClock.now - began) / .seconds(1)
        try await Task.sleep(for: .milliseconds(60))
        _ = await tracker.finish()
        // Initial sample + one per 1/30 s (+1 at the window boundary) + the trailing sample.
        #expect(Double(tracker.sampleCount) <= elapsed * 30 + 4, "\(tracker.sampleCount) samples in \(elapsed) s")
        #expect(tracker.sampleCount < 50)
        #expect(tracker.sampleCount >= 2)
    }
}
