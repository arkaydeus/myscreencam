import Foundation
import Testing

@testable import ProjectKit

struct RecordingLibraryTests {
    @Test func scanLoadsGoodAndCollectsBrokenPackages() async throws {
        let dir = try TempDirectory()
        let old = try Fixtures.package(
            in: dir.url, meta: Fixtures.meta(name: "Old", createdAt: Date(timeIntervalSince1970: 1_000)))
        let new = try Fixtures.package(
            in: dir.url, meta: Fixtures.meta(name: "New", createdAt: Date(timeIntervalSince1970: 3_000)))
        let middle = try Fixtures.package(
            in: dir.url, meta: Fixtures.meta(name: "Middle", createdAt: Date(timeIntervalSince1970: 2_000)))
        try Data().write(to: middle.url(for: .screen))
        try Data().write(to: middle.url(for: .microphone))
        try Data().write(to: middle.url(PackageLayout.thumbnail))

        // Broken: corrupt meta, meta from the future, no meta at all.
        let corrupt = try RecordingPackage.create(in: dir.url, date: Date(), id: UUID())
        try Data("{".utf8).write(to: corrupt.url(PackageLayout.meta))
        let future = try RecordingPackage.create(in: dir.url, date: Date(), id: UUID())
        var futureMeta = Fixtures.meta()
        futureMeta.version = 99
        try future.saveMeta(futureMeta)
        let empty = try RecordingPackage.create(in: dir.url, date: Date(), id: UUID())

        // Ignored: not packages / not direct children.
        try FileManager.default.createDirectory(
            at: dir.url.appending(path: "Other folder"), withIntermediateDirectories: true)
        try Data().write(to: dir.url.appending(path: "notes.txt"))
        _ = try Fixtures.package(in: dir.url.appending(path: "Other folder"), meta: Fixtures.meta(name: "Nested"))

        let scan = try await RecordingLibrary(root: dir.url).scan()
        #expect(scan.items.map(\.meta.name) == ["New", "Middle", "Old"])
        #expect(scan.items.map(\.package) == [new, middle, old])
        #expect(scan.items[1].streams == [.screen, .microphone])
        #expect(scan.items[1].thumbnailURL == middle.url(PackageLayout.thumbnail))
        #expect(scan.items[0].thumbnailURL == nil)
        #expect(scan.items[0].streams.isEmpty)
        #expect(Set(scan.failures.map(\.url)) == [corrupt.url, future.url, empty.url])
        #expect(scan.failures.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func missingRootIsEmpty() async throws {
        let dir = try TempDirectory()
        let scan = try await RecordingLibrary(root: dir.url.appending(path: "missing")).scan()
        #expect(scan == LibraryScan())
    }

    @Test func renameUpdatesMetaNameOnly() throws {
        let dir = try TempDirectory()
        let meta = Fixtures.meta(name: "Before")
        let package = try Fixtures.package(in: dir.url, meta: meta)
        let library = RecordingLibrary(root: dir.url)

        let renamed = try library.rename(package, to: "  After  ")
        #expect(renamed.name == "After")
        var expected = meta
        expected.name = "After"
        #expect(try package.loadMeta() == expected)
        #expect(FileManager.default.fileExists(atPath: package.url.path))  // folder unchanged

        let item = try RecordingLibrary.loadItem(at: package.url)
        #expect(try library.rename(item, to: "Third").meta.name == "Third")
        #expect(throws: RecordingLibrary.LibraryError.emptyName) { try library.rename(package, to: " \n") }
        #expect(try package.loadMeta().name == "Third")
    }

    @Test func deleteMovesPackageToTrash() throws {
        let dir = try TempDirectory()
        let package = try Fixtures.package(in: dir.url, meta: Fixtures.meta())
        let trashed = Locked<[URL]>([])
        let library = RecordingLibrary(root: dir.url) { url in trashed.withLock { $0.append(url) } }

        try library.delete(package)
        #expect(trashed.withLock { $0 } == [package.url])

        let notPackage = RecordingPackage(url: dir.url.appending(path: "Documents"))
        #expect(throws: RecordingLibrary.LibraryError.notAPackage(notPackage.url)) { try library.delete(notPackage) }
        #expect(trashed.withLock { $0.count } == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func watcherReportsDebouncedChanges() async throws {
        let dir = try TempDirectory()
        let library = RecordingLibrary(root: dir.url)
        let counter = Counter()
        let stream = library.changes(debounce: .milliseconds(100))
        let consumer = Task {
            for await _ in stream { await counter.increment() }
        }
        defer { consumer.cancel() }
        try await Task.sleep(for: .milliseconds(50))

        // A burst of changes → one event.
        for _ in 0..<5 {
            _ = try Fixtures.package(in: dir.url, meta: Fixtures.meta())
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(await counter.value == 1)

        // Removing a package → another event.
        let scan = try await library.scan()
        try FileManager.default.removeItem(at: scan.items[0].package.url)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await counter.value == 2)

        // Writing inside a package doesn't fire.
        _ = try library.rename(scan.items[1].package, to: "Renamed")
        try await Task.sleep(for: .milliseconds(400))
        #expect(await counter.value == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func watcherFinishesWhenRootIsDeleted() async throws {
        let dir = try TempDirectory()
        let root = dir.url.appending(path: "Recordings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let counter = Counter()
        let stream = DirectoryWatcher.changes(of: root)
        let consumer = Task {
            for await _ in stream { await counter.increment() }
        }
        try await Task.sleep(for: .milliseconds(50))
        try FileManager.default.removeItem(at: root)
        await consumer.value  // returns because the stream finished
        #expect(await counter.value >= 1)
    }

    @Test func watcherOnMissingDirectoryFinishesImmediately() async {
        let stream = DirectoryWatcher.changes(of: URL(filePath: "/nonexistent/\(UUID().uuidString)"))
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }
}
