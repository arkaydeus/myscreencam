import Foundation

/// A named set of look-and-feel settings: webcam, audio, cursor, zoom defaults and background.
/// Presets never carry per-recording content (segments, zoom keyframes, blur masks, zoom on/off).
public struct EditPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var webcam: WebcamSettings
    public var audio: AudioSettings
    public var cursor: CursorSettings
    public var zoomDefaults: ZoomTiming
    public var background: BackgroundSettings

    public init(
        id: UUID = UUID(), name: String, webcam: WebcamSettings = WebcamSettings(),
        audio: AudioSettings = AudioSettings(), cursor: CursorSettings = CursorSettings(),
        zoomDefaults: ZoomTiming = ZoomTiming(), background: BackgroundSettings = BackgroundSettings()
    ) {
        self.id = id
        self.name = name
        self.webcam = webcam
        self.audio = audio
        self.cursor = cursor
        self.zoomDefaults = zoomDefaults
        self.background = background
    }

    /// Captures the preset-able settings of `config`.
    public init(id: UUID = UUID(), name: String, from config: EditConfig) {
        self.init(
            id: id, name: name, webcam: config.webcam, audio: config.audio, cursor: config.cursor,
            zoomDefaults: config.zoom.defaults, background: config.background)
    }

    /// `config` with this preset's settings; segments, zoom keyframes, zoom on/off and blur masks are kept.
    public func applied(to config: EditConfig) -> EditConfig {
        var config = config
        config.webcam = webcam
        config.audio = audio
        config.cursor = cursor
        config.zoom.defaults = zoomDefaults
        config.background = background
        return config
    }
}

/// Persists presets as JSON (`presets.json`) in a directory, by default
/// `~/Library/Application Support/<bundle id>/`. Missing file = no presets. A corrupt file is reported, never
/// overwritten.
public actor PresetStore {
    public static let fileName = "presets.json"

    public enum StoreError: Error, Sendable, Equatable {
        /// The preset name is empty after trimming whitespace.
        case emptyName
        /// `presets.json` was written by a newer version.
        case unsupportedVersion(Int)
    }

    private struct File: Codable {
        static let currentVersion = 1
        var version: Int
        var presets: [EditPreset]
    }

    public nonisolated let fileURL: URL

    /// - Parameter directory: folder that holds `presets.json` (created on first save).
    public init(directory: URL) {
        fileURL = directory.appending(path: Self.fileName)
    }

    /// `~/Library/Application Support/<bundleIdentifier>/`.
    public static func defaultDirectory(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.myscreenart.app"
    )
        -> URL
    {
        URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
    }

    /// All presets, sorted by name.
    public func list() throws -> [EditPreset] {
        try load().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves a preset. It replaces an existing preset with the same id or, failing that, the same name
    /// (compared case-insensitively, ignoring surrounding whitespace); a replaced preset keeps its id.
    /// - Returns: the stored preset (name trimmed, id possibly that of the replaced preset).
    @discardableResult
    public func save(_ preset: EditPreset) throws -> EditPreset {
        var preset = preset
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.name.isEmpty else { throw StoreError.emptyName }
        var presets = try load()
        if let index = presets.firstIndex(where: { $0.id == preset.id })
            ?? presets.firstIndex(where: { Self.sameName($0.name, preset.name) })
        {
            preset.id = presets[index].id
            presets[index] = preset
            // A rename onto another preset's name replaces that one too.
            presets.removeAll { $0.id != preset.id && Self.sameName($0.name, preset.name) }
        } else {
            presets.append(preset)
        }
        try write(presets)
        return preset
    }

    /// Deletes the preset with `id` (no-op if absent).
    public func delete(id: EditPreset.ID) throws {
        var presets = try load()
        let before = presets.count
        presets.removeAll { $0.id == id }
        if presets.count != before { try write(presets) }
    }

    /// `config` with `preset` applied (see ``EditPreset/applied(to:)``).
    public nonisolated func apply(_ preset: EditPreset, to config: EditConfig) -> EditConfig {
        preset.applied(to: config)
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(b, options: [.caseInsensitive]) == .orderedSame
    }

    private func load() throws -> [EditPreset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL))
        guard file.version <= File.currentVersion else { throw StoreError.unsupportedVersion(file.version) }
        return file.presets
    }

    private func write(_ presets: [EditPreset]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(File(version: File.currentVersion, presets: presets))
        try data.write(to: fileURL, options: .atomic)
    }
}
