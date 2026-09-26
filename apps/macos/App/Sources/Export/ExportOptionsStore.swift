import ExportKit
import Foundation

/// The export dialog's remembered choices: the preset last picked and the settings as last adjusted.
struct ExportChoice: Codable, Equatable {
    /// The preset the settings started from; nil once the format no longer matches any preset's format.
    var preset: ExportPreset?
    var settings: ExportSettings

    static let `default` = ExportChoice(preset: .web, settings: ExportPreset.web.settings)

    /// True when the settings are exactly the preset's.
    var isUnmodifiedPreset: Bool { preset.map { $0.settings == settings } ?? false }

    mutating func apply(_ preset: ExportPreset) {
        self.preset = preset
        settings = preset.settings
    }

    /// Changes the format, keeping the other options and resetting the container to the format's default.
    mutating func setFormat(_ format: ExportFormat) {
        guard format != settings.format else { return }
        settings.format = format
        settings.container = format.defaultContainer
        if format == .gif {
            // GIF has its own caps: no audio, at most 30 fps, and a small frame (unless the preset says otherwise).
            settings.includesAudio = false
            if settings.frameRate == .fps60 { settings.frameRate = .fps30 }
            if (settings.maxLongEdge ?? .max) > 720 { settings.maxLongEdge = 720 }
            settings.maxShortEdge = nil
        } else {
            settings.includesAudio = true
            if settings.frameRate == .fps15 { settings.frameRate = .fps24 }
            if settings.maxLongEdge == 720 { settings.maxLongEdge = nil }
        }
        if let preset, preset.settings.format != format { self.preset = nil }
    }

    /// Frame rates offered for the current format.
    var frameRateChoices: [ExportFrameRate] {
        settings.format == .gif ? [.fps15, .fps24, .fps30] : ExportFrameRate.videoRates
    }
}

/// Persists the dialog's choice in `UserDefaults` as JSON.
enum ExportOptionsStore {
    static let key = "export.lastChoice"
    static let directoryKey = "export.lastDirectory"

    static func load(from defaults: UserDefaults = .standard) -> ExportChoice {
        guard let data = defaults.data(forKey: key),
            let choice = try? JSONDecoder().decode(ExportChoice.self, from: data),
            (try? choice.settings.validate()) != nil
        else { return .default }
        return choice
    }

    static func save(_ choice: ExportChoice, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: key)
    }

    /// The folder of the last export, if it still exists.
    static func lastDirectory(from defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: directoryKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    static func rememberDirectory(of url: URL, in defaults: UserDefaults = .standard) {
        defaults.set(url.deletingLastPathComponent().path, forKey: directoryKey)
    }
}
