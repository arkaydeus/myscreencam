import Foundation
import ProjectKit

/// Maps forced-aligner items back onto the exact recognised text.
///
/// The Qwen aligner doesn't return offsets: it re-tokenises the text it was given (keeping letters, digits and
/// apostrophes; every CJK ideograph is its own token; everything else separates tokens) and returns one timed
/// item per token. We tokenise `rawText` with the same rules **while tracking UTF-8 byte ranges**, then pair items
/// with tokens strictly in order. Any disagreement is reported as a mismatch rather than guessed with
/// independent string searches, so a timing is never attached to the wrong word.
public enum AlignmentMapper {
    public struct Token: Sendable, Equatable {
        public var text: String
        public var utf8Start: Int
        public var utf8End: Int
        public var isCJK: Bool
    }

    public struct Result: Sendable, Equatable {
        /// One entry per token, in order: the item's (start, end) samples, or nil where unmatched.
        public var tokens: [Token]
        public var timings: [(start: Int64, end: Int64)?]
        public var mismatched: Int

        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.tokens == rhs.tokens && lhs.mismatched == rhs.mismatched
                && lhs.timings.map { $0.map { [$0.start, $0.end] } }
                    == rhs.timings.map { $0.map { [$0.start, $0.end] } }
        }
    }

    /// MLX Audio Swift's `ForceAlignProcessor.isKeptChar`.
    static func isKept(_ c: Character) -> Bool { c == "'" || c.isLetter || c.isNumber }

    /// MLX Audio Swift's `isCJKChar` ranges (ideographs only; kana/hangul are ordinary letters to it).
    static func isAlignerCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0x2A700...0x2B73F).contains(v) || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v)
    }

    /// Tokens of `text` as the aligner forms them, with byte ranges. Mirrors both of the aligner's modes
    /// (`tokenizeSpaceLang` splits on spaces then drops non-kept characters inside a word, so `don't!x` is one
    /// token `don'tx`; `tokenizeChineseMixed` treats every non-kept character as a separator).
    public static func tokens(_ text: String, chineseMode: Bool) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start = -1
        var end = -1
        var offset = 0
        func flush() {
            if !current.isEmpty { tokens.append(Token(text: current, utf8Start: start, utf8End: end, isCJK: false)) }
            current = ""
            start = -1
        }
        for c in text {
            let width = String(c).utf8.count
            defer { offset += width }
            if isAlignerCJK(c) {
                flush()
                tokens.append(Token(text: String(c), utf8Start: offset, utf8End: offset + width, isCJK: true))
            } else if isKept(c) {
                if current.isEmpty { start = offset }
                current.append(c)
                end = offset + width
            } else if chineseMode || c == " " {
                flush()
            }
            // Space mode: other separators (punctuation, newlines…) are dropped without splitting the word.
        }
        flush()
        return tokens
    }

    /// Pairs `items` with the tokens of `rawText`. Normally the aligner returns exactly our tokens and they pair
    /// one to one. When they don't, the pairing is the longest common subsequence of the two (exact text match),
    /// which is monotonic by construction: an item can never be attached to an earlier or out-of-order token, and a
    /// repeated word can't borrow another occurrence's time. Unpaired tokens stay untimed.
    public static func map(items: [AlignedItem], rawText: String, chineseMode: Bool) -> Result {
        let tokens = tokens(rawText, chineseMode: chineseMode)
        var timings: [(start: Int64, end: Int64)?] = Array(repeating: nil, count: tokens.count)
        func time(_ item: AlignedItem) -> (start: Int64, end: Int64) {
            (item.startSample, max(item.endSample, item.startSample))
        }

        if items.count == tokens.count, zip(items, tokens).allSatisfy({ $0.text == $1.text }) {
            for (i, item) in items.enumerated() { timings[i] = time(item) }
            return Result(tokens: tokens, timings: timings, mismatched: 0)
        }
        let n = tokens.count
        let m = items.count
        // Bound the quadratic table; a window's text is far below this.
        guard n > 0, m > 0, n * m <= 4_000_000 else {
            return Result(tokens: tokens, timings: timings, mismatched: n + m)
        }
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] =
                    tokens[i].text == items[j].text ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0
        var j = 0
        var matched = 0
        while i < n, j < m {
            if tokens[i].text == items[j].text, table[i][j] == table[i + 1][j + 1] + 1 {
                timings[i] = time(items[j])
                matched += 1
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return Result(tokens: tokens, timings: timings, mismatched: (n - matched) + (m - matched))
    }
}
