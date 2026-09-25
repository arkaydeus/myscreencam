import AppKit
import MyScreenArtCore
import ProjectKit

/// AppKit lifecycle hooks SwiftUI doesn't cover: quit guards, Dock menu, reopen, URL scheme and
/// document opens. `MyScreenArtApp.init` hands it the `AppShell` before launch finishes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shell: AppShell?
    private var didFinishLaunching = false
    /// Set while a quit guard's alert is up or its work (stopping a recording) is running.
    private var isResolvingTermination = false
    /// Set by "Quit When Export Finishes": skip the export guard for the follow-up terminate.
    private var quitWhenExportFinishesPending = false

    private var model: AppModel? { shell?.model }

    // MARK: launch & reopen

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        shell?.start()
        if shell == nil { Log.app.fault("AppDelegate launched without an AppShell") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click (or relaunch from Finder) with no visible windows → Library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let shell else { return true }
        shell.actions.showLibrary()
        return false
    }

    // MARK: URL scheme & documents

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let shell else { return }
        // Opens that arrive before launch finishes are what the app was launched for: the Library window
        // SwiftUI shows at launch is closed again once the requested window is open.
        let isLaunchOpen = !didFinishLaunching
        var opensOtherWindow = false
        for url in urls {
            if url.isFileURL {
                if url.pathExtension.lowercased() == PackageLayout.packageExtension {
                    shell.actions.openRecording(at: url)
                    opensOtherWindow = true
                } else {
                    Log.app.error("Ignoring open of unsupported file \(url.lastPathComponent, privacy: .public)")
                }
                continue
            }
            guard let command = AppURLCommand.parse(url, allowedSchemes: AppShell.urlSchemes) else {
                Log.app.error("Unrecognised URL \(url.absoluteString, privacy: .public)")
                continue
            }
            Log.app.info("URL command \(String(describing: command), privacy: .public)")
            shell.actions.perform(command)
            if case .newRecording = command { opensOtherWindow = true }
        }
        if isLaunchOpen && opensOtherWindow { shell.model.router.preferLaunchTarget() }
    }

    // MARK: Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let shell else { return nil }
        let menu = NSMenu()
        if shell.actions.isRecording {
            menu.addItem(item("Finish Recording", #selector(dockFinishRecording)))
        } else {
            menu.addItem(item("New Recording", #selector(dockNewRecording)))
            menu.addItem(item("Record Display", #selector(dockRecordDisplay)))
            menu.addItem(item("Record Window", #selector(dockRecordWindow)))
            menu.addItem(item("Record Region", #selector(dockRecordRegion)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Show Library", #selector(dockShowLibrary)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func dockNewRecording() { shell?.actions.newRecording() }
    @objc private func dockRecordDisplay() { shell?.actions.newRecording(source: .display) }
    @objc private func dockRecordWindow() { shell?.actions.newRecording(source: .window) }
    @objc private func dockRecordRegion() { shell?.actions.newRecording(source: .region) }
    @objc private func dockShowLibrary() { shell?.actions.showLibrary() }
    @objc private func dockFinishRecording() { shell?.actions.finishRecording() }

    // MARK: quit guards

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if isResolvingTermination { return .terminateCancel }

        let exportGuardApplies = model.exports.isExporting && !quitWhenExportFinishesPending
        quitWhenExportFinishesPending = false
        switch QuitGuard.resolve(isRecording: model.recording.isActive, isExporting: exportGuardApplies) {
        case .none:
            model.editors.flushAll()
            return .terminateNow
        case .recording:
            isResolvingTermination = true
            Task { await resolveRecordingGuard(model) }
            return .terminateLater
        case .exporting:
            isResolvingTermination = true
            Task { await resolveExportGuard(model) }
            return .terminateLater
        }
    }

    private func resolveRecordingGuard(_ model: AppModel) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A recording is in progress"
        alert.informativeText = "Quitting stops the recording and saves what has been captured so far."
        alert.addButton(withTitle: "Stop Recording and Quit")
        alert.addButton(withTitle: "Keep Recording")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            finishTermination(quit: false)
            return
        }
        await model.recording.stop()
        // An export may have been running alongside the recording.
        if model.exports.isExporting {
            await resolveExportGuard(model)
            return
        }
        model.editors.flushAll()
        finishTermination(quit: true)
    }

    private func resolveExportGuard(_ model: AppModel) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An export is in progress"
        alert.informativeText = "Cancelling it discards the partially exported file."
        alert.addButton(withTitle: "Cancel Export and Quit")
        alert.addButton(withTitle: "Quit When Export Finishes")
        alert.addButton(withTitle: "Keep App Open")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.exports.cancelAll()
            await model.exports.waitUntilIdle()
            model.editors.flushAll()
            finishTermination(quit: true)
        case .alertSecondButtonReturn:
            // Keep the app usable while the export finishes, then quit without asking again.
            finishTermination(quit: false)
            Log.app.info("Will quit when exports finish")
            await model.exports.waitUntilIdle()
            quitWhenExportFinishesPending = true
            NSApp.terminate(nil)
        default:
            finishTermination(quit: false)
        }
    }

    private func finishTermination(quit: Bool) {
        isResolvingTermination = false
        NSApp.reply(toApplicationShouldTerminate: quit)
    }
}
