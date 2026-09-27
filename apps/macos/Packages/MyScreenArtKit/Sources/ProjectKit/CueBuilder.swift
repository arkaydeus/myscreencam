import Foundation

/// Builds display cues from a transcript revision. Pure; raw recognition is never modified.
///
/// Timed units are grouped into cues of at most ``Rules/maxCharacters`` (CJK characters count double), at most
/// ``Rules/maxDuration`` seconds, breaking at pauses of ``Rules/pauseBreak`` or more and after sentence-final
/// punctuation. Units without timing join the cue they're in; they never create a boundary. Segments that only
/// know their processing window (plain Qwen recognition) become one coarse cue each: splitting them would invent
/// timing.
public enum CueBuilder {
    public struct Rules: Sendable, Equatable {
        /// Two lines of ~42.
        public var maxCharacters: Int = 84
        public var maxDuration: Double = 6
        public var pauseBreak: Double = 0.6
        /// A cue shorter than this isn't ended at a sentence break.
        public var minSentenceCue: Double = 1.0
        /// Short cues are held on screen up to this long, without overlapping the next one.
        public var minDisplay: Double = 0.8

        public init() {}
    }

    /// A unit with its segment-local text and (optional) source seconds.
    struct Item {
        let segmentIndex: Int
        let unit: TranscriptUnit
        let text: String
        /// Punctuation directly after the unit in the raw text (aligners don't return it as units).
        let trailing: String
        let start: Double?
        let end: Double?

        var endsClause: Bool { CueBuilder.isClauseEnd(text + trailing) }
        var endsSentence: Bool { CueBuilder.isSentenceEnd(text + trailing) }
    }

    public static func cues(
        from revision: TranscriptRevision, rules: Rules = Rules(), excludingUnits excluded: Set<String> = []
    ) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for segment in revision.segments where !segment.units.contains(where: { $0.timing != nil }) {
            let text = segment.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let unitIDs = segment.units.map(\.id)
            guard !text.isEmpty, !unitIDs.contains(where: excluded.contains) else { continue }
            cues.append(
                SubtitleCue(
                    start: segment.sourceRange.startSeconds, end: segment.sourceRange.endSeconds, text: text,
                    generatedText: text, unitIDs: unitIDs, coarse: true))
        }
        let items: [Item] = revision.segments.enumerated().flatMap { index, segment -> [Item] in
            guard segment.units.contains(where: { $0.timing != nil }) else { return [] }
            let bytes = Array(segment.rawText.utf8)
            return segment.units.enumerated().compactMap { i, unit in
                guard !excluded.contains(unit.id), let text = segment.text(of: unit) else { return nil }
                let limit = i + 1 < segment.units.count ? segment.units[i + 1].utf8Start : bytes.count
                return Item(
                    segmentIndex: index, unit: unit, text: text,
                    trailing: trailingPunctuation(bytes, from: unit.utf8End, limit: limit),
                    start: unit.timing?.sourceRange.startSeconds, end: unit.timing?.sourceRange.endSeconds)
            }
        }
        cues += group(items, revision: revision, rules: rules)
        cues.sort { $0.start < $1.start }
        return holdShortCues(cues, rules: rules)
    }

    static func group(_ items: [Item], revision: TranscriptRevision, rules: Rules) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: [Item] = []

        func emit(_ run: [Item]) {
            guard let first = run.first(where: { $0.start != nil }),
                let last = run.last(where: { $0.end != nil }), let start = first.start, let end = last.end,
                end > start
            else { return }
            let text = joinedText(run, revision: revision)
            guard !text.isEmpty else { return }
            let words = SubtitleWords.build(text: text, units: run.map { ($0.text, $0.unit.timing) })
            cues.append(
                SubtitleCue(
                    start: start, end: end, text: text, generatedText: text, unitIDs: run.map(\.unit.id),
                    words: words))
        }

        for item in items {
            if let start = item.start, !current.isEmpty {
                let cueStart = current.first(where: { $0.start != nil })?.start ?? start
                let lastEnd = current.last(where: { $0.end != nil })?.end ?? start
                let pause = start - lastEnd >= rules.pauseBreak
                let sentence = (current.last?.endsSentence ?? false) && lastEnd - cueStart >= rules.minSentenceCue
                let overflow =
                    (item.end ?? start) - cueStart > rules.maxDuration
                    || weightedLength(joinedText(current + [item], revision: revision)) > rules.maxCharacters
                if pause || sentence {
                    emit(current)
                    current = []
                } else if overflow {
                    // Prefer to break after a clause (comma, sentence end) in the latter two thirds of the cue.
                    let floor = max(1, current.count / 3)
                    if let k = (floor..<current.count).last(where: { current[$0 - 1].endsClause }) {
                        emit(Array(current[..<k]))
                        current = Array(current[k...])
                    } else {
                        emit(current)
                        current = []
                    }
                }
            }
            current.append(item)
        }
        emit(current)
        return cues
    }

    /// The raw text spanned by `items`: within a segment the exact bytes between the first and last unit (so the
    /// recogniser's own spacing is kept); across segments joined with a space unless both sides are CJK.
    static func joinedText(_ items: [Item], revision: TranscriptRevision) -> String {
        var parts: [String] = []
        var i = 0
        while i < items.count {
            let segmentIndex = items[i].segmentIndex
            var j = i
            while j + 1 < items.count, items[j + 1].segmentIndex == segmentIndex { j += 1 }
            let bytes = Array(revision.segments[segmentIndex].rawText.utf8)
            let lo = items[i].unit.utf8Start
            let hi = items[j].unit.utf8End + items[j].trailing.utf8.count
            if lo >= 0, hi <= bytes.count, lo < hi, let s = String(bytes: bytes[lo..<hi], encoding: .utf8) {
                parts.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            i = j + 1
        }
        var result = ""
        for part in parts where !part.isEmpty {
            if let last = result.last, let first = part.first, !(isCJK(last) && isCJK(first)) {
                result += " "
            }
            result += part
        }
        return result
    }

    /// Characters, with CJK/kana/hangul counting double (they're about twice as wide).
    public static func weightedLength(_ text: String) -> Int {
        text.reduce(0) { $0 + (isCJK($1) ? 2 : 1) }
    }

    static func isClauseEnd(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!。？！…,;:，、；：".contains(last)
    }

    /// Non-space, non-letter/digit characters right after `from`, stopping at whitespace or `limit`.
    static func trailingPunctuation(_ bytes: [UInt8], from: Int, limit: Int) -> String {
        guard from >= 0, from < min(limit, bytes.count),
            let tail = String(bytes: bytes[from..<min(limit, bytes.count)], encoding: .utf8)
        else { return "" }
        return String(tail.prefix { !$0.isWhitespace && !$0.isLetter && !$0.isNumber })
    }

    static func isSentenceEnd(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!。？！…".contains(last)
    }

    public static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3040...0x30FF).contains(v)
            || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x20000...0x2CEAF).contains(v)
            || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// Extends cues shorter than `minDisplay` into the following gap (display only; unit timings are untouched).
    static func holdShortCues(_ cues: [SubtitleCue], rules: Rules) -> [SubtitleCue] {
        var cues = cues
        for i in cues.indices where cues[i].duration < rules.minDisplay {
            let limit = i + 1 < cues.count ? cues[i + 1].start : cues[i].start + rules.minDisplay
            cues[i].end = max(cues[i].end, min(cues[i].start + rules.minDisplay, limit))
        }
        return cues
    }
}
