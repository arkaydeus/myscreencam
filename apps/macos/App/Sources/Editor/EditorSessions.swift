import Foundation
import MyScreenCamCore
import Observation

/// The open editor windows' models. Other areas rely only on `hasPendingSaves`, `flushAll()`, `isAnyPlaying` and
/// `session(for:)` (transcription commits a finished transcript through `EditorModel.receiveTranscript(_:)`).
///
/// Each `EditorModel` autosaves through its own `EditAutosaver` (500 ms debounce) and flushes on window close,
/// rename and delete; `flushAll()` covers app termination.
@MainActor
@Observable
final class EditorSessions {
    private var sessions: [URL: EditorModel] = [:]
    @ObservationIgnored private var closing: [URL: (UUID, Task<Void, Never>)] = [:]

    /// True while any editor is playing (transcription holds GPU-heavy work meanwhile).
    var isAnyPlaying: Bool { sessions.values.contains { $0.clock.isPlaying } }

    /// True while any open editor has edits that aren't on disk yet.
    var hasPendingSaves: Bool { sessions.values.contains { $0.hasUnsavedChanges } }

    /// Writes every unsaved edit to disk now (synchronously: it runs right before the app terminates).
    func flushAll() {
        for model in sessions.values { model.flushSynchronously() }
    }

    /// The model already open for a package, if any.
    func session(for packageURL: URL) -> EditorModel? { sessions[packageURL.standardizedFileURL] }

    func register(_ model: EditorModel, resetEdit: Bool = false) async {
        let key = model.package.url.standardizedFileURL
        await waitForClose(of: key)
        // The loader may have read edit.json before a transcription committed. Refresh at registration,
        // after all background loading and rendering, before the new editor can accept user edits.
        do {
            if resetEdit {
                try model.package.saveEdit(model.edit)
            } else if let latest = try model.package.loadEdit() {
                if latest != model.edit { model.apply(latest, action: "Load Latest Edits") }
            } else {
                try model.package.saveEdit(model.edit)
            }
        } catch {
            Log.app.error("Couldn't refresh editor edits: \(error)")
        }
        sessions[key] = model
    }

    func waitForClose(of packageURL: URL) async {
        await closing[packageURL.standardizedFileURL]?.1.value
    }

    /// Saves and releases a session when its window closes.
    func close(_ model: EditorModel) async {
        let key = model.package.url.standardizedFileURL
        if sessions[key] === model { sessions[key] = nil }
        let id = UUID()
        let previous = closing[key]?.1
        let task = Task {
            await previous?.value
            await model.close()
        }
        closing[key] = (id, task)
        await task.value
        if closing[key]?.0 == id { closing[key] = nil }
    }
}
