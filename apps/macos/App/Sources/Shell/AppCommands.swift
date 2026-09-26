import SwiftUI

extension FocusedValues {
    /// File > Export… (⌘E). The Editor area publishes it from the focused editor window:
    /// `.focusedSceneValue(\.exportAction) { showExportSheet = true }`. The menu item is disabled while
    /// no focused scene provides it.
    var exportAction: (() -> Void)? {
        get { self[ExportActionKey.self] }
        set { self[ExportActionKey.self] = newValue }
    }
}

private struct ExportActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Main-menu commands. The standard Edit menu (Undo/Redo through SwiftUI's `UndoManager`, Cut/Copy/Paste)
/// is left in place.
struct AppCommands: Commands {
    let shell: AppShell
    @FocusedValue(\.exportAction) private var exportAction

    private var actions: ShellActions { shell.actions }
    private var recording: RecordingController { shell.model.recording }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { shell.updates.checkForUpdates() }
                .disabled(!shell.updates.canCheckForUpdates)
            Toggle("Hide Dock Icon When Idle", isOn: Bindable(shell.settings).hideDockIconWhenIdle)
        }

        // Replaces "New Window" items for the scenes, which would open an empty editor or a second recorder.
        CommandGroup(replacing: .newItem) {
            Button("Show Library") { actions.showLibrary() }
                .keyboardShortcut("1", modifiers: .command)
            Button("New Recording") { actions.newRecording() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(recording.isActive)
            Divider()
            Button("Finish Recording") { actions.finishRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!recording.isActive)
            Button(isPaused ? "Resume Recording" : "Pause Recording") { actions.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .option, .shift])
                .disabled(!actions.canTogglePause)
            Divider()
            Button("Open Recording…") { actions.openRecordingWithPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .importExport) {
            Button("Export…") { exportAction?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exportAction == nil)
        }
    }

    private var isPaused: Bool {
        if case .recording(_, let paused) = recording.state { return paused }
        return false
    }
}
