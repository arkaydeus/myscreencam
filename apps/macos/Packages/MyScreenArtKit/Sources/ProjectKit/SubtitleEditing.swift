import Foundation

// MARK: - Transcript-driven cuts

extension EditConfig {
    /// Removes source seconds `start..<end` from the kept segments, splitting a segment when the range falls inside
    /// it. Pieces shorter than ``EditLimits/minimumSegmentLength`` left at either side are dropped with the range.
    /// - Throws: ``SegmentEditError/lastSegment`` when nothing would remain, ``SegmentEditError/noSegments`` for an
    ///   empty or non-finite range.
    public func removingSource(start: Double, end: Double) throws(SegmentEditError) -> EditConfig {
        guard start.isFinite, end.isFinite, end > start else { throw .noSegments }
        let minimum = EditLimits.minimumSegmentLength
        var kept: [Segment] = []
        for segment in segments {
            guard segment.end > start, segment.start < end else {
                kept.append(segment)
                continue
            }
            if start - segment.start >= minimum {
                kept.append(Segment(id: segment.id, start: segment.start, end: start))
            }
            if segment.end - end >= minimum {
                let reuse = kept.last?.id == segment.id ? UUID() : segment.id
                kept.append(Segment(id: reuse, start: end, end: segment.end))
            }
        }
        guard !kept.isEmpty else { throw .lastSegment }
        var config = self
        config.segments = kept
        return config
    }
}

public enum TranscriptCutError: Error, Sendable, Equatable {
    /// A selected word has no fine (acoustic, validated) timing.
    case noFineTiming
    case emptySelection
    case notContiguous
}

public enum TranscriptCuts {
    /// The source range covering the units `ids` (which must be consecutive in the revision and all have fine
    /// timing). Word-driven cuts are refused for coarse, manual or needs-review timing rather than cutting blind.
    public static func sourceRange(
        of ids: [String], in revision: TranscriptRevision
    ) throws(TranscriptCutError) -> (start: Double, end: Double) {
        guard !ids.isEmpty else { throw .emptySelection }
        let all = revision.allUnits.map(\.unit)
        let positions = ids.compactMap { id in all.firstIndex { $0.id == id } }.sorted()
        guard positions.count == ids.count, let first = positions.first, let last = positions.last,
            last - first + 1 == positions.count
        else { throw .notContiguous }
        var start = Double.infinity
        var end = -Double.infinity
        for unit in all[first...last] {
            guard let timing = unit.timing, timing.isFine else {
                if unit.kind == .punctuation { continue }
                throw .noFineTiming
            }
            start = min(start, timing.sourceRange.startSeconds)
            end = max(end, timing.sourceRange.endSeconds)
        }
        guard start < end else { throw .noFineTiming }
        return (start, end)
    }
}

// MARK: - Search

public enum TranscriptSearch {
    /// Cues whose text contains `query` (case- and diacritic-insensitive), in order.
    public static func matches(_ query: String, in cues: [SubtitleCue]) -> [SubtitleCue.ID] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return cues.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(\.id)
    }
}

// MARK: - Adopting a new revision

/// Carries the user's cue edits over to cues rebuilt from a new transcript revision.
///
/// An edited cue (text correction, own position or hand timing) is **reapplied** when the words the new revision
/// recognised inside the cue's time span normalise to the same words the old cue was generated from: the edit is
/// then unambiguous. Otherwise it's a **conflict**, and the user decides (`keep` = their cue wins and claims
/// that span; not in `keep` = the new transcript wins). Cues the user added (no `generatedText`) are kept when the
/// new revision recognised nothing in their span, and are conflicts otherwise.
public enum SubtitleMerge {
    public struct Conflict: Sendable, Equatable, Identifiable {
        public var id: SubtitleCue.ID { mine.id }
        /// The user's cue.
        public var mine: SubtitleCue
        /// What the new transcript says in that span.
        public var newText: String
    }

    public struct Result: Sendable, Equatable {
        public var cues: [SubtitleCue]
        public var conflicts: [Conflict]
        /// Edited cues carried over automatically.
        public var reapplied: Int
    }

