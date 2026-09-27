import FluidAudio
import Foundation
import ProjectKit
import SpeechCore

/// Parakeet Ultra through FluidAudio (Core ML). Loaded only from a verified local directory with
/// `AsrModels.loadLocal(from:version: .ultra)`; `downloadAndLoad` is never called.
///
/// Each outer work unit (60–120 s) is transcribed with FluidAudio's own long-form path (its 15 s internal windows
/// and stitching), with a fresh decoder state. Token timings are seconds relative to the samples passed in; we
/// convert them once to absolute prepared-sample positions.
final class ParakeetAdapter: Sendable {
    private let manager: AsrManager

    private init(manager: AsrManager) {
        self.manager = manager
    }

    static func load(directory: URL) async throws -> ParakeetAdapter {
        let models = try AsrModels.loadLocal(from: directory, version: .ultra)
        // One decoding worker: the outer units are already sequential, and it keeps peak memory low.
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
        return ParakeetAdapter(manager: manager)
    }

    func recognise(samples: PreparedSamples, window: WorkWindow, languageHint: String?) async throws
        -> RecognisedWindow
    {
        let started = Date()
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(PreparedAudio.sampleRate))
        let audio = samples.read(window.read, minimumCount: minimum)
        var state = TdtDecoderState.make(decoderLayers: 2)
        let language = languageHint.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(audio, decoderState: &state, language: language)
        let (text, units, warnings) = Self.units(
            from: result.tokenTimings ?? [], expectedText: result.text, windowStart: window.read.start)
        return RecognisedWindow(
            window: window, text: text, languageTag: languageHint, units: units,
            termination: text.isEmpty ? .silent : .complete, warnings: warnings,
            processingSeconds: Date().timeIntervalSince(started))
    }

    /// Rebuilds the recogniser's text from its tokens, tracking byte offsets, and groups subword tokens into
    /// words (a token starting with a space begins a word; a token of punctuation only is its own unit).
    /// If the rebuilt text doesn't equal FluidAudio's `text`, the text is kept and the units dropped (with a
    /// warning) rather than attaching timings to the wrong bytes.
    static func units(from tokens: [TokenTiming], expectedText: String, windowStart: Int64)
        -> (String, [RecognisedUnit], [String])
    {
        let sr = Double(PreparedAudio.sampleRate)
        var joined = ""
        var pieces: [(start: Int, end: Int, timing: TokenTiming)] = []
        for token in tokens where !token.token.isEmpty && token.token != "<blank>" && token.token != "<pad>" {
            let start = joined.utf8.count
            joined += token.token
            pieces.append((start, joined.utf8.count, token))
        }
        let leading = joined.utf8.prefix { $0 == 0x20 }.count
        let text = joined.trimmingCharacters(in: .whitespaces)
        guard text == expectedText else {
            return (expectedText, [], ["token text didn't reproduce the transcript text; word timing unavailable"])
        }
        var units: [RecognisedUnit] = []
        func sample(_ seconds: Double) -> Int64 { windowStart + Int64((seconds * sr).rounded()) }
        for piece in pieces {
            let raw = piece.timing.token
            let startsWord = raw.hasPrefix(" ")
            let bodyStart = piece.start + raw.utf8.prefix { $0 == 0x20 }.count - leading
            let bodyEnd = piece.end - leading
            guard bodyEnd > bodyStart else { continue }
            let body = raw.trimmingCharacters(in: .whitespaces)
            let isPunctuation =
                !body.isEmpty && body.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            let s = sample(piece.timing.startTime)
            let e = sample(piece.timing.endTime)
            if !startsWord, !isPunctuation, var last = units.last, last.kind == .word {
                // Continuation subword: extend the current word.
                last.utf8End = bodyEnd
                last.endSample = max(last.endSample ?? e, e)
                last.score = min(last.score ?? 1, Double(piece.timing.confidence))
                units[units.count - 1] = last
            } else {
                units.append(
                    RecognisedUnit(
                        utf8Start: bodyStart, utf8End: bodyEnd, kind: isPunctuation ? .punctuation : .word,
                        startSample: s, endSample: max(e, s), method: .tdt, endEstimated: false,
                        score: Double(piece.timing.confidence)))
            }
        }
        return (text, units, [])
    }
}
