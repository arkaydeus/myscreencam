import Foundation
import Testing

@testable import ProjectKit

struct AutoZoomTests {
    let defaults = ZoomTiming()  // 1.6, in 0.32, hold 0.85, out 0.48 → a keyframe lasts 1.65 s

    @Test func addedAndSeededZoomsShareTimingDefaults() {
        let keyframe = ZoomKeyframe(time: 0)
        #expect(keyframe.easeIn == defaults.easeIn)
        #expect(keyframe.hold == defaults.hold)
        #expect(keyframe.easeOut == defaults.easeOut)
    }

    func click(_ t: Double, x: Double = 0.5, y: Double = 0.5, button: Int = 0) -> InputEvent {
        InputEvent(t: t, kind: .down, x: x, y: y, button: button)
    }

    @Test func leftClickCreatesClickKeyframe() throws {
        let keyframes = AutoZoom.keyframes(from: [click(2, x: 0.25, y: 0.75)], defaults: defaults)
        let k = try #require(keyframes.first)
        #expect(keyframes.count == 1)
        #expect(abs(k.time - 1.88) < 1e-9)
        #expect(k.mode == .click)
        #expect(k.scale == 1.6)
        #expect(k.easeIn == 0.32 && k.hold == 0.85 && k.easeOut == 0.48)
        #expect(k.target == NormPoint(x: 0.25, y: 0.75))
        #expect(k.enabled && !k.instant)
    }

    @Test func earlyClickStartsAtZero() {
        let keyframes = AutoZoom.keyframes(from: [click(0.05)], defaults: defaults)
        #expect(keyframes.map(\.time) == [0])
    }

    @Test func minimumGapRule() {
        // First: t=0.88, end=2.53. Next allowed start ≥ 2.71 → click ≥ 2.83.
        let justTooSoon = AutoZoom.keyframes(from: [click(1), click(2.82)], defaults: defaults)
        #expect(justTooSoon.count == 1)
        let justEnough = AutoZoom.keyframes(from: [click(1), click(2.84)], defaults: defaults)
        #expect(justEnough.count == 2)
    }

    @Test func skippedClickDoesNotExtendTheWindow() {
        // Click 2 is skipped; click 3 is measured against click 1's end (2.53), not click 2's (3.03).
        let keyframes = AutoZoom.keyframes(from: [click(1), click(1.5), click(3)], defaults: defaults)
        #expect(keyframes.count == 2)
        #expect(abs(keyframes[1].time - 2.88) < 1e-9)
    }

    @Test func targetsAreClamped() {
        let keyframes = AutoZoom.keyframes(from: [click(1, x: -0.2, y: 1.4)], defaults: defaults)
        #expect(keyframes.first?.target == NormPoint(x: 0, y: 1))
    }

    @Test func onlyLeftMouseDownsCount() {
        let events = [
            click(1, button: 1),
            click(3, button: 2),
            InputEvent(t: 5, kind: .up, x: 0.5, y: 0.5, button: 0),
            InputEvent(t: 6, kind: .move, x: 0.5, y: 0.5),
            InputEvent(t: 7, kind: .scroll, x: 0.5, y: 0.5, dy: 3),
            InputEvent(t: 8, kind: .down, x: 0.5, y: 0.5),  // no button
        ]
        #expect(AutoZoom.keyframes(from: events, defaults: defaults).isEmpty)
    }

    @Test func usesCustomDefaultsAndSortsClicks() {
        let custom = ZoomTiming(scale: 2.5, easeIn: 0.1, hold: 0.2, easeOut: 0.1)
        let keyframes = AutoZoom.keyframes(from: [click(5), click(1)], defaults: custom)
        #expect(keyframes.map(\.scale) == [2.5, 2.5])
        #expect(approx(keyframes.map(\.time), [0.88, 4.88]))
    }

    @Test func makeInitialSeedsZoomsOnlyWhenAsked() {
        let meta = Fixtures.meta(duration: 5)
        let events = [click(1), click(4), click(5.5)]
        let plain = EditConfig.makeInitial(meta: meta, events: events, defaults: ProjectDefaults(autoZoom: false))
        #expect(plain == EditConfig.initial(for: meta).with(segmentIDs: plain.segments))
        #expect(plain.zoom.keyframes.isEmpty)

        let seeded = EditConfig.makeInitial(meta: meta, events: events, defaults: ProjectDefaults())
        // The click at 5.5 would start at 5.38 ≥ duration and is dropped.
        #expect(approx(seeded.zoom.keyframes.map(\.time), [0.88, 3.88]))
        #expect(seeded.segments.count == 1 && seeded.segments[0].end == 5)
    }
}

extension EditConfig {
    /// Copy with the given segments' ids (for comparing configs built separately).
    func with(segmentIDs segments: [Segment]) -> EditConfig {
        var copy = self
        for i in copy.segments.indices where i < segments.count { copy.segments[i].id = segments[i].id }
        return copy
    }
}