    public static func merge(
        current: [SubtitleCue], newRevision: TranscriptRevision, keep: Set<SubtitleCue.ID> = [],
        rules: CueBuilder.Rules = CueBuilder.Rules()
    ) -> Result {
        let units: [(unit: TranscriptUnit, text: String, mid: Double)] = newRevision.segments.flatMap { segment in
            segment.units.compactMap { unit in
                guard let timing = unit.timing, let text = segment.text(of: unit) else { return nil }
                return (unit, text, (timing.sourceRange.startSeconds + timing.sourceRange.endSeconds) / 2)
            }
        }
        var pinned: [SubtitleCue] = []
        var claimed = Set<String>()
        var conflicts: [Conflict] = []
        var reapplied = 0
        for cue in current where cue.isUserEdited {
            let inside = units.filter { $0.mid >= cue.start && $0.mid < cue.end }
            let newText = inside.map(\.text).joined(separator: " ")
            let unambiguous: Bool =
                if let generated = cue.generatedText {
                    normalisedWords(generated) == normalisedWords(newText) && !inside.isEmpty
                } else {
                    inside.isEmpty
                }
            if unambiguous || keep.contains(cue.id) {
                var carried = cue
                carried.unitIDs = inside.map(\.unit.id)
                carried.words = SubtitleWords.build(
                    text: newText, units: inside.map { ($0.text, $0.unit.timing) })
                pinned.append(carried)
                claimed.formUnion(carried.unitIDs)
                if unambiguous { reapplied += 1 }
            } else {
                conflicts.append(Conflict(mine: cue, newText: newText))
            }
        }
        // Rebuilt cues that overlap a pinned cue are trimmed away from it by excluding the claimed units.
        var cues = CueBuilder.cues(from: newRevision, rules: rules, excludingUnits: claimed)
        cues.removeAll { cue in pinned.contains { $0.start < cue.end && cue.start < $0.end && cue.coarse } }
        cues += pinned
        cues.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        return Result(cues: cues, conflicts: conflicts, reapplied: reapplied)
    }

    /// Lower-cased letters/digits only, split into words (CJK characters are words on their own).
    static func normalisedWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for c in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
            if CueBuilder.isCJK(c), c.isLetter {
                if !current.isEmpty { words.append(current) }
                current = ""
                words.append(String(c))
            } else if c.isLetter || c.isNumber || c == "'" {
                current.append(c)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

// MARK: - SRT

public enum SubtitleExport {
    /// UTF-8 SubRip for the **edited** timeline: cue parts inside cuts are dropped and a cue spanning a cut is split
    /// into one entry per kept piece. Entries are numbered in time order.
    public static func srt(cues: [SubtitleCue], timeline: EditTimeline) -> String {
        var entries: [(start: Double, end: Double, text: String)] = []
        for cue in cues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for piece in timeline.pieces {
                let s = max(cue.start, piece.segment.start)
                let e = min(cue.end, piece.segment.end)
                guard e - s >= 0.05 else { continue }
                entries.append(
                    (piece.editedStart + (s - piece.segment.start), piece.editedStart + (e - piece.segment.start), text)
                )
            }
        }
        entries.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        var out = ""
        for (i, entry) in entries.enumerated() {
            out += "\(i + 1)\n\(timestamp(entry.start)) --> \(timestamp(entry.end))\n"
            // A blank line would end the entry early; SubRip has no escape for it, so collapse blank lines.
            let lines = entry.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            out += lines.filter { !$0.isEmpty }.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    /// `HH:MM:SS,mmm` (rounded to the millisecond).
    public static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

// MARK: - Receiving a transcript

extension SubtitleSettings {
    public enum Receipt: Sendable, Equatable {
        /// The cues were (re)built from the revision.
        case adopted
        /// The user has edits, so the revision waits as a candidate for them to adopt or discard.
        case candidate
    }

    /// Lands a finished transcription. With no user edits the cues are rebuilt from it; otherwise it becomes the
    /// candidate, so a job that finishes after the user started editing never overwrites their work.
    @discardableResult
    public mutating func receive(_ revision: TranscriptRevision, rules: CueBuilder.Rules = CueBuilder.Rules())
        -> Receipt
    {
        if cues.contains(where: \.isUserEdited) {
            candidateRevisionID = revision.id
            return .candidate
        }
        cues = CueBuilder.cues(from: revision, rules: rules)
        revisionID = revision.id
        candidateRevisionID = nil
        return .adopted
    }

    /// Adopts `revision`, carrying edits over (``SubtitleMerge``); `keep` resolves conflicts in the user's favour.
    public mutating func adopt(_ revision: TranscriptRevision, keep: Set<SubtitleCue.ID> = []) -> SubtitleMerge.Result {
        let result = SubtitleMerge.merge(current: cues, newRevision: revision, keep: keep)
        cues = result.cues
        revisionID = revision.id
        candidateRevisionID = nil
        return result
    }
}
