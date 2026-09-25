import Foundation
import MyScreenArtCore
import ProjectKit

/// Appends `events.jsonl` lines on a background queue, buffering in memory and writing in chunks
/// (every `flushThreshold` bytes, on ``flush()``, and at ``close()``) rather than a syscall per event.
final class EventLogWriter: @unchecked Sendable {
    static let flushThreshold = 32 * 1024

    let url: URL
    private let queue = DispatchQueue(label: "com.myscreenart.recording.events", qos: .utility)
    private let lock = NSLock()
    private var written = 0

    // Confined to `queue`.
    private var handle: FileHandle?
    private var buffer = Data()
    private var failure: String?

    /// Creates (or truncates) the file.
    init(url: URL, handle suppliedHandle: FileHandle? = nil) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RecordingError.packageFailed("Can't create \(url.lastPathComponent)")
        }
        handle = try suppliedHandle ?? FileHandle(forWritingTo: url)
        buffer.reserveCapacity(Self.flushThreshold * 2)
    }

    /// Events accepted so far.
    var count: Int { lock.withLock { written } }

    func append(_ event: InputEvent) {
        lock.withLock { written += 1 }
        queue.async { [self] in
            guard let line = try? InputEventLog.encodeLine(event) else { return }
            buffer.append(line)
            if buffer.count >= Self.flushThreshold { writeBuffer() }
        }
    }

    /// Writes buffered lines now (e.g. on pause).
    func flush() {
        queue.async { [self] in writeBuffer() }
    }

    /// Writes everything and closes the file.
    func close() async throws {
        let failure: String? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                writeBuffer()
                try? handle?.close()
                handle = nil
                continuation.resume(returning: self.failure)
            }
        }
        if let failure { throw RecordingError.packageFailed(failure) }
    }

    private func writeBuffer() {
        guard !buffer.isEmpty, let handle else { return }
        do {
            try handle.write(contentsOf: buffer)
        } catch {
            failure = failure ?? error.localizedDescription
            Log.app.error("events.jsonl write failed: \(error.localizedDescription, privacy: .public)")
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
