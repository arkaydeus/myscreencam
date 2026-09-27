import Foundation
import Testing

@testable import ProjectKit

struct SegmentEditingTests {
    /// Keep 0–2, 5–6, 8–10 → edited 0–2 | 2–3 | 3–5.
    let config = EditConfig(segments: [
        Segment(start: 0, end: 2), Segment(start: 5, end: 6), Segment(start: 8, end: 10),
    ])

    func ranges(_ config: EditConfig) -> [[Double]] { config.segments.map { [$0.start, $0.end] } }

    @Test func cutSplitsAtEditedTime() throws {
        let cut = try config.cut(atEdited: 2.5)  // source 5.5
        #expect(ranges(cut) == [[0, 2], [5, 5.5], [5.5, 6], [8, 10]])
        #expect(cut.segments[1].id == config.segments[1].id)
        #expect(cut.segments[2].id != config.segments[1].id)
        #expect(config.segments.count == 3)  // original untouched
    }

    @Test(arguments: [0.0, 0.05, 1.95, 2.0, 2.05, 2.95, 3.0, 4.95, 5.0])
    func cutRefusesNearEdges(at t: Double) {
        #expect(throws: SegmentEditError.tooCloseToEdge) { try config.cut(atEdited: t) }
    }

    @Test func cutJustOutsideTheTolerance() throws {
        #expect(try config.cut(atEdited: 0.1).segments.count == 4)
        #expect(approx(try config.cut(atEdited: 3.9).segments[3].start, 8.9))
    }

    @Test func cutOnEmptyConfig() {
        #expect(throws: SegmentEditError.noSegments) { try EditConfig(segments: []).cut(atEdited: 1) }
    }

    @Test func deleteSegment() throws {
        let deleted = try config.deleteSegment(id: config.segments[1].id)
        #expect(ranges(deleted) == [[0, 2], [8, 10]])
        #expect(throws: SegmentEditError.segmentNotFound) { try config.deleteSegment(id: UUID()) }
        let single = EditConfig(segments: [Segment(start: 0, end: 4)])
        #expect(throws: SegmentEditError.lastSegment) { try single.deleteSegment(id: single.segments[0].id) }
    }

    @Test func trimStart() throws {
        #expect(ranges(try config.trimStart(toSource: 1)).first == [1, 2])
        #expect(ranges(try config.trimStart(toSource: -4)).first == [0, 2])
        #expect(approx(ranges(try config.trimStart(toSource: 5)).first!, [1.9, 2]))  // keeps 0.1 s
    }

    @Test func trimEnd() throws {
        #expect(ranges(try config.trimEnd(toSource: 9)).last == [8, 9])
        #expect(approx(ranges(try config.trimEnd(toSource: 3)).last!, [8, 8.1]))
        #expect(ranges(try config.trimEnd(toSource: 14, duration: 12)).last == [8, 12])
        #expect(ranges(try config.trimEnd(toSource: 14)).last == [8, 14])
        #expect(throws: SegmentEditError.noSegments) { try EditConfig(segments: []).trimEnd(toSource: 1) }
    }

    @Test func resetCuts() {
        let reset = config.resetCuts(duration: 12)
        #expect(ranges(reset) == [[0, 12]])
        #expect(reset.segments[0].id == config.segments[0].id)
    }

    @Test func editsKeepOtherSettings() throws {
        var config = self.config
        config.zoom.keyframes = [ZoomKeyframe(time: 5.2)]
        config.blur = [BlurMask(start: 1, end: 9)]
        let edited = try config.cut(atEdited: 1).deleteSegment(id: config.segments[2].id)
        #expect(edited.zoom == config.zoom)
        #expect(edited.blur == config.blur)
    }
}
