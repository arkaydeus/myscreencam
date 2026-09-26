import ProjectKit
import Testing

@testable import RecordingKit

struct SessionClockTests {
    /// Host times are arbitrary large values like real `mach_absolute_time` seconds.
    let t0 = 250_000.0

    @Test func nothingBeforeStart() {
        var clock = SessionClock()
        #expect(clock.placement(forHostTime: t0) == nil)
        #expect(clock.elapsed(atHostTime: t0) == 0)
        clock.start(atHostTime: t0)
        #expect(clock.placement(forHostTime: t0 - 0.001) == nil)
        #expect(clock.sessionTime(forHostTime: t0) == 0)
        #expect(clock.sessionTime(forHostTime: t0 + 1.25) == 1.25)
    }

    @Test func startIsOnlySetOnce() {
        var clock = SessionClock()
        clock.start(atHostTime: t0)
        clock.start(atHostTime: t0 + 5)
        #expect(clock.startHostTime == t0)
    }

    @Test func pauseRemovesTheSkippedSpan() throws {
        var clock = SessionClock()
        clock.start(atHostTime: t0)
        let paused = clock.pause(atHostTime: t0 + 2)
        let pausedAgain = clock.pause(atHostTime: t0 + 2.5)  // already paused
        let resumed = clock.resume(atHostTime: t0 + 5)
        let resumedAgain = clock.resume(atHostTime: t0 + 6)  // not paused
        #expect(paused && !pausedAgain && resumed && !resumedAgain)

        // Captured before the pause (even if it arrives late): kept, unshifted.
        let before = try #require(clock.placement(forHostTime: t0 + 1.99))
        #expect(abs(before.sessionTime - 1.99) < 1e-9 && before.shift == 0)
        // Captured during the pause: dropped.
        #expect(clock.placement(forHostTime: t0 + 2) == nil)
        #expect(clock.placement(forHostTime: t0 + 4.999) == nil)
        // After resume: 3 s of pause removed.
        let after = try #require(clock.placement(forHostTime: t0 + 5.5))
        #expect(abs(after.sessionTime - 2.5) < 1e-9)
        #expect(after.shift == -3)
        #expect(clock.pauseRecords == [PauseRecord(at: 2, skipped: 3)])
    }

    @Test func multiplePausesAccumulate() throws {
        var clock = SessionClock()
        clock.start(atHostTime: t0)
        clock.pause(atHostTime: t0 + 1)
        clock.resume(atHostTime: t0 + 2)  // −1
        clock.pause(atHostTime: t0 + 4)  // session 3
        clock.resume(atHostTime: t0 + 7)  // −3
        let placement = try #require(clock.placement(forHostTime: t0 + 8))
        #expect(abs(placement.sessionTime - 4) < 1e-9)
        #expect(abs(placement.shift + 4) < 1e-9)
        #expect(clock.pauseRecords.map(\.at) == [1, 3])
        #expect(clock.pauseRecords.map(\.skipped) == [1, 3])
        // Between the pauses only the first one counts.
        #expect(abs(try #require(clock.sessionTime(forHostTime: t0 + 3)) - 2) < 1e-9)
    }

    @Test func elapsedFreezesWhilePausedAndAfterStop() {
        var clock = SessionClock()
        clock.start(atHostTime: t0)
        #expect(clock.elapsed(atHostTime: t0 + 1) == 1)
        clock.pause(atHostTime: t0 + 1.5)
        #expect(clock.elapsed(atHostTime: t0 + 3) == 1.5)
        clock.resume(atHostTime: t0 + 4)
        #expect(abs(clock.elapsed(atHostTime: t0 + 4.5) - 2) < 1e-9)
        clock.stop(atHostTime: t0 + 5)
        #expect(abs(clock.elapsed(atHostTime: t0 + 100) - 2.5) < 1e-9)
    }

    @Test func stopDropsLaterSamples() {
        var clock = SessionClock()
        clock.start(atHostTime: t0)
        clock.stop(atHostTime: t0 + 3)
        #expect(clock.placement(forHostTime: t0 + 2.9) != nil)
        #expect(clock.placement(forHostTime: t0 + 3) == nil)
        let paused = clock.pause(atHostTime: t0 + 4)
        #expect(!paused)
    }

    @Test func stopWhilePausedEndsAtThePause() {
        var clock = SessionClock()
        clock.start(atHostTime: t0)
        clock.pause(atHostTime: t0 + 2)
        clock.stop(atHostTime: t0 + 10)
        #expect(clock.elapsed(atHostTime: t0 + 10) == 2)
        // An open pause at stop is just the end of the recording, not a skipped span.
        #expect(clock.pauseRecords.isEmpty)
    }

    @Test func pauseBeforeStartIsRejected() {
        var clock = SessionClock()
        let paused = clock.pause(atHostTime: t0)
        #expect(!paused)
        #expect(!clock.isPaused)
    }
}
