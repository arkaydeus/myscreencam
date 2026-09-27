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
