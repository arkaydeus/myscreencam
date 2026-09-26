import Foundation
import Testing

@testable import MyScreenArtCore

struct AppURLCommandTests {
    @Test(arguments: [
        ("myscreenart://record", AppURLCommand.newRecording(source: nil)),
        ("myscreenart://new-recording", .newRecording(source: nil)),
        ("myscreenart://display", .newRecording(source: .display)),
        ("myscreenart://record-display", .newRecording(source: .display)),
        ("myscreenart://window", .newRecording(source: .window)),
        ("myscreenart://record-window", .newRecording(source: .window)),
        ("myscreenart://region", .newRecording(source: .region)),
        ("myscreenart://record-region", .newRecording(source: .region)),
        ("myscreenart://projects", .showLibrary),
        ("myscreenart://show-projects", .showLibrary),
        ("myscreenart://library", .showLibrary),
        ("myscreenart://stop", .finishRecording),
        ("myscreenart://finish", .finishRecording),
    ])
    func actionFromHost(url: String, expected: AppURLCommand) throws {
        #expect(AppURLCommand.parse(try #require(URL(string: url))) == expected)
    }

    @Test(arguments: [
        ("myscreenart:record", AppURLCommand.newRecording(source: nil)),
        ("myscreenart:///display", .newRecording(source: .display)),
        ("myscreenart:/library/extra", .showLibrary),
        ("myscreenart-dev:finish?now=1", .finishRecording),
    ])
    func actionFromPathWhenHostIsMissing(url: String, expected: AppURLCommand) throws {
        #expect(AppURLCommand.parse(try #require(URL(string: url))) == expected)
    }

    @Test func hostWinsOverPath() throws {
        let url = try #require(URL(string: "myscreenart://window/display"))
        #expect(AppURLCommand.parse(url) == .newRecording(source: .window))
    }

    @Test func matchingIsCaseInsensitive() throws {
        let url = try #require(URL(string: "MyScreenArt://Record-Region"))
        #expect(AppURLCommand.parse(url, allowedSchemes: ["myscreenart"]) == .newRecording(source: .region))
    }

    @Test(arguments: ["myscreenart://", "myscreenart://unknown", "myscreenart:///", "myscreenart:"])
    func unknownOrMissingActionIsNil(url: String) throws {
        #expect(AppURLCommand.parse(try #require(URL(string: url))) == nil)
    }

    @Test func schemeMustBeAllowedWhenGiven() throws {
        let url = try #require(URL(string: "myscreenart://record"))
        #expect(AppURLCommand.parse(url, allowedSchemes: ["myscreenart-dev"]) == nil)
        #expect(AppURLCommand.parse(url, allowedSchemes: ["myscreenart"]) == .newRecording(source: nil))
        #expect(AppURLCommand.parse(url, allowedSchemes: []) == nil)
    }
}

struct DockIconPolicyTests {
    @Test func accessoryOnlyWhenPreferenceOnAndIdleWithoutWindows() {
        #expect(DockIconPolicy.resolve(hideWhenIdle: true, hasVisibleWindows: false, isRecording: false) == .accessory)
    }

    @Test(arguments: [
        (false, false, false),
        (true, true, false),
        (true, false, true),
        (false, true, true),
    ])
    func otherwiseRegular(hideWhenIdle: Bool, hasVisibleWindows: Bool, isRecording: Bool) {
        let policy = DockIconPolicy.resolve(
            hideWhenIdle: hideWhenIdle, hasVisibleWindows: hasVisibleWindows, isRecording: isRecording)
        #expect(policy == .regular)
    }
}

struct QuitGuardTests {
    @Test(arguments: [
        (false, false, QuitGuard.none),
        (true, false, .recording),
        (false, true, .exporting),
        (true, true, .recording),
    ])
    func resolve(isRecording: Bool, isExporting: Bool, expected: QuitGuard) {
        #expect(QuitGuard.resolve(isRecording: isRecording, isExporting: isExporting) == expected)
    }
}

struct UpdateConfigurationTests {
    @Test func acceptsA32ByteBase64Key() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(UpdateConfiguration.isValidEdDSAPublicKey(key))
        #expect(UpdateConfiguration.isValidEdDSAPublicKey(" \(key)\n"))
    }

    @Test(arguments: [
        nil, "", UpdateConfiguration.publicKeyPlaceholder, "not base64!",
        Data(repeating: 1, count: 16).base64EncodedString(),
    ])
    func rejectsPlaceholderAndMalformedKeys(key: String?) {
        #expect(!UpdateConfiguration.isValidEdDSAPublicKey(key))
    }
}
