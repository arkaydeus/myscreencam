import Foundation

/// File names inside a recording package folder.
public enum PackageLayout {
    public static let meta = "meta.json"
    public static let edit = "edit.json"
    public static let events = "events.jsonl"
    public static let cursorsDirectory = "cursors"
    public static let backgroundsDirectory = "backgrounds"
    public static let cursorIndex = "cursors/index.json"
    public static let screen = "screen.mov"
    public static let webcam = "webcam.mov"
    public static let systemAudio = "sysaudio.m4a"
    public static let microphone = "mic.m4a"
    public static let cacheDirectory = "cache"
    public static let thumbnail = "cache/thumbnail.heic"
    /// Immutable transcript revisions, `transcripts/<revision id>.json`.
    public static let transcriptsDirectory = "transcripts"
    /// Prepared audio and per-window checkpoints for transcription (derived; safe to delete).
    public static let transcriptionCacheDirectory = "cache/transcription"

    public static func transcript(id: String) -> String { "\(transcriptsDirectory)/\(id).json" }

    public static func waveformCache(for kind: StreamKind) -> String { "cache/waveform-\(kind.rawValue).bin" }

    /// Folder extension. Declared by the app as the `com.myscreenart.recording` package type (conforms to
    /// `com.apple.package`), so Finder shows a recording as one document and Quick Look can thumbnail it.
    public static let packageExtension = "msarec"
    public static let packageUTType = "com.myscreenart.recording"

    /// `Recording_YYYYMMDD_HHMMSS_xxxxxxxx.msarec` (local time).
    public static func folderName(for date: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let suffix = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "Recording_\(formatter.string(from: date))_\(suffix).\(packageExtension)"
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

    /// Resolves an untrusted path stored in package JSON. Symlinks cannot escape the package.
    public func containedURL(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
            !relativePath.split(separator: "/").contains("..")
        else { return nil }
        let base = url.resolvingSymlinksInPath().standardizedFileURL
        let candidate = url(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }

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

    /// A `.msarec` folder that contains `meta.json`.
    public static func isPackage(_ url: URL) -> Bool {
        url.pathExtension == PackageLayout.packageExtension
            && FileManager.default.fileExists(atPath: url.appending(path: PackageLayout.meta).path)
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

    /// The edit shown by the editor and used for a direct Library export.
    public func loadEffectiveEdit(meta: RecordingMeta, defaults: ProjectDefaults) throws -> EditConfig {
        if let saved = try loadEdit() { return saved.normalized(duration: meta.duration) }
        return try EditConfig.makeInitial(meta: meta, events: loadEvents(), defaults: defaults)
            .normalized(duration: meta.duration)
    }

    /// Fixes the first-use defaults for a direct Library export. An existing edit is never overwritten.
    public func loadOrCreateEdit(meta: RecordingMeta, defaults: ProjectDefaults) throws -> EditConfig {
        if let saved = try loadEdit() { return saved.normalized(duration: meta.duration) }
        let initial = try EditConfig.makeInitial(meta: meta, events: loadEvents(), defaults: defaults)
            .normalized(duration: meta.duration)
        try saveEdit(initial)
        return initial
    }

    /// Atomic write (temp file + rename), so a crash never leaves a half-written `edit.json`.
    public func saveEdit(_ edit: EditConfig) throws {
        try JSONEncoder.pretty.encode(edit).write(to: url(PackageLayout.edit), options: .atomic)
    }

    // MARK: transcripts

    /// A stored transcript revision, or nil when there's no such file. Ids are validated so a value from JSON can't
    /// name a path outside `transcripts/`.
    public func loadTranscript(id: String) throws -> TranscriptRevision? {
        guard Self.isSafeIdentifier(id) else { return nil }
        let file = url(PackageLayout.transcript(id: id))
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder.iso8601.decode(TranscriptRevision.self, from: Data(contentsOf: file))
    }

    /// Writes a revision atomically. Revisions are immutable: an existing file with the same id is left alone.
    public func saveTranscript(_ revision: TranscriptRevision) throws {
        guard Self.isSafeIdentifier(revision.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let directory = url(PackageLayout.transcriptsDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = url(PackageLayout.transcript(id: revision.id))
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try JSONEncoder.pretty.encode(revision).write(to: file, options: .atomic)
    }

    /// Letters, digits, `-` and `_` only.
    static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
            }
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
