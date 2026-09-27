import Foundation
import ProjectKit

/// Turns worker window results into a canonical ``TranscriptRevision`` on the session timeline.
///
/// - Offsets are added exactly once, here: unit sample positions are absolute in the prepared file, and
///   ``PreparedAudio/sourceTime(sample:)`` maps them to session time.
/// - Ownership: a word belongs to the window that owns its **start** (Parakeet reads a little context either side);
///   seams are then reconciled by timing (``resolvedUnits(_:prepared:warnings:)``): competing hypotheses for the
///   same moment keep one copy, and a word only the neighbour heard isn't lost. Repeated words at different times
///   are never merged. Units starting beyond the valid samples (model padding) are dropped, never clamped into
///   existence.
/// - A window that ended on its token budget or a repetition guard is excluded from coverage and makes the revision
///   `partial`; its text is still kept, flagged.
public enum TranscriptAssembler {
    public struct Input: Sendable {
        public var revisionID: String
        public var parentRevisionID: String?
        public var prepared: PreparedAudio
        public var sourceDuration: Double
        public var engine: SpeechEngine
        public var recogniser: ModelIdentity
        public var aligner: ModelIdentity?
        public var implementation: [String: String]
        public var options: TranscriptionOptions
        public var windows: [RecognisedWindow]
        /// Alignment results by window index (Qwen).
        public var alignments: [Int: AlignedWindow]

        public init(
            revisionID: String, parentRevisionID: String?, prepared: PreparedAudio, sourceDuration: Double,
            engine: SpeechEngine, recogniser: ModelIdentity, aligner: ModelIdentity?, implementation: [String: String],
            options: TranscriptionOptions, windows: [RecognisedWindow], alignments: [Int: AlignedWindow]
        ) {
            self.revisionID = revisionID
            self.parentRevisionID = parentRevisionID
            self.prepared = prepared
            self.sourceDuration = sourceDuration
            self.engine = engine
            self.recogniser = recogniser
            self.aligner = aligner
            self.implementation = implementation
            self.options = options
            self.windows = windows
            self.alignments = alignments
        }
    }

    public static func assemble(_ input: Input) throws -> TranscriptRevision {
        var segments: [TranscriptSegment] = []
        var coverage: [MediaRange] = []
        var warnings: [String] = []
        var partial = false
        let prepared = input.prepared

        // Retry windows receive new checkpoint indices, but still belong at their audio position.
        let ordered = input.windows.sorted {
            if $0.window.owned.start != $1.window.owned.start {
                return $0.window.owned.start < $1.window.owned.start
            }
            return $0.window.index < $1.window.index
        }
        let owned = resolvedUnits(ordered, prepared: prepared, warnings: &warnings)
        for (position, window) in ordered.enumerated() {
            let w = window.window
            switch window.termination {
            case .complete, .silent:
                coverage.append(prepared.sourceRange(w.owned))
            case .tokenBudgetExhausted:
                partial = true
                warnings.append("window \(w.index): generation hit its token budget; text may be truncated")
            case .repetitionStop:
                partial = true
                warnings.append("window \(w.index): generation stopped on a repetition guard; text may be truncated")
            }
            warnings += window.warnings.map { "window \(w.index): \($0)" }
            let text = window.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let segmentID = "\(input.revisionID.prefix(8))-s\(w.index)"
            if let alignment = input.alignments[w.index] {
                segments.append(
                    alignedSegment(
                        id: segmentID, window: window, alignment: alignment, prepared: prepared, warnings: &warnings))
            } else if window.units.contains(where: { $0.startSample != nil }) {
                if let segment = timedSegment(id: segmentID, window: window, kept: owned[position], prepared: prepared)
                {
                    segments.append(segment)
                }
            } else {
                segments.append(textOnlySegment(id: segmentID, window: window, prepared: prepared))
            }
        }

        let revision = TranscriptRevision(
            id: input.revisionID, parentRevisionID: input.parentRevisionID,
            sourceMediaID: prepared.sourceMediaID, audioIdentityHash: prepared.identity,
            recogniser: input.recogniser, aligner: input.aligner,
            implementationFingerprint: Fingerprint.of(input.implementation), implementation: input.implementation,
            optionsFingerprint: Fingerprint.of(input.options), options: input.options,
            sourceCoverage: mergeCoverage(coverage), segments: segments, status: partial ? .partial : .complete,
            warnings: warnings)
        try revision.validate(sourceDuration: input.sourceDuration)
        return revision
    }

    // MARK: Parakeet (TDT timing)

    /// A word with the punctuation units that follow it (they travel together across a seam).
    struct Group {
        var units: [RecognisedUnit]
        var start: Int64
    }

