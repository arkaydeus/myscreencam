import Foundation
import Testing

@testable import ProjectKit

struct ProjectModelTests {
    @Test func packagePathsCannotEscapeThroughTraversalOrSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pk-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try RecordingPackage.create(in: root)
        let outside = root.appending(path: "outside.png")
        try Data([1, 2, 3]).write(to: outside)
        let link = package.url("cursors/escape.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(package.containedURL("cursors/valid.png") != nil)
        #expect(package.containedURL("../../outside.png") == nil)
        #expect(package.containedURL(outside.path) == nil)
        #expect(package.containedURL("cursors/escape.png") == nil)
    }

    func sampleMeta() -> RecordingMeta {
        RecordingMeta(
            name: "Test",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            duration: 12.5,
            source: .display(displayID: 1, name: "Built-in"),
            screen: ScreenStreamInfo(
                pixelWidth: 3024, pixelHeight: 1964, scale: 2, frameRate: 60, codec: "hvc1",
                contentRectPoints: RectPoints(x: 0, y: 0, width: 1512, height: 982)),
            webcam: WebcamStreamInfo(
                deviceID: "cam", name: "Camera", pixelWidth: 1280, pixelHeight: 720, frameRate: 30),
            capturedSystemAudio: true,
            streams: [.screen: StreamTiming(startOffset: 0.01), .webcam: StreamTiming(startOffset: 0.2)],
            pauses: [PauseRecord(at: 4, skipped: 3.5)],
            systemCursorHidden: true
        )
    }

    @Test func packageRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try RecordingPackage.create(in: root)
        let meta = sampleMeta()
        try package.saveMeta(meta)
        #expect(RecordingPackage.isPackage(package.url))
        #expect(package.url.pathExtension == "msarec")
        #expect(try package.loadMeta() == meta)
        #expect(try package.loadEdit() == nil)

        var edit = EditConfig.initial(for: meta)
        edit.zoom.keyframes.append(ZoomKeyframe(time: 2, target: NormPoint(x: 0.2, y: 0.8), mode: .followMouse))
        edit.cursor.style = .fixed(.pointingHand)
        edit.background.fill = .solid(.white)
        edit.blur.append(BlurMask(start: 1, end: 3))
        try package.saveEdit(edit)
        #expect(try package.loadEdit() == edit)
    }

    @Test func effectiveEditSeedsClicksAndNormalizesSavedEdit() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pk-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try RecordingPackage.create(in: root)
        let meta = sampleMeta()
        let click = InputEvent(t: 2, kind: .down, x: 0.25, y: 0.75, button: 0)
        try InputEventLog.encodeLine(click).write(to: package.url(PackageLayout.events))
        let initial = try package.loadEffectiveEdit(meta: meta, autoZoom: true)
        #expect(initial.zoom.keyframes.count == 1)
        #expect(try package.loadEffectiveEdit(meta: meta, autoZoom: false).zoom.keyframes.isEmpty)
        var saved = initial
        saved.zoom.keyframes = []
        try package.saveEdit(saved)
        #expect(try package.loadEffectiveEdit(meta: meta, autoZoom: true).zoom.keyframes.isEmpty)
    }

    @Test func initialEditReflectsMeta() {
        let edit = EditConfig.initial(for: sampleMeta())
        #expect(edit.segments.count == 1)
        #expect(edit.segments[0].end == 12.5)
        #expect(edit.webcam.enabled)
        #expect(edit.cursor.enabled)
        #expect(!edit.audio.microphone.enabled)
    }

    @Test func eventLogSkipsTruncatedLine() throws {
        var data = try InputEventLog.encodeLine(InputEvent(t: 0.5, kind: .down, x: 0.1, y: 0.2, button: 0, cursor: 1))
        data.append(contentsOf: Array(#"{"t":1.0,"k":"mo"#.utf8))
        let events = InputEventLog.decode(data)
        #expect(events.count == 1)
        #expect(events[0].isLeftClick)
    }

    @Test(arguments: ["#3b82f6", "3B82F6FF", "#fff"])
    func colourHexParses(hex: String) {
        #expect(RGBAColor(hex: hex) != nil)
    }

    @Test func zoomKeyframeEnd() {
        let kf = ZoomKeyframe(time: 1, easeIn: 0.2, hold: 1, easeOut: 0.3)
        #expect(abs(kf.end - 2.5) < 1e-9)
        var instant = kf
        instant.instant = true
        #expect(abs(instant.end - 2.0) < 1e-9)
    }
}
