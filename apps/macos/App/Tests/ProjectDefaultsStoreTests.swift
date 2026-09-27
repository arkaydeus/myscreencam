import Foundation
import ProjectKit
import Testing

@testable import MyScreenArt_Dev

@MainActor
struct ProjectDefaultsStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "msa-defaults-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func startsWithBuiltInDefaults() {
        #expect(ProjectDefaultsStore(userDefaults: freshDefaults()).defaults == ProjectDefaults())
    }

    @Test func changesPersist() {
        let userDefaults = freshDefaults()
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
        let userDefaults = freshDefaults()
        userDefaults.set(false, forKey: ProjectDefaultsStore.legacyAutoZoomKey)
        #expect(!ProjectDefaultsStore.load(from: userDefaults).autoZoom)

        // Once saved, the new value wins over the old key.
        let store = ProjectDefaultsStore(userDefaults: userDefaults)
        store.defaults.autoZoom = true
        #expect(ProjectDefaultsStore.load(from: userDefaults).autoZoom)
    }

    @Test func unreadableValueFallsBackToBuiltIns() {
        let userDefaults = freshDefaults()
        userDefaults.set(Data("not json".utf8), forKey: ProjectDefaultsStore.key)
        #expect(ProjectDefaultsStore.load(from: userDefaults) == ProjectDefaults())
    }
}
