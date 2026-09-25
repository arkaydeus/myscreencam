import Foundation
import Synchronization
import Testing

@testable import ProjectKit

/// Records writes; can be told to fail.
final class WriteLog: Sendable {
    private let state = Mutex<(writes: [EditConfig], failing: Bool, errors: Int)>(([], false, 0))

    var writes: [EditConfig] { state.withLock { $0.writes } }
    var errorCount: Int { state.withLock { $0.errors } }

    func recordError() { state.withLock { $0.errors += 1 } }

    func setFailing(_ failing: Bool) { state.withLock { $0.failing = failing } }

    var writer: EditAutosaver.Writer {
        { config, _ in
            try self.state.withLock {
                if $0.failing { throw CocoaError(.fileWriteNoPermission) }
                $0.writes.append(config)
            }
        }
    }
}

struct EditAutosaverTests {
    let package = RecordingPackage(url: URL(filePath: "/nonexistent/test.msarec"))

    static let segmentID = UUID()

    func config(_ marker: Double) -> EditConfig {
        EditConfig(segments: [Segment(id: Self.segmentID, start: 0, end: marker)])
    }

    @Test func debouncesToLatest() async throws {
        let log = WriteLog()
        let saver = EditAutosaver(package: package, debounce: .milliseconds(50), writer: log.writer)
        for i in 1...5 {
            await saver.schedule(config(Double(i)))
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await saver.hasPendingChanges)
        #expect(log.writes.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.writes == [config(5)])
        #expect(await saver.hasPendingChanges == false)
        #expect(await saver.lastSaved == config(5))
    }

    @Test func flushWritesImmediatelyOnce() async throws {
        let log = WriteLog()
        let saver = EditAutosaver(package: package, debounce: .seconds(10), writer: log.writer)
        await saver.schedule(config(1))
        await saver.schedule(config(2))
        try await saver.flush()
        #expect(log.writes == [config(2)])
        #expect(await saver.hasPendingChanges == false)
        try await saver.flush()  // nothing pending: no write
        #expect(log.writes.count == 1)
    }

    @Test func failureKeepsSnapshotForRetry() async throws {
        let log = WriteLog()
        let saver = EditAutosaver(
            package: package, debounce: .milliseconds(20), writer: log.writer, onError: { _ in log.recordError() })
        log.setFailing(true)
        await saver.schedule(config(3))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await saver.hasPendingChanges)
        #expect(await saver.lastError != nil)
        #expect(log.errorCount == 1)
        await #expect(throws: CocoaError.self) { try await saver.flush() }

        log.setFailing(false)
        try await saver.flush()
        #expect(log.writes == [config(3)])
        #expect(await saver.hasPendingChanges == false)
        #expect(await saver.lastError == nil)
    }

    @Test func defaultWriterSavesEditJSON() async throws {
        let dir = try TempDirectory()
        let package = try Fixtures.package(in: dir.url, meta: Fixtures.meta())
        let saver = EditAutosaver(package: package)
        let edit = config(7)
        await saver.schedule(edit)
        try await saver.flush()
        #expect(try package.loadEdit() == edit)
    }
}
