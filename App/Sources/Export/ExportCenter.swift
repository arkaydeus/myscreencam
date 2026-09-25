import Foundation
import Observation

/// Tracks running exports app-wide (skeleton — the Export area implements it).
/// Other areas rely only on: `isExporting`, `cancelAll()`, `waitUntilIdle()`.
@MainActor
@Observable
final class ExportCenter {
    var isExporting: Bool { false }

    func cancelAll() {}

    /// Returns when no export is running.
    func waitUntilIdle() async {}
}
