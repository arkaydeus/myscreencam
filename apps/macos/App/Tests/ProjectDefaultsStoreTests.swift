import Foundation
import ProjectKit
import Testing

@testable import MyScreenArt_Dev

nonisolated private final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func data(forKey defaultName: String) -> Data? {
        lock.withLock { values[defaultName] as? Data }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        _ = lock.withLock { values.removeValue(forKey: defaultName) }
    }
}

@MainActor
struct ProjectDefaultsStoreTests {
    @Test func startsWithBuiltInDefaults() {
        #expect(ProjectDefaultsStore(userDefaults: InMemoryDefaults()).defaults == ProjectDefaults())
    }

    @Test func changesPersist() {
        let userDefaults = InMemoryDefaults()
        let store = ProjectDefaultsStore(userDefaults: userDefaults)
        store.defaults.zoomTiming.scale = 2.2
        store.defaults.subtitles.style.uppercase = true
        store.defaults.subtitles.placement.anchor = .top

        let reloaded = ProjectDefaultsStore.load(from: userDefaults)
        #expect(reloaded.zoomTiming.scale == 2.2)
        #expect(reloaded.subtitleStyle.uppercase)
        #expect(reloaded.subtitlePlacement.anchor == .top)

        store.resetToBuiltIn()
        #expect(ProjectDefaultsStore.load(from: userDefaults) == ProjectDefaults())
    }

    @Test func migratesTheOldAutoZoomPreference() {
        let userDefaults = InMemoryDefaults()
        userDefaults.set(false, forKey: ProjectDefaultsStore.legacyAutoZoomKey)
        #expect(!ProjectDefaultsStore.load(from: userDefaults).autoZoom)

        // Once saved, the new value wins over the old key.
        let store = ProjectDefaultsStore(userDefaults: userDefaults)
        store.defaults.autoZoom = true
        #expect(ProjectDefaultsStore.load(from: userDefaults).autoZoom)
    }

    @Test func unreadableValueFallsBackToBuiltIns() {
        let userDefaults = InMemoryDefaults()
        userDefaults.set(Data("not json".utf8), forKey: ProjectDefaultsStore.key)
        #expect(ProjectDefaultsStore.load(from: userDefaults) == ProjectDefaults())
    }
}
