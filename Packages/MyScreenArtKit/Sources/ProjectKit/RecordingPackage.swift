import Foundation

/// File names inside a recording package folder.
public enum PackageLayout {
    public static let meta = "meta.json"
    public static let edit = "edit.json"
    public static let events = "events.jsonl"
    public static let cursorsDirectory = "cursors"
    public static let cursorIndex = "cursors/index.json"
    public static let screen = "screen.mov"
    public static let webcam = "webcam.mov"
    public static let systemAudio = "sysaudio.m4a"
    public static let microphone = "mic.m4a"
    public static let cacheDirectory = "cache"
    public static let thumbnail = "cache/thumbnail.heic"

    public static func waveformCache(for kind: StreamKind) -> String { "cache/waveform-\(kind.rawValue).bin" }

    /// `Recording_YYYYMMDD_HHMMSS_xxxxxxxx` (local time).
    public static func folderName(for date: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let suffix = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "Recording_\(formatter.string(from: date))_\(suffix)"
    }
}

/// A recording package on disk. Value type; all I/O is synchronous and should run off the main actor
/// for large files (events, waveforms).
public struct RecordingPackage: Sendable, Hashable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public enum PackageError: Error, Equatable {
        case missingMeta(URL)
        case unsupportedVersion(Int)
    }

    public func url(_ relativePath: String) -> URL { url.appending(path: relativePath) }
    public func url(for stream: StreamKind) -> URL { url(stream.fileName) }

    /// Creates a new empty package folder (with `cursors/` and `cache/`) under `root`.
    public static func create(in root: URL, date: Date = Date(), id: UUID = UUID()) throws -> RecordingPackage {
        let folder = root.appending(path: PackageLayout.folderName(for: date, id: id), directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(
            at: folder.appending(path: PackageLayout.cursorsDirectory), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: folder.appending(path: PackageLayout.cacheDirectory), withIntermediateDirectories: true)
        return RecordingPackage(url: folder)
    }

    public static func isPackage(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: PackageLayout.meta).path)
    }

    // MARK: meta

    public func loadMeta() throws -> RecordingMeta {
        let file = url(PackageLayout.meta)
        guard FileManager.default.fileExists(atPath: file.path) else { throw PackageError.missingMeta(url) }
        let meta = try JSONDecoder.iso8601.decode(RecordingMeta.self, from: Data(contentsOf: file))
        guard meta.version <= RecordingMeta.currentVersion else { throw PackageError.unsupportedVersion(meta.version) }
        return meta
    }

    public func saveMeta(_ meta: RecordingMeta) throws {
        try JSONEncoder.pretty.encode(meta).write(to: url(PackageLayout.meta), options: .atomic)
    }

    // MARK: edit

    /// The saved edit, or nil if the editor hasn't saved one yet.
    public func loadEdit() throws -> EditConfig? {
        let file = url(PackageLayout.edit)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder.iso8601.decode(EditConfig.self, from: Data(contentsOf: file))
    }

    /// Atomic write (temp file + rename), so a crash never leaves a half-written `edit.json`.
    public func saveEdit(_ edit: EditConfig) throws {
        try JSONEncoder.pretty.encode(edit).write(to: url(PackageLayout.edit), options: .atomic)
    }

    // MARK: events & cursors

    public func loadEvents() throws -> [InputEvent] {
        let file = url(PackageLayout.events)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return InputEventLog.decode(try Data(contentsOf: file, options: .mappedIfSafe))
    }

    public func loadCursorIndex() throws -> CursorIndex {
        let file = url(PackageLayout.cursorIndex)
        guard FileManager.default.fileExists(atPath: file.path) else { return CursorIndex() }
        return try JSONDecoder.iso8601.decode(CursorIndex.self, from: Data(contentsOf: file))
    }

    public func saveCursorIndex(_ index: CursorIndex) throws {
        try JSONEncoder.pretty.encode(index).write(to: url(PackageLayout.cursorIndex), options: .atomic)
    }

    /// Streams whose file exists.
    public func availableStreams() -> Set<StreamKind> {
        Set(StreamKind.allCases.filter { FileManager.default.fileExists(atPath: url(for: $0).path) })
    }
}
