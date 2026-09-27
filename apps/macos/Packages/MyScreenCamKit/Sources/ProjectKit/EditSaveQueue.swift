import Foundation

/// Orders debounced snapshots and explicit flushes through one consumer.
/// A flush cannot be followed by an older snapshot that was already queued.
@MainActor
public final class EditSaveQueue {
    private enum Command: Sendable {
        case schedule(EditConfig)
        case flush(EditConfig, CheckedContinuation<Result<Void, any Error>, Never>)
    }

    public let autosaver: EditAutosaver
    private let continuation: AsyncStream<Command>.Continuation
    private var task: Task<Void, Never>?

    public init(autosaver: EditAutosaver) {
        self.autosaver = autosaver
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        self.continuation = continuation
        task = Task {
            for await command in stream {
                switch command {
                case .schedule(let edit): await autosaver.schedule(edit)
                case .flush(let edit, let waiter):
                    await autosaver.schedule(edit)
                    do {
                        try await autosaver.flush()
                        waiter.resume(returning: .success(()))
                    } catch {
                        waiter.resume(returning: .failure(error))
                    }
                }
            }
        }
    }

    public func schedule(_ edit: EditConfig) {
        continuation.yield(.schedule(edit))
    }

    public func flush(_ edit: EditConfig) async throws {
        let result = await withCheckedContinuation { waiter in
            continuation.yield(.flush(edit, waiter))
        }
        try result.get()
    }

    public func finish() {
        continuation.finish()
    }
}
