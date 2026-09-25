import Foundation
import Testing

@testable import ProjectKit

struct PresetStoreTests {
    func styled() -> EditConfig {
        var config = EditConfig.initial(for: Fixtures.meta())
        config.webcam.width = 0.3
        config.webcam.mirrored = true
        config.audio.microphone.gainDB = 4
        config.cursor.style = .fixed(.pointingHand)
        config.zoom.defaults = ZoomTiming(scale: 2.2, easeIn: 0.3, hold: 1.2, easeOut: 0.4)
        config.background.enabled = true
        config.background.fill = .solid(.black)
        return config
    }

    @Test func emptyWhenNoFile() async throws {
        let dir = try TempDirectory()
        #expect(try await PresetStore(directory: dir.url).list().isEmpty)
    }

    @Test func saveListDelete() async throws {
        let dir = try TempDirectory()
        let store = PresetStore(directory: dir.url.appending(path: "nested"))
        let b = try await store.save(EditPreset(name: "  Bravo ", from: styled()))
        #expect(b.name == "Bravo")
        try await store.save(EditPreset(name: "alpha"))
        #expect(try await store.list().map(\.name) == ["alpha", "Bravo"])

        // Persisted: a fresh store sees the same presets.
        let reopened = PresetStore(directory: dir.url.appending(path: "nested"))
        let loaded = try await reopened.list()
        #expect(loaded.count == 2)
        #expect(loaded.first { $0.name == "Bravo" } == b)

        try await reopened.delete(id: b.id)
        #expect(try await store.list().map(\.name) == ["alpha"])
        try await reopened.delete(id: UUID())  // no-op
    }

    @Test func saveReplacesSameNameCaseInsensitively() async throws {
        let dir = try TempDirectory()
        let store = PresetStore(directory: dir.url)
        let original = try await store.save(EditPreset(name: "Tutorial"))
        let replacement = try await store.save(EditPreset(name: "TUTORIAL ", from: styled()))
        let all = try await store.list()
        #expect(all.count == 1)
        #expect(replacement.id == original.id)
        #expect(all[0].name == "TUTORIAL")
        #expect(all[0].webcam.width == 0.3)
    }

    @Test func renamingOntoAnotherNameReplacesIt() async throws {
        let dir = try TempDirectory()
        let store = PresetStore(directory: dir.url)
        var a = try await store.save(EditPreset(name: "A"))
        try await store.save(EditPreset(name: "B"))
        a.name = "b"
        try await store.save(a)
        #expect(try await store.list().map(\.name) == ["b"])
    }

    @Test func rejectsEmptyNameAndCorruptFile() async throws {
        let dir = try TempDirectory()
        let store = PresetStore(directory: dir.url)
        await #expect(throws: PresetStore.StoreError.emptyName) { try await store.save(EditPreset(name: "  ")) }

        try Data("{nope".utf8).write(to: store.fileURL)
        await #expect(throws: (any Error).self) { try await store.list() }
        await #expect(throws: (any Error).self) { try await store.save(EditPreset(name: "X")) }
        #expect(try Data(contentsOf: store.fileURL) == Data("{nope".utf8))  // never overwritten
    }

    @Test func applyKeepsContentAndReplacesLook() async throws {
        let preset = EditPreset(name: "Look", from: styled())
        var target = EditConfig.initial(for: Fixtures.meta())
        target.segments.append(Segment(start: 10, end: 12))
        target.zoom.enabled = false
        target.zoom.keyframes = [ZoomKeyframe(time: 3)]
        target.blur = [BlurMask(start: 1, end: 2)]

        let applied = PresetStore(directory: URL(filePath: "/tmp")).apply(preset, to: target)
        #expect(applied.segments == target.segments)
        #expect(applied.zoom.keyframes == target.zoom.keyframes)
        #expect(applied.zoom.enabled == false)
        #expect(applied.blur == target.blur)
        #expect(applied.webcam == styled().webcam)
        #expect(applied.audio == styled().audio)
        #expect(applied.cursor == styled().cursor)
        #expect(applied.background == styled().background)
        #expect(applied.zoom.defaults == styled().zoom.defaults)
    }

    @Test func defaultDirectoryIsApplicationSupport() {
        let url = PresetStore.defaultDirectory(bundleIdentifier: "com.example.test")
        #expect(url.path.hasSuffix("Library/Application Support/com.example.test"))
    }
}
