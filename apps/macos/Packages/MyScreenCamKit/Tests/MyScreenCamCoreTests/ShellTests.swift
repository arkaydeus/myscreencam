import Foundation
import Testing

@testable import MyScreenCamCore

struct AppURLCommandTests {
    @Test(arguments: [
        ("myscreencam://record", AppURLCommand.newRecording(source: nil)),
        ("myscreencam://new-recording", .newRecording(source: nil)),
        ("myscreencam://display", .newRecording(source: .display)),
        ("myscreencam://record-display", .newRecording(source: .display)),
        ("myscreencam://window", .newRecording(source: .window)),
        ("myscreencam://record-window", .newRecording(source: .window)),
        ("myscreencam://region", .newRecording(source: .region)),
        ("myscreencam://record-region", .newRecording(source: .region)),
        ("myscreencam://projects", .showLibrary),
        ("myscreencam://show-projects", .showLibrary),
        ("myscreencam://library", .showLibrary),
        ("myscreencam://stop", .finishRecording),
        ("myscreencam://finish", .finishRecording),
    ])
    func actionFromHost(url: String, expected: AppURLCommand) throws {
        #expect(AppURLCommand.parse(try #require(URL(string: url))) == expected)
    }

    @Test(arguments: [
        ("myscreencam:record", AppURLCommand.newRecording(source: nil)),
        ("myscreencam:///display", .newRecording(source: .display)),
        ("myscreencam:/library/extra", .showLibrary),
        ("myscreencam-dev:finish?now=1", .finishRecording),
    ])
    func actionFromPathWhenHostIsMissing(url: String, expected: AppURLCommand) throws {
        #expect(AppURLCommand.parse(try #require(URL(string: url))) == expected)
    }

    @Test func hostWinsOverPath() throws {
        let url = try #require(URL(string: "myscreencam://window/display"))
        #expect(AppURLCommand.parse(url) == .newRecording(source: .window))
    }

    @Test func matchingIsCaseInsensitive() throws {
        let url = try #require(URL(string: "MyScreenCam://Record-Region"))
        #expect(AppURLCommand.parse(url, allowedSchemes: ["myscreencam"]) == .newRecording(source: .region))
    }

    @Test(arguments: ["myscreencam://", "myscreencam://unknown", "myscreencam:///", "myscreencam:"])
    func unknownOrMissingActionIsNil(url: String) throws {
        #expect(AppURLCommand.parse(try #require(URL(string: url))) == nil)
    }

    @Test func schemeMustBeAllowedWhenGiven() throws {
        let url = try #require(URL(string: "myscreencam://record"))
        #expect(AppURLCommand.parse(url, allowedSchemes: ["myscreencam-dev"]) == nil)
        #expect(AppURLCommand.parse(url, allowedSchemes: ["myscreencam"]) == .newRecording(source: nil))
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
