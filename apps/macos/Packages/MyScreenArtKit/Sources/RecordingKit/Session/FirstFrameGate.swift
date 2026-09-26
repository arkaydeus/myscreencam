import Foundation

/// A one-shot signal awaited with a timeout (used for "the first screen frame arrived").
final class FirstFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<Void, any Error>?

    func open() { settle(nil) }

    func fail(_ error: any Error) { settle(error) }

    /// Returns once opened, or throws `timeoutError` after `timeout` seconds (or the error passed to ``fail(_:)``).
    func wait(timeout: Double, timeoutError: any Error) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let settled: Result<Void, any Error>? = lock.withLock {
                if isOpen { return .success(()) }
                if let failure { return .failure(failure) }
                self.continuation = continuation
                return nil
            }
            if let settled {
                continuation.resume(with: settled)
                return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [self] in
                fail(timeoutError)
            }
        }
    }

    private func settle(_ error: (any Error)?) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard !isOpen, failure == nil else { return nil }
            if let error { failure = error } else { isOpen = true }
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}
