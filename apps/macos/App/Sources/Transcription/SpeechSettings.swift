import Foundation
import Observation
import SpeechCore

/// Subtitle/transcription preferences, persisted in `UserDefaults`. Nothing is downloaded until the user picks an
/// engine (the default is off).
@MainActor
@Observable
final class SpeechSettings {
    enum Key {
        static let engine = "speech.engine"
        static let language = "speech.language"
        static let autoTranscribe = "speech.autoTranscribe"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The engine used for new transcriptions, or nil when subtitles are off.
    var engine: SpeechEngine? {
        didSet { defaults.set(engine?.rawValue ?? "off", forKey: Key.engine) }
    }

    /// A canonical language tag, or nil for automatic detection.
    var language: String? {
        didSet { defaults.set(language ?? "auto", forKey: Key.language) }
    }

    /// Transcribe each new recording as soon as it's saved.
    var autoTranscribe: Bool {
        didSet { defaults.set(autoTranscribe, forKey: Key.autoTranscribe) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.engine: "off", Key.language: "auto", Key.autoTranscribe: true])
        engine = SpeechEngine(rawValue: defaults.string(forKey: Key.engine) ?? "off")
        let language = defaults.string(forKey: Key.language) ?? "auto"
        self.language = language == "auto" ? nil : language
        autoTranscribe = defaults.bool(forKey: Key.autoTranscribe)
    }

    /// The language hint for `engine`: the chosen language when that engine supports it, else automatic.
    func languageHint(for engine: SpeechEngine) -> String? {
        guard let language, LanguageCapabilities.canRecognise(language, engine: engine) else { return nil }
        return language
    }
}
