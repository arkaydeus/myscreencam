import Foundation

/// A language as the app knows it: a canonical BCP-47 tag plus the names each SDK expects at its boundary.
public struct SpeechLanguage: Codable, Sendable, Hashable, Identifiable {
    /// Canonical tag (`en`, `zh`, `yue`, …).
    public var tag: String
    /// English name, which is also Qwen's name for it.
    public var name: String

    public var id: String { tag }

    public init(tag: String, name: String) {
        self.tag = tag
        self.name = name
    }

    /// Localised display name.
    public var displayName: String { Locale.current.localizedString(forLanguageCode: tag) ?? name }
}

/// Capabilities built from the reviewed model metadata (model cards and the pinned configs), kept separate per
/// operation: recognising a language, accepting it as a hint, and producing fine (word) timing for it.
public enum LanguageCapabilities {
    /// Parakeet Ultra (v3 family): 25 European languages. Recognition detects the language itself; the hint
    /// only filters tokens by script.
    public static let parakeet: [SpeechLanguage] = [
        ("bg", "Bulgarian"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"),
        ("en", "English"), ("et", "Estonian"), ("fi", "Finnish"), ("fr", "French"), ("de", "German"),
        ("el", "Greek"), ("hu", "Hungarian"), ("it", "Italian"), ("lv", "Latvian"), ("lt", "Lithuanian"),
        ("mt", "Maltese"), ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"), ("sk", "Slovak"),
        ("sl", "Slovenian"), ("es", "Spanish"), ("sv", "Swedish"), ("ru", "Russian"), ("uk", "Ukrainian"),
    ].map { SpeechLanguage(tag: $0.0, name: $0.1) }

    /// Qwen3-ASR `support_languages` (pinned config.json): 30 languages.
    public static let qwen: [SpeechLanguage] = [
        ("zh", "Chinese"), ("en", "English"), ("yue", "Cantonese"), ("ar", "Arabic"), ("de", "German"),
        ("fr", "French"), ("es", "Spanish"), ("pt", "Portuguese"), ("id", "Indonesian"), ("it", "Italian"),
        ("ko", "Korean"), ("ru", "Russian"), ("th", "Thai"), ("vi", "Vietnamese"), ("ja", "Japanese"),
        ("tr", "Turkish"), ("hi", "Hindi"), ("ms", "Malay"), ("nl", "Dutch"), ("sv", "Swedish"), ("da", "Danish"),
        ("fi", "Finnish"), ("pl", "Polish"), ("cs", "Czech"), ("fil", "Filipino"), ("fa", "Persian"),
        ("el", "Greek"), ("ro", "Romanian"), ("hu", "Hungarian"), ("mk", "Macedonian"),
    ].map { SpeechLanguage(tag: $0.0, name: $0.1) }

    /// Languages the Qwen forced aligner can time **in this app**. The model supports 11 (its config lists
    /// Japanese and Korean too), but MLX Audio Swift's aligner splits Japanese and Korean words with a space
    /// tokenizer, which the upstream code notes is wrong for them, so we don't claim fine timing there.
    public static let qwenAlignment: Set<String> = ["zh", "yue", "en", "de", "es", "fr", "it", "pt", "ru"]

    public static func languages(for engine: SpeechEngine) -> [SpeechLanguage] {
        switch engine {
        case .parakeet: parakeet
        case .qwen: qwen
        }
    }

    public static func canRecognise(_ tag: String, engine: SpeechEngine) -> Bool {
        languages(for: engine).contains { $0.tag == tag }
    }

    /// Whether `engine` produces word timing for `tag`. Nil tag (unknown/mixed) → false for Qwen: alignment must
    /// not silently default to English.
    public static func hasFineTiming(_ tag: String?, engine: SpeechEngine) -> Bool {
        switch engine {
        case .parakeet: true
        case .qwen: tag.map { qwenAlignment.contains($0) } ?? false
        }
    }

    /// Canonical tag for a Qwen language name (`"English"` → `en`); nil when unknown.
    public static func tag(forQwenName name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return qwen.first { $0.name.lowercased() == n }?.tag
    }

    public static func qwenName(for tag: String) -> String? { qwen.first { $0.tag == tag }?.name }
}
