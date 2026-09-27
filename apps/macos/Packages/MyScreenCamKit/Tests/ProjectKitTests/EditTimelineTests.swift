import Testing

@testable import ProjectKit

struct EditTimelineTests {
    // Keep 0–2, 5–6, 8–10 → edited duration 5.
    let timeline = EditTimeline(segments: [
        Segment(start: 0, end: 2), Segment(start: 5, end: 6), Segment(start: 8, end: 10),
    ])

    @Test func duration() {
        #expect(timeline.duration == 5)
    }

    @Test(arguments: [(0.0, 0.0), (1.5, 1.5), (2.0, 5.0), (2.5, 5.5), (3.0, 8.0), (5.0, 10.0), (-1, 0), (99, 10)])
    func editedToSource(edited: Double, source: Double) {
        #expect(abs(timeline.sourceTime(forEdited: edited) - source) < 1e-9)
    }

    @Test func sourceToEdited() {
        #expect(timeline.editedTime(forSource: 5.5) == 2.5)
        #expect(timeline.editedTime(forSource: 3) == nil)
        #expect(timeline.editedTimeSnapping(forSource: 3) == 2)
        #expect(timeline.editedTimeSnapping(forSource: 11) == 5)
    }

    @Test func emptySegmentsAreSkipped() {
        let t = EditTimeline(segments: [Segment(start: 1, end: 1), Segment(start: 2, end: 3)])
        #expect(t.pieces.count == 1)
        #expect(t.sourceTime(forEdited: 0.5) == 2.5)
    }
}
