import Foundation

/// Carries preferences and Application Support data across the bundle-ID rename. Run before constructing stores.
enum LegacyStateMigration {
    static let marker = "migration.myscreenart.v1"

    static func migrate(
        bundleIdentifier: String, defaults: UserDefaults = .standard,
        supportDirectory: URL = .applicationSupportDirectory, fileManager: FileManager = .default
    ) throws {
        guard bundleIdentifier.hasPrefix("com.myscreencam.app") else { return }
        let oldID = bundleIdentifier.replacingOccurrences(of: "com.myscreencam.app", with: "com.myscreenart.app")
        let oldDirectory = supportDirectory.appending(path: oldID, directoryHint: .isDirectory)
        let newDirectory = supportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: oldDirectory.path) {
            try fileManager.createDirectory(at: newDirectory, withIntermediateDirectories: true)
            for source in try fileManager.contentsOfDirectory(at: oldDirectory, includingPropertiesForKeys: nil) {
                let target = newDirectory.appending(path: source.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try fileManager.moveItem(at: source, to: target)
            }
        }

        guard !defaults.bool(forKey: marker) else { return }
        let existing = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        let previous = defaults.persistentDomain(forName: oldID) ?? [:]
        for (key, value) in previous where existing[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
    }
}
