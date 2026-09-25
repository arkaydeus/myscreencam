import Foundation
import Observation

/// The open editor windows' models. Other areas rely only on `hasPendingSaves` and `flushAll()`.
///
/// Each `EditorModel` autosaves through its own `EditAutosaver` (500 ms debounce) and flushes on window close,
/// rename and delete; `flushAll()` covers app termination.
@MainActor
@Observable
final class EditorSessions {
    private var sessions: [URL: EditorModel] = [:]

    /// True while any open editor has edits that aren't on disk yet.
    var hasPendingSaves: Bool { sessions.values.contains { $0.hasUnsavedChanges } }

    /// Writes every unsaved edit to disk now (synchronously: it runs right before the app terminates).
    func flushAll() {
        for model in sessions.values { model.flushSynchronously() }
    }

    /// The model already open for a package, if any.
    func session(for packageURL: URL) -> EditorModel? { sessions[packageURL.standardizedFileURL] }

    func register(_ model: EditorModel) {
        sessions[model.package.url.standardizedFileURL] = model
    }

    /// Saves and releases a session when its window closes.
    func close(_ model: EditorModel) async {
        let key = model.package.url.standardizedFileURL
        await model.close()
        if sessions[key] === model { sessions[key] = nil }
    }
}
