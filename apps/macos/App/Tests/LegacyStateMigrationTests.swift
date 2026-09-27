import Foundation
import Testing

@testable import MyScreenCam

struct LegacyStateMigrationTests {
    @Test func carriesPreferencesAndSupportFilesOnce() throws {
        let suffix = UUID().uuidString.lowercased()
        let oldID = "com.myscreenart.app.\(suffix)"
        let newID = "com.myscreencam.app.\(suffix)"
        let defaults = UserDefaults(suiteName: newID)!
        defaults.setPersistentDomain(["recorder.codec": "h264", "shell.globalHotkeysEnabled": false], forName: oldID)
        defaults.set("hevc", forKey: "recorder.codec")
        defer {
            defaults.removePersistentDomain(forName: oldID)
            defaults.removePersistentDomain(forName: newID)
        }
        let support = FileManager.default.temporaryDirectory.appending(path: "msc-support-\(suffix)")
        defer { try? FileManager.default.removeItem(at: support) }
        let previous = support.appending(path: oldID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: previous.appending(path: "Models"), withIntermediateDirectories: true)
        try Data("preset".utf8).write(to: previous.appending(path: "presets.json"))
        try Data("model".utf8).write(to: previous.appending(path: "Models/model.bin"))

        try LegacyStateMigration.migrate(bundleIdentifier: newID, defaults: defaults, supportDirectory: support)
        #expect(defaults.string(forKey: "recorder.codec") == "hevc")
        #expect(defaults.object(forKey: "shell.globalHotkeysEnabled") as? Bool == false)
        #expect(defaults.bool(forKey: LegacyStateMigration.marker))
        let current = support.appending(path: newID)
        #expect(FileManager.default.fileExists(atPath: current.appending(path: "presets.json").path))
        #expect(FileManager.default.fileExists(atPath: current.appending(path: "Models/model.bin").path))
        defaults.removeObject(forKey: "shell.globalHotkeysEnabled")
        try LegacyStateMigration.migrate(bundleIdentifier: newID, defaults: defaults, supportDirectory: support)
        #expect(defaults.persistentDomain(forName: newID)?["shell.globalHotkeysEnabled"] == nil)
    }
}