    static func groups(_ window: RecognisedWindow, valid: Int64) -> [Group] {
        var groups: [Group] = []
        for unit in window.units {
            guard let s = unit.startSample, unit.endSample != nil, s < valid else { continue }
            if unit.kind == .punctuation, !groups.isEmpty {
                groups[groups.count - 1].units.append(unit)
            } else {
                groups.append(Group(units: [unit], start: s))
            }
        }
        return groups
    }

    /// Each window's units after resolving its seams.
    ///
    /// At the cut between windows A and B (B's owned start): A keeps the words that start before it and B the
    /// words that start at or after it. Then, within the context each window reads across the cut, a word only the
    /// neighbour heard (no word of the owner starts within ``seamTolerance``) is added to the neighbour's side, and
    /// two estimates of the same moment on either side of the cut keep B's copy (A heard it cut off by its context
    /// edge). Repeated words at different times are never merged.
    static func resolvedUnits(_ windows: [RecognisedWindow], prepared: PreparedAudio, warnings: inout [String])
        -> [[RecognisedUnit]]
    {
        let valid = prepared.sampleCount
        let all = windows.map { groups($0, valid: valid) }
        let beyond = windows.reduce(0) { $0 + $1.units.filter { ($0.startSample ?? 0) >= valid }.count }
        if beyond > 0 { warnings.append("\(beyond) unit(s) beyond the end of the audio were dropped") }
        var kept: [[Group]] = windows.indices.map { i in
            all[i].filter { $0.start >= windows[i].window.owned.start && $0.start < windows[i].window.owned.end }
        }
        func text(_ group: Group, _ window: RecognisedWindow) -> String { normalised(window.text, group.units[0]) }
        /// The owner already has this word: a word starting at (nearly) the same time, or the same word within a
        /// second (a word heard cut off at a context edge gets poor timing).
        func owned(_ candidate: Group, from: RecognisedWindow, by groups: [Group], of owner: RecognisedWindow) -> Bool {
            let word = text(candidate, from)
            return groups.contains {
                abs($0.start - candidate.start) <= seamTolerance
                    || (abs($0.start - candidate.start) <= 16_000 && !word.isEmpty && text($0, owner) == word)
            }
        }
        /// Words starting this close to the edge of a window's audio were probably heard cut off.
        let edge: Int64 = 3_200
        for i in 0..<max(0, windows.count - 1) {
            let cut = windows[i + 1].window.owned.start
            // Same moment on both sides of the cut: keep the later window's copy.
            while let last = kept[i].last, let first = kept[i + 1].first, first.start - last.start <= seamTolerance,
                last.start >= cut - seamTolerance
            {
                kept[i].removeLast()
            }
            // Words only B heard just before the cut (A missed them).
            let lastA = kept[i].last?.start ?? Int64.min
            let missedByA = all[i + 1].filter {
                $0.start < cut && $0.start > lastA + seamTolerance
                    && $0.start >= windows[i + 1].window.read.start + edge
                    && !owned($0, from: windows[i + 1], by: all[i], of: windows[i])
            }
            kept[i + 1].insert(contentsOf: missedByA, at: 0)
            // Words only A heard just after the cut (B missed them).
            let firstB = kept[i + 1].first?.start ?? Int64.max
            let missedByB = all[i].filter {
                $0.start >= cut && $0.start < firstB - seamTolerance && $0.start < windows[i].window.read.end - edge
                    && !owned($0, from: windows[i], by: all[i + 1], of: windows[i + 1])
            }
            kept[i].append(contentsOf: missedByB)
        }
        return kept.map { $0.flatMap(\.units) }
    }

    /// Two estimates of the same word's start at a seam differ by at most this (samples; 0.3 s).
    static let seamTolerance: Int64 = 4_800

