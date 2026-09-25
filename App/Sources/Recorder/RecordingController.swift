import Foundation
import Observation

/// Recording lifecycle for the whole app (skeleton — the Recorder area implements it).
/// Other areas rely only on: `state`, `isActive`, `stop()`, `togglePause()`.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case countingDown(remaining: Int)
        case recording(startedAt: Date, paused: Bool)
        case stopping
    }

    private(set) var state: State = .idle
    let environment: AppEnvironment
    let router: AppRouter

    init(environment: AppEnvironment, router: AppRouter) {
        self.environment = environment
        self.router = router
    }

    /// Counting down, recording or stopping.
    var isActive: Bool { state != .idle }

    /// Finishes the current recording and opens it in the editor.
    func stop() async {}

    func togglePause() {}
}
