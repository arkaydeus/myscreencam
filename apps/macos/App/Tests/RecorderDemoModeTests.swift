import AppKit
import CaptureKit
import MyScreenCamCore
import ScreenCaptureKit
import Testing

@testable import MyScreenCam

@MainActor
struct RecorderDemoModeTests {
    private func fixture(_ access: RecorderWindowModel.SourceAccess) -> (RecorderWindowModel, UserDefaults, String) {
        let suite = "recorder-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = RecordingController(
            environment: AppEnvironment(flavor: .development, recordingsRoot: .success(URL(filePath: "/tmp"))),
            router: AppRouter(), preferences: RecorderPreferences(defaults: defaults))
        return (RecorderWindowModel(controller: controller, sourceAccess: access), defaults, suite)
    }

    private func window(_ id: CGWindowID, own: Bool) -> WindowInfo {
        WindowInfo(
            id: id, title: own ? "Editor" : "Other app", appName: nil, bundleID: nil,
            processID: own ? ProcessInfo.processInfo.processIdentifier : -1,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    private func image() throws -> CGImage {
        try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
    }

    @Test func delayedDiscoveryCannotRepopulateCacheAfterDisablingOnAnotherTab() async throws {
        var response: CheckedContinuation<[WindowInfo], Never>?
        let started = AsyncStream<Void>.makeStream()
        var requests: [Bool] = []
        var access = RecorderWindowModel.SourceAccess()
        access.permissionStatus = { $0 == .screenRecording ? .granted : .denied }
        access.thumbnail = { _, _, _ in throw CancellationError() }
        access.windows = { demoMode in
            requests.append(demoMode)
            if !demoMode { return [] }
            return await withCheckedContinuation {
                response = $0
                started.continuation.yield(())
            }
        }
        let (model, defaults, suite) = fixture(access)
        defer { model.deactivate(); defaults.removePersistentDomain(forName: suite) }
        model.preferences.sourceKind = .window
        model.preferences.demoMode = true
        model.activate()
        let oldRequest = try #require(model.refreshWindows())
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        model.selectSourceKind(.display)
        model.preferences.demoMode = false
        model.demoModeChanged()
        response?.resume(returning: [window(42, own: true)])
        await oldRequest.value
        #expect(model.windows.isEmpty && !model.windowsLoaded)
        model.selectSourceKind(.window)
        await model.refreshWindows()?.value
        #expect(model.windows.isEmpty && model.windowsLoaded)
        #expect(requests.first == true && requests.last == false)
        model.preferences.windowID = 42
        #expect(model.startBlocker != nil)
        model.startRecording()
        #expect(model.controller.state == .idle)
    }

    @Test func disablingClearsOwnSelectionAndReloadsWindowTab() async {
        let own = window(42, own: true)
        var access = RecorderWindowModel.SourceAccess()
        access.permissionStatus = { $0 == .screenRecording ? .granted : .denied }
        access.thumbnail = { _, _, _ in throw CancellationError() }
        access.windows = { $0 ? [own] : [] }
        let (model, defaults, suite) = fixture(access)
        defer { model.deactivate(); defaults.removePersistentDomain(forName: suite) }
        model.preferences.sourceKind = .window
        model.preferences.demoMode = true
        model.activate()
        await model.refreshWindows()?.value
        model.selectWindow(42)
        #expect(model.startBlocker == nil)
        model.preferences.demoMode = false
        model.demoModeChanged()
        #expect(model.preferences.windowID == nil && model.selectedWindow == nil)
        await model.refreshWindows()?.value
        #expect(model.windowsLoaded && model.windows.isEmpty)
    }

    @Test(arguments: [RecorderSourceKind.display, .region])
    func previewAndRecordingFollowDemoMode(kind: RecorderSourceKind) async throws {
        let still = try image()
        let previews = AsyncStream<Bool>.makeStream()
        var iterator = previews.stream.makeAsyncIterator()
        var access = RecorderWindowModel.SourceAccess()
        access.permissionStatus = { $0 == .screenRecording ? .granted : .denied }
        access.thumbnail = { _, _, excluded in
            previews.continuation.yield(excluded); return still
        }
        let (model, defaults, suite) = fixture(access)
        defer { model.deactivate(); defaults.removePersistentDomain(forName: suite) }
        model.preferences.sourceKind = kind
        model.preferences.region = .init(displayID: CGMainDisplayID(), rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        model.activate()
        for demoMode in [false, true, false] {
            model.preferences.demoMode = demoMode
            model.demoModeChanged()
            #expect(await iterator.next() == !demoMode)
            await model.refreshSourcePreview()?.value
            _ = await iterator.next()
            #expect(model.sourcePreview != nil)
            let source = try #require(model.preferences.selectedSource)
            #expect(
                model.controller.makeOptions(source: source, root: URL(filePath: "/tmp")).excludesOwnApplication
                    == !demoMode)
        }
    }

    @Test func pickerUsesCurrentModeAndDiscardsResultAfterToggle() {
        var modes: [Bool] = []
        var completion: ((ScreenSource?) -> Void)?
        var access = RecorderWindowModel.SourceAccess()
        access.presentPicker = { mode, callback in
            modes.append(mode); completion = callback
        }
        let (model, defaults, suite) = fixture(access)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.preferences.sourceKind = .display
        model.chooseWithSystemPicker()
        model.preferences.demoMode = true
        model.chooseWithSystemPicker()
        model.preferences.demoMode = false
        model.demoModeChanged()
        completion?(.window(42))
        #expect(modes == [false, true])
        #expect(model.preferences.sourceKind == .display && model.preferences.windowID == nil)
    }

    @Test func recorderIsExcludedBeforeCountdownAndCannotBecomeACaptureSource() async {
        let control = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        control.isReleasedWhenClosed = false
        control.title = "New Recording"
        let reader = WindowVisibilityReader.ReaderView()
        control.contentView = reader
        defer { control.close() }
        let id = CGWindowID(control.windowNumber)
        #expect(control.sharingType == .none)
        #expect(CaptureSources.excludedWindowIDs.contains(id))
        for demoMode in [false, true] {
            let config = SystemContentPicker.configuration(includingOwnApplication: demoMode)
            #expect(config.excludedWindowIDs.contains(Int(id)))
            #expect(config.excludedBundleIDs.contains(Bundle.main.bundleIdentifier!) == !demoMode)
        }
        var access = RecorderWindowModel.SourceAccess()
        access.permissionStatus = { $0 == .screenRecording ? .granted : .denied }
        access.thumbnail = { _, _, _ in throw CancellationError() }
        access.windows = { _ in [window(id, own: true)] }
        let (model, defaults, suite) = fixture(access)
        defer { model.deactivate(); defaults.removePersistentDomain(forName: suite) }
        model.preferences.demoMode = true
        model.preferences.sourceKind = .window
        model.activate()
        await model.refreshWindows()?.value
        model.selectWindow(id)
        #expect(model.selectedWindow == nil && model.startBlocker != nil)
        model.startRecording()
        #expect(model.controller.state == .idle)
    }
}