    static func normalised(_ text: String, _ unit: RecognisedUnit) -> String {
        let bytes = Array(text.utf8)
        guard unit.utf8Start >= 0, unit.utf8End <= bytes.count, unit.utf8Start < unit.utf8End,
            let word = String(bytes: bytes[unit.utf8Start..<unit.utf8End], encoding: .utf8)
        else { return "" }
        return word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func timedSegment(
        id: String, window: RecognisedWindow, kept: [RecognisedUnit], prepared: PreparedAudio
    ) -> TranscriptSegment? {
        let owned = window.window.owned
        let valid = prepared.sampleCount
        guard let first = kept.first, let last = kept.last else { return nil }
        // The segment's text is exactly the recogniser's bytes from the first to the last owned unit.
        let bytes = Array(window.text.utf8)
        let lo = first.utf8Start
        let hi = last.utf8End
        guard lo >= 0, hi <= bytes.count, lo < hi, let raw = String(bytes: bytes[lo..<hi], encoding: .utf8) else {
            return nil
        }
        let language = window.languageTag
        var units: [TranscriptUnit] = []
        for (i, unit) in kept.enumerated() {
            let s = unit.startSample!
            let e = min(max(unit.endSample!, s), valid)
            let validation: TimingValidation = unit.endEstimated ? .needsReview : .valid
            units.append(
                TranscriptUnit(
                    id: "\(id)-u\(i)", utf8Start: unit.utf8Start - lo, utf8End: unit.utf8End - lo, kind: unit.kind,
                    timing: UnitTiming(
                        sourceRange: prepared.sourceRange(SampleRange(start: s, end: e)), method: unit.method ?? .tdt,
                        validation: validation),
                    languageTag: language, backendScore: unit.score,
                    warnings: unit.endEstimated ? ["end estimated from the next token"] : []))
        }
        let start = kept.compactMap(\.startSample).min() ?? owned.start
        let end = min(kept.compactMap(\.endSample).max() ?? owned.end, valid)
        return TranscriptSegment(
            id: id, sourceRange: prepared.sourceRange(SampleRange(start: start, end: max(start, end))),
            rangeMeaning: .speech, rawText: raw, languageTag: language, units: units)
    }

    // MARK: Qwen text-only

    static func textOnlySegment(id: String, window: RecognisedWindow, prepared: PreparedAudio) -> TranscriptSegment {
        let chinese = window.languageTag == "zh"
        let tokens = AlignmentMapper.tokens(window.text, chineseMode: chinese)
        let units = tokens.enumerated().map { i, token in
            TranscriptUnit(
                id: "\(id)-u\(i)", utf8Start: token.utf8Start, utf8End: token.utf8End,
                kind: token.isCJK ? .character : .word, timing: nil, languageTag: window.languageTag)
        }
        return TranscriptSegment(
            id: id, sourceRange: prepared.sourceRange(window.window.owned), rangeMeaning: .processingWindow,
            rawText: window.text, languageTag: window.languageTag, units: units)
    }

    // MARK: Qwen + forced alignment

    static func alignedSegment(
        id: String, window: RecognisedWindow, alignment: AlignedWindow, prepared: PreparedAudio,
        warnings: inout [String]
    ) -> TranscriptSegment {
        let chinese = window.languageTag == "zh"
        let mapped = AlignmentMapper.map(items: alignment.items, rawText: window.text, chineseMode: chinese)
        let owned = window.window.owned
        let valid = min(prepared.sampleCount, owned.end)
        if mapped.mismatched > 0 {
            warnings.append(
                "window \(window.window.index): \(mapped.mismatched) aligner item(s) didn't match the recognised text; "
                    + "those words have no timing")
        }
        var units: [TranscriptUnit] = []
        var outOfWindow = 0
        for (i, token) in mapped.tokens.enumerated() {
            var timing: UnitTiming?
            if let t = mapped.timings[i] {
                // Aligner times are relative to the window's audio.
                let s = window.window.read.start + t.start
                let e = window.window.read.start + t.end
                if s >= owned.start, s < valid {
                    let range = prepared.sourceRange(SampleRange(start: s, end: min(max(e, s), valid)))
                    timing = UnitTiming(
                        sourceRange: range, method: .forcedAlignment, validation: e > s ? .valid : .needsReview)
                } else {
                    outOfWindow += 1
                }
            }
            units.append(
                TranscriptUnit(
                    id: "\(id)-u\(i)", utf8Start: token.utf8Start, utf8End: token.utf8End,
                    kind: token.isCJK ? .character : .word, timing: timing, languageTag: window.languageTag))
        }
        if outOfWindow > 0 {
            warnings.append("window \(window.window.index): \(outOfWindow) aligned time(s) outside the window")
        }
        let timed = units.compactMap(\.timing?.sourceRange)
        let range: MediaRange
        let meaning: TranscriptSegment.RangeMeaning
        if let first = timed.first, let last = timed.last {
            range = MediaRange(start: first.start, end: max(last.end, first.start))
            meaning = .speech
        } else {
            range = prepared.sourceRange(owned)
            meaning = .processingWindow
        }
        return TranscriptSegment(
            id: id, sourceRange: range, rangeMeaning: meaning, rawText: window.text, languageTag: window.languageTag,
            units: units)
    }

    /// Sorts and merges touching/overlapping ranges.
    static func mergeCoverage(_ ranges: [MediaRange]) -> [MediaRange] {
        var merged: [MediaRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, !(last.end < range.start) {
                merged[merged.count - 1] = MediaRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
