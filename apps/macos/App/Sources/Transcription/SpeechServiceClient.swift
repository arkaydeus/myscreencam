import Foundation
import MyScreenArtCore
import SpeechCore

/// Talks to the `MyScreenArtSpeech` XPC service.
///
/// - The service is launched on the first request and exits when the connection is invalidated, so
///   ``release()`` returns every byte of model memory to the system.
/// - Cancelling the calling task invalidates the connection: the service exits mid-inference and the call throws
///   ``TranscriptionError/cancelled``; nothing in flight is committed.
/// - If the service is relaunched (after a release, a crash or a memory-pressure recycle) the last `load` is
///   replayed before the next request, so callers don't need to know.
nonisolated final class SpeechServiceClient: SpeechWorker, @unchecked Sendable {
    static let serviceName =
        (Bundle.main.bundleIdentifier ?? "com.myscreenart.app") + SpeechServiceIdentity.bundleSuffix

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var loadedRequest: WorkerRequest?

    func send(_ request: WorkerRequest) async throws -> WorkerResponse {
        let (connection, fresh) = currentConnection()
        if fresh, let load = lock.withLock({ loadedRequest }), !Self.isLifecycle(request) {
            _ = try await perform(load, on: connection)
        }
        let response = try await perform(request, on: connection)
        lock.withLock {
            switch request {
            case .load: if case .loaded = response { loadedRequest = request }
            case .unload, .shutdown: loadedRequest = nil
            default: break
            }
        }
        return response
    }

    /// Ends the service process (and its memory). The next request relaunches it.
    func release() {
        let old = lock.withLock { () -> NSXPCConnection? in
            defer { connection = nil }
            return connection
        }
        old?.invalidate()
    }

    /// Also forgets the loaded model (a fresh job must load its own).
    func reset() {
        lock.withLock { loadedRequest = nil }
        release()
    }

    private static func isLifecycle(_ request: WorkerRequest) -> Bool {
        switch request {
        case .load, .unload, .shutdown, .handshake: true
        default: false
        }
    }

    private func currentConnection() -> (NSXPCConnection, Bool) {
        lock.withLock {
            if let connection { return (connection, false) }
            let connection = NSXPCConnection(serviceName: Self.serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: SpeechServiceProtocol.self)
            connection.invalidationHandler = { [weak self] in self?.connectionEnded(connection) }
            connection.interruptionHandler = { [weak self] in
                Log.app.error("Speech service interrupted")
                self?.connectionEnded(connection)
                connection.invalidate()
            }
            connection.resume()
            self.connection = connection
            return (connection, true)
        }
    }

    private func connectionEnded(_ ended: NSXPCConnection) {
        lock.withLock { if connection === ended { connection = nil } }
    }

    private func perform(_ request: WorkerRequest, on xpc: NSXPCConnection) async throws -> WorkerResponse {
        let data = try WorkerCoding.encode(request)
        let once = OnceFlag()
        // NSXPCConnection is thread-safe; it isn't annotated Sendable.
        nonisolated(unsafe) let connection = xpc
        let reply: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    if once.claim() { continuation.resume(throwing: TranscriptionError.workerCrashed) }
                }
                guard let service = proxy as? SpeechServiceProtocol else {
                    if once.claim() { continuation.resume(throwing: TranscriptionError.workerCrashed) }
                    return
                }
                service.perform(data) { reply in
                    if once.claim() { continuation.resume(returning: reply) }
                }
            }
        } onCancel: {
            // Stops the in-flight inference by ending the service process.
            connection.invalidate()
        }
        if Task.isCancelled { throw TranscriptionError.cancelled }
        return try WorkerCoding.decode(WorkerResponse.self, from: reply)
    }
}

/// True for the first caller only.
nonisolated private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
