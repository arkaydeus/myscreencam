import Dispatch
import Foundation
import Synchronization

/// Cancellation and first-failure bookkeeping shared by a job and its pipeline.
final class ExportControl: Sendable {
    private struct State {
        var cancelled = false
        var failure: ExportError?
        var abortHandler: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// The first failure recorded by the pipeline (append failure, stall), if any.
    var failure: ExportError? { state.withLock { $0.failure } }

    /// Whether the pipeline should stop: cancelled or failed.
    var shouldStop: Bool { state.withLock { $0.cancelled || $0.failure != nil } }

    /// Requests cancellation. Idempotent and safe from any thread.
    func cancel() {
        let handler: (@Sendable () -> Void)? = state.withLock { state in
            guard !state.cancelled else { return nil }
            state.cancelled = true
            return state.abortHandler
        }
        handler?()
    }

    /// Records a failure (the first one wins) and aborts the running pipeline.
    func fail(_ error: ExportError) {
        let handler: (@Sendable () -> Void)? = state.withLock { state in
            guard state.failure == nil, !state.cancelled else { return nil }
            state.failure = error
            return state.abortHandler
        }
        handler?()
    }

    /// Installs the pipeline's abort routine (end the pumps). Runs it immediately if the job was
    /// already cancelled or failed. Install it only after the pumps have started.
    func setAbortHandler(_ handler: (@Sendable () -> Void)?) {
        let runNow = state.withLock { state in
            state.abortHandler = handler
            return state.cancelled || state.failure != nil
        }
        if runNow { handler?() }
    }

    func checkCancelled() throws(ExportError) {
        if isCancelled { throw .cancelled }
    }
}

/// Aborts the export when nothing has been appended for `timeout`, so a wedged compositor or encoder
/// surfaces as an error instead of a progress bar that never moves.
final class StallWatchdog: @unchecked Sendable {
    // `timer` is created in `init` and only cancelled in `stop()`; DispatchSource is thread-safe.
    private let timer: any DispatchSourceTimer

    init(timeout: Duration, reporter: ProgressReporter, control: ExportControl) {
        let seconds = timeout.seconds
        let interval = max(0.5, seconds / 4)
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(
            deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        timer.setEventHandler {
            if reporter.secondsSinceActivity > seconds {
                control.fail(.stalled(seconds: seconds))
            }
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }

    deinit {
        timer.cancel()
    }
}

/// Resumes a continuation exactly once, whichever of several racing events comes first.
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func callAsFunction(_ value: Value) {
        let pending = continuation.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// How a pipeline's pumps ended.
enum PumpOutcome: Sendable {
    /// Every pump returned; the reader and writer are idle and safe to cancel or finish.
    case finished
    /// The stall watchdog fired while a pump was stuck inside AVFoundation. Cancelling the reader
    /// from another thread while it's inside `copyNextSampleBuffer` crashes AVFoundation, so the
    /// wedged pipeline is abandoned (it stops by itself if the stuck call ever returns).
    case abandoned

    var isAbandoned: Bool { self == .abandoned }
}

extension ExportError {
    var isStall: Bool {
        if case .stalled = self { return true }
        return false
    }
}
