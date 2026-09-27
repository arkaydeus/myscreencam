import ProjectKit

/// Maps host-clock timestamps onto a recording's **session timeline**: 0 at the first screen frame, paused
/// spans removed, nothing after stop.
///
/// Pure value type (no clocks read), so the arithmetic is unit-tested directly. Decisions use each sample's
/// own timestamp, not its arrival time: a buffer captured just before `pause()` is kept even if it arrives
/// after, and one captured during a pause is dropped even if it arrives after `resume()`.
public struct SessionClock: Sendable, Equatable {
    public struct Pause: Sendable, Equatable {
        public var hostStart: Double
        /// Nil while the pause is ongoing.
        public var hostEnd: Double?
        /// Session time at which the pause happened.
        public var sessionTime: Double
    }

    /// Where a sample lands.
    public struct Placement: Sendable, Equatable {
        /// Seconds on the session timeline.
        public var sessionTime: Double
        /// Seconds to add to the sample's host timestamps before writing (minus the pauses before it). Writers
        /// store `host + shift`, which equals `sessionTime + startHostTime`, so a file's own t=0 is its first
        /// sample and every stream keeps one common time base.
        public var shift: Double
    }

    public private(set) var startHostTime: Double?
    public private(set) var stopHostTime: Double?
    public private(set) var pauses: [Pause] = []

    public init() {}

    public var isStarted: Bool { startHostTime != nil }
    public var isPaused: Bool { pauses.last.map { $0.hostEnd == nil } ?? false }
    public var isStopped: Bool { stopHostTime != nil }

    /// Starts the timeline at `hostTime` (session time 0). Ignored if already started.
    public mutating func start(atHostTime hostTime: Double) {
        guard startHostTime == nil else { return }
        startHostTime = hostTime
    }

    /// Pauses at `hostTime`. Returns false if not running.
    @discardableResult
    public mutating func pause(atHostTime hostTime: Double) -> Bool {
        guard let start = startHostTime, !isPaused, !isStopped, hostTime >= start else { return false }
        let at = hostTime - start - pausedDuration(before: hostTime)
        pauses.append(Pause(hostStart: hostTime, hostEnd: nil, sessionTime: at))
        return true
    }

    /// Resumes at `hostTime`. Returns false if not paused.
    @discardableResult
    public mutating func resume(atHostTime hostTime: Double) -> Bool {
        guard isPaused, !isStopped, let last = pauses.last, hostTime >= last.hostStart else { return false }
        pauses[pauses.count - 1].hostEnd = hostTime
        return true
    }

    /// Ends the timeline: samples at or after `hostTime` are dropped.
    public mutating func stop(atHostTime hostTime: Double) {
        guard stopHostTime == nil else { return }
        stopHostTime = hostTime
    }

    /// Total length of completed pauses that ended at or before `hostTime`.
    public func pausedDuration(before hostTime: Double) -> Double {
        pauses.reduce(0) { total, pause in
            guard let end = pause.hostEnd, end <= hostTime else { return total }
            return total + (end - pause.hostStart)
        }
    }

    /// Where a sample captured at `hostTime` goes, or nil to drop it (before start, inside a pause, after stop).
    public func placement(forHostTime hostTime: Double) -> Placement? {
        guard let start = startHostTime, hostTime >= start else { return nil }
        if let stop = stopHostTime, hostTime >= stop { return nil }
        var paused = 0.0
        for pause in pauses {
            if hostTime < pause.hostStart { break }
            guard let end = pause.hostEnd, hostTime >= end else { return nil }
            paused += end - pause.hostStart
        }
        return Placement(sessionTime: hostTime - start - paused, shift: -paused)
    }

    public func sessionTime(forHostTime hostTime: Double) -> Double? {
        placement(forHostTime: hostTime)?.sessionTime
    }

    /// Session time "now": frozen during a pause and after stop, 0 before start.
    public func elapsed(atHostTime hostTime: Double) -> Double {
        guard let start = startHostTime else { return 0 }
        let now = min(hostTime, stopHostTime ?? hostTime)
        if let last = pauses.last, now >= last.hostStart, last.hostEnd.map({ now < $0 }) ?? true {
            return last.sessionTime
        }
        return max(0, now - start - pausedDuration(before: now))
    }

    /// Completed pauses for `meta.json` (a pause still open at stop is just the end of the recording).
    public var pauseRecords: [PauseRecord] {
        pauses.compactMap { pause in
            pause.hostEnd.map { PauseRecord(at: pause.sessionTime, skipped: $0 - pause.hostStart) }
        }
    }
}
