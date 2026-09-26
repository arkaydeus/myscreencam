import AppKit
import MyScreenArtCore
import ProjectKit
import UniformTypeIdentifiers

/// The shell's verbs, shared by menus, the Dock menu, global hotkeys, the URL scheme and App Intents.
/// Everything goes through `AppRouter` and the `RecordingController` skeleton API.
@MainActor
final class ShellActions {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var isRecording: Bool { model.recording.isActive }

    var canTogglePause: Bool {
        if case .recording = model.recording.state { return true }
        return false
    }

    func showLibrary() { model.router.showLibrary() }

    func newRecording(source: RecorderSourceKind? = nil) {
        guard !model.recording.isActive else {
            Log.app.info("New recording ignored: a recording is already active")
            return
        }
        model.router.showRecorder(source: source)
    }

    func finishRecording() {
        guard model.recording.isActive else { return }
        Task { await model.recording.stop() }
    }

    func togglePause() {
        guard canTogglePause else { return }
        model.recording.togglePause()
    }

    func perform(_ command: AppURLCommand) {
        switch command {
        case .newRecording(let source): newRecording(source: source.map(RecorderSourceKind.init))
        case .showLibrary: showLibrary()
        case .finishRecording: finishRecording()
        }
    }

    /// File > Open Recording…: a panel limited to recording packages, opened in the editor.
    func openRecordingWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Recording"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.myScreenArtRecording]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        if case .success(let root) = model.environment.recordingsRoot { panel.directoryURL = root }
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openRecording(at: url) }
    }

    func openRecording(at url: URL) {
        guard url.pathExtension.lowercased() == PackageLayout.packageExtension else {
            Log.app.error("Not a recording package: \(url.path(), privacy: .public)")
            return
        }
        model.router.openEditor(for: url)
    }
}

extension UTType {
    /// A `.msarec` recording package, declared in `App/Info.plist` (`UTExportedTypeDeclarations`).
    static let myScreenArtRecording = UTType(exportedAs: PackageLayout.packageUTType, conformingTo: .package)
}
