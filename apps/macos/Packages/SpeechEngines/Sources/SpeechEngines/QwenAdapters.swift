import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import ProjectKit
import SpeechCore

/// Qwen3-ASR 1.7B (8-bit MLX) recognition, one bounded window per call.
///
/// Loaded with `Qwen3ASRModel.fromModelDirectory` from a runtime mirror of the verified snapshot (the loader
/// writes `tokenizer.json` beside the weights). Greedy decoding (temperature 0), no context prompt, and an explicit
/// token budget per window. The library's own long-audio chunking is bypassed (`chunkDuration` exceeds the
/// window), so this adapter owns the work units and can tell a finished window from a truncated one:
/// - `generationTokens >= budget` → ``WindowTermination/tokenBudgetExhausted``;
/// - a highly repetitive tail (the library's repetition backstop, which stops without saying so) →
///   ``WindowTermination/repetitionStop``.
final class QwenAdapter {
    private let model: Qwen3ASRModel

    private init(model: Qwen3ASRModel) {
        self.model = model
    }

    static func load(runtimeDirectory: URL) async throws -> QwenAdapter {
        QwenAdapter(model: try await Qwen3ASRModel.fromModelDirectory(runtimeDirectory))
    }

    /// Default generation budget: ~25 tokens per second of audio, at least 256.
    static func defaultBudget(seconds: Double) -> Int { max(256, Int(seconds * 25)) }

    func recognise(samples: PreparedSamples, window: WorkWindow, languageHint: String?, tokenBudget: Int?)
        -> RecognisedWindow
    {
        let started = Date()
        let sr = Int(PreparedAudio.sampleRate)
        let audio = samples.read(window.read, minimumCount: sr)
        let seconds = Double(window.read.count) / Double(sr)
        let budget = tokenBudget ?? Self.defaultBudget(seconds: seconds)
        let forced = languageHint.flatMap(LanguageCapabilities.qwenName(for:))
        let output = model.generate(
            audio: MLXArray(audio), maxTokens: budget, temperature: 0, language: forced,
            chunkDuration: Float(seconds) + 3600, minChunkDuration: 1)
        Memory.clearCache()
        let text = output.text
        var warnings: [String] = []
        // The library falls back to "English" when it can't parse a detected language; we can't tell that apart,
        // so an unforced "English" on text that is mostly non-Latin is flagged rather than trusted.
        var tag = output.language.flatMap { $0.split(separator: ",").first.map(String.init) }
            .flatMap(LanguageCapabilities.tag(forQwenName:))
        if forced == nil, tag == "en", Self.nonLatinFraction(text) > 0.5 {
            tag = nil
            warnings.append("language detection was inconclusive")
        }
        let termination: WindowTermination =
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                .silent
            } else if output.generationTokens >= budget {
                .tokenBudgetExhausted
            } else if Self.hasRepetitiveTail(text) {
                .repetitionStop
            } else {
                .complete
            }
        return RecognisedWindow(
            window: window, text: text, languageTag: forced.flatMap(LanguageCapabilities.tag(forQwenName:)) ?? tag,
            units: [], termination: termination, generatedTokens: output.generationTokens, tokenBudget: budget,
            warnings: warnings, processingSeconds: Date().timeIntervalSince(started))
    }

    static func nonLatinFraction(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        return Double(letters.filter { $0.value > 0x024F }.count) / Double(letters.count)
    }

    /// Mirrors the library's backstop (≤ 3 distinct tokens among the last 24): the last 8 words (or 16 CJK
    /// characters) have at most 2 distinct values.
    static func hasRepetitiveTail(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count >= 8, Set(words.suffix(8)).count <= 2 { return true }
        let cjk = text.filter { CueBuilder.isCJK($0) }
        if cjk.count >= 16, Set(cjk.suffix(16)).count <= 2 { return true }
        return false
    }
}

/// Qwen3-ForcedAligner 0.6B (8-bit MLX): word/character timing for recognised text, per window.
final class QwenAlignmentAdapter {
    /// The model card's limit on input length.
    static let maximumSeconds = 300.0
    private let model: Qwen3ForcedAlignerModel

    private init(model: Qwen3ForcedAlignerModel) {
        self.model = model
    }

    static func load(runtimeDirectory: URL) async throws -> QwenAlignmentAdapter {
        QwenAlignmentAdapter(model: try await Qwen3ForcedAlignerModel.fromModelDirectory(runtimeDirectory))
    }

    /// Item times are returned relative to `window.read.start` (the assembler adds the offset).
    func align(samples: PreparedSamples, window: WorkWindow, text: String, languageTag: String) throws -> AlignedWindow
    {
        let started = Date()
        let sr = Double(PreparedAudio.sampleRate)
        guard Double(window.read.count) / sr <= Self.maximumSeconds else { throw WorkerFailure.oversizedRequest }
        guard LanguageCapabilities.qwenAlignment.contains(languageTag),
            let language = LanguageCapabilities.qwenName(for: languageTag)
        else { throw WorkerFailure.badRequest }
        let audio = samples.read(window.read, minimumCount: Int(sr))
        let result = model.generate(audio: MLXArray(audio), text: text, language: language)
        Memory.clearCache()
        let items = result.items.map { item in
            AlignedItem(
                text: item.text, startSample: Int64((item.startTime * sr).rounded()),
                endSample: Int64((item.endTime * sr).rounded()))
        }
        return AlignedWindow(
            windowIndex: window.index, items: items, processingSeconds: Date().timeIntervalSince(started))
    }
}
