import Foundation

/// Why a segment edit was refused.
public enum SegmentEditError: Error, Sendable, Equatable {
    /// A cut within ``EditLimits/minimumSegmentLength`` of a segment edge ("Too close to edge").
    case tooCloseToEdge
    /// Deleting the only remaining segment.
    case lastSegment
    /// No segment has the given id.
    case segmentNotFound
    /// The config has no (non-empty) segments to edit.
    case noSegments
}

/// Pure segment operations. Each returns a new config and leaves `self` unchanged, so the editor can register
/// the old value for undo. Inputs the UI measures on the timeline are **edited** seconds; trims take **source**
/// seconds (the outer edges of the first and last segment). Other effect times are untouched (they are source
/// time and stay valid).
extension EditConfig {
    /// Splits the segment under edited time `t` into two at that moment. The left half keeps the segment's id.
    /// - Throws: ``SegmentEditError/tooCloseToEdge`` within ``EditLimits/minimumSegmentLength`` of either edge of
    ///   the segment (including the start and end of the timeline), ``SegmentEditError/noSegments``.
    public func cut(atEdited t: Double) throws(SegmentEditError) -> EditConfig {
        let timeline = EditTimeline(segments: segments)
        guard t.isFinite, let index = timeline.pieceIndex(forEdited: t) else { throw .noSegments }
        let piece = timeline.pieces[index]
        let edge = EditLimits.minimumSegmentLength
        guard t - piece.editedStart >= edge, piece.editedEnd - t >= edge else { throw .tooCloseToEdge }
        guard let position = segments.firstIndex(where: { $0.id == piece.segment.id }) else { throw .noSegments }

        let source = piece.segment.start + (t - piece.editedStart)
        var config = self
        config.segments[position].end = source
        config.segments.insert(Segment(start: source, end: piece.segment.end), at: position + 1)
        return config
    }

    /// Removes a segment.
    /// - Throws: ``SegmentEditError/lastSegment`` when it is the only one, ``SegmentEditError/segmentNotFound``.
    public func deleteSegment(id: Segment.ID) throws(SegmentEditError) -> EditConfig {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { throw .segmentNotFound }
        guard segments.count > 1 else { throw .lastSegment }
        var config = self
        config.segments.remove(at: index)
        return config
    }

    /// Moves the start of the first segment to source time `s`, clamped so it stays ≥ 0 and the segment keeps at
    /// least ``EditLimits/minimumSegmentLength``.
    public func trimStart(toSource s: Double) throws(SegmentEditError) -> EditConfig {
        guard let first = segments.first else { throw .noSegments }
        let upper = max(0, first.end - EditLimits.minimumSegmentLength)
        var config = self
        config.segments[0].start = clamp(s, 0...upper, fallback: first.start)
        return config
    }

    /// Moves the end of the last segment to source time `s`, clamped so it stays ≤ `duration` (the recording
    /// length; pass it to stop the edge being dragged past the end) and the segment keeps at least
    /// ``EditLimits/minimumSegmentLength``.
    public func trimEnd(toSource s: Double, duration: Double = .infinity) throws(SegmentEditError) -> EditConfig {
        guard let last = segments.last else { throw .noSegments }
        let lower = last.start + EditLimits.minimumSegmentLength
        let upper = max(lower, duration)
        var config = self
        config.segments[config.segments.count - 1].end = clamp(s, lower...upper, fallback: last.end)
        return config
    }

    /// Replaces all segments with one covering `0…duration` (keeping the first segment's id).
    public func resetCuts(duration: Double) -> EditConfig {
        var config = self
        config.segments = [Segment(id: segments.first?.id ?? UUID(), start: 0, end: max(0, duration))]
        return config
    }
}
