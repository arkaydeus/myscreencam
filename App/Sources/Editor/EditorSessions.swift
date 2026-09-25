import Foundation
import Observation

/// Open editor sessions (skeleton — the Editor area implements it).
/// Other areas rely only on: `hasPendingSaves`, `flushAll()`.
@MainActor
@Observable
final class EditorSessions {
    var hasPendingSaves: Bool { false }

    /// Writes every unsaved edit to disk now.
    func flushAll() {}
}
