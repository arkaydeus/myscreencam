import Foundation
import Testing

@testable import MyScreenCamCore

struct AppFlavorTests {
    @Test(arguments: [
        ("com.myscreencam.app.dev", AppFlavor.development),
        ("com.myscreencam.app", AppFlavor.release),
        (nil, AppFlavor.release),
    ])
    func flavorFromBundleIdentifier(bundleIdentifier: String?, expected: AppFlavor) {
        #expect(AppFlavor(bundleIdentifier: bundleIdentifier) == expected)
    }
}

struct RecordingsLocationTests {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    @Test func releaseUsesMoviesFolder() throws {
        let url = try RecordingsLocation.resolve(flavor: .release, environment: [:], homeDirectory: home)
        #expect(url.path(percentEncoded: false) == "/Users/tester/Movies/My Screen Cam/")
    }

    @Test func developmentDefaultsToSharedDevFolder() throws {
        let url = try RecordingsLocation.resolve(flavor: .development, environment: [:], homeDirectory: home)
        #expect(url.path(percentEncoded: false) == "/Users/tester/Movies/My Screen Cam Dev/default/")
    }

    @Test(arguments: [AppFlavor.development, .release])
    func absoluteOverrideWins(flavor: AppFlavor) throws {
        let env = [RecordingsLocation.overrideKey: "/tmp/msc/../msc-recordings"]
        let url = try RecordingsLocation.resolve(flavor: flavor, environment: env, homeDirectory: home)
        #expect(url.path(percentEncoded: false) == "/tmp/msc-recordings/")
    }

    @Test func emptyOverrideIsIgnored() throws {
        let env = [RecordingsLocation.overrideKey: ""]
        let url = try RecordingsLocation.resolve(flavor: .release, environment: env, homeDirectory: home)
        #expect(url.path(percentEncoded: false) == "/Users/tester/Movies/My Screen Cam/")
    }

    @Test func relativeOverrideIsRejected() {
        let env = [RecordingsLocation.overrideKey: "recordings"]
        #expect(throws: RecordingsLocation.ResolutionError.relativeOverride("recordings")) {
            try RecordingsLocation.resolve(flavor: .release, environment: env, homeDirectory: home)
        }
    }

    @Test func prepareCreatesFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "msc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = [RecordingsLocation.overrideKey: root.appending(path: "nested/recordings").path()]

        let url = try RecordingsLocation.prepare(flavor: .development, environment: env, homeDirectory: home)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path(), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

extension RecordingsLocationTests {
    @Test func releaseMovesLegacyPackagesWithoutOverwritingCurrentFiles() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "msc-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appending(path: "Movies/MyScreenArt", directoryHint: .isDirectory)
        let current = home.appending(path: "Movies/My Screen Cam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let source = old.appending(path: "Recording_old.msarec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: source.appending(path: "meta.json"))
        let collision = old.appending(path: "Recording_kept.msarec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: current.appending(path: collision.lastPathComponent), withIntermediateDirectories: true)

        let result = try RecordingsLocation.prepare(flavor: .release, environment: [:], homeDirectory: home)
        #expect(result == current)
        #expect(FileManager.default.fileExists(atPath: current.appending(path: "Recording_old.msarec/meta.json").path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: collision.path))
        _ = try RecordingsLocation.prepare(flavor: .release, environment: [:], homeDirectory: home)
    }

    @Test func developmentMigratesMatchingWorktreeOnly() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "msc-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appending(
            path: "Movies/MyScreenArt Dev/worktree-a/Recording_old.msarec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let target = home.appending(path: "Movies/My Screen Cam Dev/worktree-a", directoryHint: .isDirectory)
        let result = try RecordingsLocation.prepare(
            flavor: .development,
            environment: [RecordingsLocation.overrideKey: target.path], homeDirectory: home)
        #expect(result == target)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: old.lastPathComponent).path))
    }
}
