import Foundation
import MyScreenCamCore

/// One recording shown in the library.
public struct LibraryItem: Sendable, Equatable, Identifiable {
    public var package: RecordingPackage
    public var meta: RecordingMeta
    /// Streams whose file exists in the package.
    public var streams: Set<StreamKind>
    /// The cached thumbnail, if one has been generated (see ``ThumbnailGenerator``). The library never opens the
    /// video; call ``ThumbnailGenerator/thumbnail(for:)`` for items where this is nil.
    public var thumbnailURL: URL?

    public init(package: RecordingPackage, meta: RecordingMeta, streams: Set<StreamKind>, thumbnailURL: URL?) {
        self.package = package
        self.meta = meta
        self.streams = streams
        self.thumbnailURL = thumbnailURL
    }

    /// The package folder URL (stable across renames).
    public var id: URL { package.url }
}

/// A recording package that couldn't be loaded. The scan skips it instead of failing.
public struct LibraryFailure: Error, Sendable, Equatable, Identifiable {
    public var url: URL
    /// Human-readable reason (for logs / a "damaged recordings" UI).
    public var reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }

    public var id: URL { url }
}

/// Result of ``RecordingLibrary/scan()``.
public struct LibraryScan: Sendable, Equatable {
    /// Loaded recordings, newest first.
    public var items: [LibraryItem]
    /// Broken packages (missing/corrupt/unsupported `meta.json`), sorted by path.
    public var failures: [LibraryFailure]

    public init(items: [LibraryItem] = [], failures: [LibraryFailure] = []) {
        self.items = items
        self.failures = failures
    }
}

/// The recordings folder: lists packages, watches for changes, renames and deletes recordings.
public struct RecordingLibrary: Sendable {
    public typealias Trasher = @Sendable (URL) throws -> Void

    public enum LibraryError: Error, Sendable, Equatable {
        /// The new name is empty after trimming whitespace.
        case emptyName
        /// The URL isn't a supported recording package; refused so nothing else is ever trashed.
        case notAPackage(URL)
    }

    public let root: URL
    private let trasher: Trasher

    /// - Parameters:
    ///   - root: the recordings folder (e.g. `RecordingsLocation.prepare(...)`).
    ///   - trasher: moves a package to the Trash; defaults to `FileManager.trashItem`. Injectable for tests.
    public init(root: URL, trasher: Trasher? = nil) {
        self.root = root
        self.trasher = trasher ?? { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    /// Loads every `.mscam` or `.msarec` package directly inside ``root`` (metas are read concurrently). A missing root
    /// yields an empty scan.
    /// - Throws: only when the root exists but can't be listed.
    public func scan() async throws -> LibraryScan {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LibraryScan()
        }
        // Rebuild child URLs from `root` so they match URLs made with `RecordingPackage.create(in: root)` (the
        // listing may resolve symlinks, e.g. /var → /private/var).
        let candidates =
            urls
            .filter { PackageLayout.supportsExtension($0.pathExtension) }
            .map { root.appending(path: $0.lastPathComponent, directoryHint: .isDirectory) }

        let outcomes = await withTaskGroup(of: Result<LibraryItem, LibraryFailure>.self) { group in
            for url in candidates {
                group.addTask { Self.load(url) }
            }
            var results: [Result<LibraryItem, LibraryFailure>] = []
            for await outcome in group { results.append(outcome) }
            return results
        }

        var scan = LibraryScan()
        for outcome in outcomes {
            switch outcome {
            case .success(let item): scan.items.append(item)
            case .failure(let failure): scan.failures.append(failure)
            }
        }
        scan.items.sort {
            ($0.meta.createdAt, $1.package.url.path) > ($1.meta.createdAt, $0.package.url.path)
        }
        scan.failures.sort { $0.url.path < $1.url.path }
        for failure in scan.failures {
            Log.app.error(
                "Skipping broken recording \(failure.url.lastPathComponent, privacy: .public): \(failure.reason)")
        }
        return scan
    }

    /// Loads one package as a library item.
    public static func loadItem(at url: URL) throws -> LibraryItem {
        let package = RecordingPackage(url: url)
        let meta = try package.loadMeta()
        return LibraryItem(
            package: package, meta: meta, streams: package.availableStreams(),
            thumbnailURL: ThumbnailGenerator.cachedThumbnailURL(for: package))
    }

    private static func load(_ url: URL) -> Result<LibraryItem, LibraryFailure> {
        do {
            return .success(try loadItem(at: url))
        } catch {
            return .failure(LibraryFailure(url: url, reason: String(describing: error)))
        }
    }

    /// Yields (debounced by ~250 ms) whenever packages are added, removed or renamed in ``root``; rescan then.
    /// Edits inside a package (e.g. ``rename(_:to:)``) don't fire; update the item from the returned meta.
    public func changes(debounce: Duration = .milliseconds(250)) -> AsyncStream<Void> {
        DirectoryWatcher.changes(of: root, debounce: debounce)
    }

    /// Sets the recording's display name (`meta.name`). The folder isn't renamed, so URLs stay valid.
    /// - Returns: the updated meta.
    @discardableResult
    public func rename(_ package: RecordingPackage, to name: String) throws -> RecordingMeta {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.emptyName }
        var meta = try package.loadMeta()
        guard meta.name != name else { return meta }
        meta.name = name
        try package.saveMeta(meta)
        return meta
    }

    /// Renames a library item; returns the item with the new meta.
    public func rename(_ item: LibraryItem, to name: String) throws -> LibraryItem {
        var item = item
        item.meta = try rename(item.package, to: name)
        return item
    }

    /// Moves the package to the Trash (reversible from Finder).
    public func delete(_ package: RecordingPackage) throws {
        guard PackageLayout.supportsExtension(package.url.pathExtension) else {
            throw LibraryError.notAPackage(package.url)
        }
        try trasher(package.url)
    }
}
