import Foundation

/// Maps between **edited** time (the concatenation of kept segments, starting at 0) and **source** (session) time.
/// Build one per `EditConfig.segments` change; lookups are O(log n).
public struct EditTimeline: Sendable, Equatable {
    public struct Piece: Sendable, Equatable {
        public var segment: Segment
        /// Edited time at which this segment starts.
        public var editedStart: Double

        public var editedEnd: Double { editedStart + segment.duration }
    }

    public let pieces: [Piece]
    /// Total edited duration.
    public let duration: Double

    public init(segments: [Segment]) {
        var pieces: [Piece] = []
        var t = 0.0
        for segment in segments where segment.duration > 0 {
            pieces.append(Piece(segment: segment, editedStart: t))
            t += segment.duration
        }
        self.pieces = pieces
        self.duration = t
    }

    /// Index of the piece containing edited time `t` (clamped into 0…duration; the end maps to the last piece).
    public func pieceIndex(forEdited t: Double) -> Int? {
        guard !pieces.isEmpty else { return nil }
        let t = min(max(t, 0), duration)
        var lo = 0
        var hi = pieces.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pieces[mid].editedStart <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Source time for an edited time (clamped to the timeline).
    public func sourceTime(forEdited t: Double) -> Double {
        guard let i = pieceIndex(forEdited: t) else { return 0 }
        let piece = pieces[i]
        let clamped = min(max(t, 0), duration)
        return min(piece.segment.start + (clamped - piece.editedStart), piece.segment.end)
    }

    /// Edited time for a source time, or nil when that moment was cut.
    public func editedTime(forSource s: Double) -> Double? {
        for piece in pieces where s >= piece.segment.start && s <= piece.segment.end {
            return piece.editedStart + (s - piece.segment.start)
        }
        return nil
    }

    /// Edited time for a source time; times inside a cut snap to the start of the next kept segment
    /// (or the end of the timeline).
    public func editedTimeSnapping(forSource s: Double) -> Double {
        if let t = editedTime(forSource: s) { return t }
        return pieces.first { $0.segment.start > s }?.editedStart ?? duration
    }
}
