import Dispatch
import Foundation

/// Watches one directory's vnode (a `DispatchSource` file-system object; no polling) and reports changes.
///
/// Fires when entries are added, removed or renamed directly inside the directory (`write`), or when the directory
/// itself is renamed or deleted. Changes *inside* child folders (e.g. a package's `meta.json`) don't fire.
public enum DirectoryWatcher {
    /// An `AsyncStream` that yields once per burst of changes, after `debounce` of quiet.
    ///
    /// The stream finishes (after a final yield) if the directory is deleted or renamed, since the watch then
    /// refers to the old folder; it also finishes immediately if the directory can't be opened. The watch is
    /// cancelled when the consumer stops iterating.
    public static func changes(of directory: URL, debounce: Duration = .milliseconds(250)) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else {
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "ProjectKit.DirectoryWatcher", qos: .utility)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            let debouncer = Debouncer(queue: queue, delay: debounce) { continuation.yield() }

            source.setEventHandler { [weak source] in
                guard let source else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    debouncer.cancel()
                    continuation.yield()
                    continuation.finish()
                    source.cancel()
                } else {
                    debouncer.trigger()
                }
            }
            source.setCancelHandler {
                debouncer.cancel()
                close(fd)
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}

/// Trailing-edge debounce on a serial queue. All state is touched only on `queue`.
private final class Debouncer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let delay: DispatchTimeInterval
    private let action: @Sendable () -> Void
    private var pending: DispatchWorkItem?

    init(queue: DispatchQueue, delay: Duration, action: @escaping @Sendable () -> Void) {
        self.queue = queue
        let (seconds, attoseconds) = delay.components
        self.delay = .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        self.action = action
    }

    /// Call on `queue`.
    func trigger() {
        pending?.cancel()
        let item = DispatchWorkItem(block: action)
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Call on `queue`.
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
