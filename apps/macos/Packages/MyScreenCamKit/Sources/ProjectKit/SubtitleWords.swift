import Foundation

/// When one word of a cue is spoken (source seconds), for highlighting the current word.
public struct SubtitleWord: Codable, Sendable, Hashable {
    /// The word as recognised, with any punctuation attached to it.
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Word-level timing for subtitles: taken from the transcript units when cues are built, and matched back to the
/// cue's current (possibly corrected) text when drawing.
///
/// Text splits into **words**: runs of non-space characters, except that each CJK character is a word of its own
/// (punctuation stays with the word before it). Only acoustic timing (Parakeet TDT, Qwen forced alignment) gives a
/// word its time; coarse and manual timing never do, so approximate cues are never highlighted. Highlighting only
/// uses a word's start (a word stays lit until the next one starts), so an end estimated from the next token
/// (`needsReview`) doesn't matter.
public enum SubtitleWords {
    /// The words of `text` as UTF-16 offset ranges (Core Text's indexing).
    public static func tokens(in text: String) -> [Range<Int>] {
        var tokens: [Range<Int>] = []
        var start: Int?
        var offset = 0
        var previous: Character?
        for c in text {
            if c.isWhitespace {
                if let s = start { tokens.append(s..<offset) }
                start = nil
            } else if let s = start {
                if isCJKLetter(c) || (previous.map(CueBuilder.isCJK) == true && (c.isLetter || c.isNumber)) {
                    tokens.append(s..<offset)
                    start = offset
                }
            } else {
                start = offset
            }
            previous = c
            offset += c.utf16.count
        }
        if let s = start { tokens.append(s..<offset) }
        return tokens
    }

    /// Word timings for `text` from the units it was recognised as, in order. Each unit's text is found in `text`
    /// left to right; subword units share a display word, while a unit spanning multiple CJK display tokens
    /// distributes its acoustic interval across them.
    public static func build(text: String, units: [(text: String, timing: UnitTiming?)]) -> [SubtitleWord] {
        let utf16 = Array(text.utf16)
        let tokens = tokens(in: text)
        var spans: [Int: (start: Double, end: Double)] = [:]
        var cursor = text.startIndex
        for unit in units {
            let needle = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, let found = text.range(of: needle, range: cursor..<text.endIndex) else { continue }
            cursor = found.upperBound
            guard let timing = unit.timing, timing.method == .tdt || timing.method == .forcedAlignment else {
                continue
            }
            let match = found.lowerBound.utf16Offset(in: text)..<found.upperBound.utf16Offset(in: text)
            let overlapping = tokens.indices.filter { tokens[$0].overlaps(match) }
            guard !overlapping.isEmpty else { continue }
            let s = timing.sourceRange.startSeconds
            let e = timing.sourceRange.endSeconds
            for (index, k) in overlapping.enumerated() {
                let start = s + (e - s) * Double(index) / Double(overlapping.count)
                let end = s + (e - s) * Double(index + 1) / Double(overlapping.count)
                spans[k] = spans[k].map { (min($0.start, start), max($0.end, end)) } ?? (start, end)
            }
        }
        return spans.keys.sorted().map { k in
            SubtitleWord(
                text: String(decoding: utf16[tokens[k]], as: UTF16.self), start: spans[k]!.start, end: spans[k]!.end)
        }
    }

    /// The UTF-16 range in `text` of the current timed word at source time `t`. `words` are matched to the words
    /// of `text` in order by their letters and digits (a longest common subsequence), so a correction keeps the
    /// timing of every word it didn't change. A changed current word has no matching range and is never lit;
    /// the preceding word stays lit only during its own pause. Nil before the first word starts.
    public static func highlightedRange(in text: String, words: [SubtitleWord], at t: Double) -> Range<Int>? {
        progress(in: text, words: words, at: t)?.highlight
    }

    /// How far speech has got through `text` at source time `t`.
    public struct Progress: Sendable, Hashable {
        /// The current word (see ``SubtitleWords/highlightedRange(in:words:at:)``).
        public var highlight: Range<Int>?
        /// UTF-16 offset where the words not spoken yet begin: the end of the current word or, when the user
        /// changed it, the start of the next word that still matches (the end of the text if none does). 0 before
        /// the first word starts.
        public var spoken: Int
    }

    /// Where speech is in `text` at `t`, matching `words` as ``highlightedRange(in:words:at:)`` does. Nil without
    /// word timing.
    public static func progress(in text: String, words: [SubtitleWord], at t: Double) -> Progress? {
        guard !words.isEmpty else { return nil }
        guard let current = words.indices.last(where: { words[$0].start <= t }) else {
            return Progress(highlight: nil, spoken: 0)
        }
        let utf16 = Array(text.utf16)
        let tokens = tokens(in: text)
        let a = tokens.map { key(String(decoding: utf16[$0], as: UTF16.self)) }
        let b = words.map { key($0.text) }
        // lengths[i][j] = LCS of a[i...] and b[j...].
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                if j == current { return Progress(highlight: tokens[i], spoken: tokens[i].upperBound) }
                // The current word was changed: everything before the next matching word is being spoken.
                if j > current { return Progress(highlight: nil, spoken: tokens[i].lowerBound) }
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return Progress(highlight: nil, spoken: utf16.count)
    }

    /// Letters and digits, case- and diacritic-folded; a word of punctuation only is compared as is.
    static func key(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let letters = String(folded.filter { $0.isLetter || $0.isNumber })
        return letters.isEmpty ? word : letters
    }

    static func isCJKLetter(_ c: Character) -> Bool { c.isLetter && CueBuilder.isCJK(c) }
}

extension SubtitleSettings {
    /// Gives word timing to cues built from `revision` before word timing was stored. Returns whether anything
    /// changed.
    public mutating func fillWordTimings(from revision: TranscriptRevision) -> Bool {
        guard revisionID == revision.id else { return false }
        var units: [String: (text: String, timing: UnitTiming?)] = [:]
        for (segment, unit) in revision.allUnits {
            if let text = segment.text(of: unit) { units[unit.id] = (text, unit.timing) }
        }
        var changed = false
        for i in cues.indices where cues[i].words.isEmpty && !cues[i].coarse && !cues[i].unitIDs.isEmpty {
            let words = SubtitleWords.build(
                text: cues[i].generatedText ?? cues[i].text, units: cues[i].unitIDs.compactMap { units[$0] })
            guard !words.isEmpty else { continue }
            cues[i].words = words
            changed = true
        }
        return changed
    }
}
