import Foundation
import MyScreenArtCore

/// Debounced autosave of `edit.json`: the latest scheduled config is written (atomically) once no newer one has
/// arrived for `debounce` (500 ms by default). Call ``flush()`` on window close, project switch, rename and quit.
///
/// A failed save keeps the unsaved snapshot: ``hasPendingChanges`` stays true, ``lastError`` is set, `onError`
/// is called, and the next ``schedule(_:)`` or ``flush()`` retries.
public actor EditAutosaver {
    public typealias Writer = @Sendable (EditConfig, RecordingPackage) throws -> Void

    public nonisolated let package: RecordingPackage
    public nonisolated let debounce: Duration
    private let writer: Writer
    private let onError: (@Sendable (any Error) -> Void)?

    private var pending: EditConfig?
    private var timer: Task<Void, Never>?

    /// The error from the most recent failed save; cleared by a successful one.
    public private(set) var lastError: (any Error)?
    /// The config most recently written to disk by this autosaver.
    public private(set) var lastSaved: EditConfig?

    /// - Parameters:
    ///   - writer: performs the write; defaults to `RecordingPackage.saveEdit` (atomic). Injectable for tests.
    ///   - onError: called (on the actor) whenever a debounced or flushed save fails.
    public init(
        package: RecordingPackage, debounce: Duration = .milliseconds(500), writer: Writer? = nil,
        onError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.package = package
        self.debounce = debounce
        self.writer = writer ?? { edit, package in try package.saveEdit(edit) }
        self.onError = onError
    }

    deinit {
        timer?.cancel()
    }

    /// True while a scheduled (or failed) snapshot hasn't been written yet.
    public var hasPendingChanges: Bool { pending != nil }

    /// Queues `config` for saving, replacing any older unsaved snapshot, and restarts the debounce.
    public func schedule(_ config: EditConfig) {
        pending = config
        timer?.cancel()
        let delay = debounce
        timer = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self.timerFired()
        }
    }

    /// Writes the pending snapshot now (if any), cancelling the debounce.
    /// - Throws: the write error; the snapshot stays pending for a retry.
    public func flush() throws {
        timer?.cancel()
        timer = nil
        try saveNow()
    }

    private func timerFired() {
        guard !Task.isCancelled else { return }
        timer = nil
        try? saveNow()
    }

    private func saveNow() throws {
        guard let snapshot = pending else { return }
        do {
            try writer(snapshot, package)
            pending = nil
            lastSaved = snapshot
            lastError = nil
        } catch {
            lastError = error
            Log.app.error("Autosave failed for \(self.package.url.lastPathComponent, privacy: .public): \(error)")
            onError?(error)
            throw error
        }
    }
}
