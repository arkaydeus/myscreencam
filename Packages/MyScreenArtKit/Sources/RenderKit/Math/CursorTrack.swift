import Foundation
import ProjectKit

/// The recorded pointer, precomputed once from `events.jsonl` for random access at any source time.
///
/// - Positions are linear between events. With smoothing, a critically damped spring follows that path; it is
///   integrated once at `sampleRate` Hz and looked up in O(1).
/// - The cursor is hidden before the first event.
/// - Cursor ids, activity (for hide-when-idle), clicks and drags are looked up by binary search.
///
/// All times are source (session) seconds; positions are normalised (0…1, y down, may lie outside 0…1).
public struct CursorTrack: Sendable {
    /// A mouse-down.
    public struct Click: Sendable, Equatable {
        public var time: Double
        public var position: NormPoint
        /// 0 = left, 1 = right, 2+ = other.
        public var button: Int

        public init(time: Double, position: NormPoint, button: Int) {
            self.time = time
            self.position = position
            self.button = button
        }
    }

    /// A span during which a button was held.
    public struct Drag: Sendable, Equatable {
        public var start: Double
        public var end: Double
    }

    /// One ghost of the drag trail.
    public struct TrailPoint: Sendable, Equatable {
        public var position: NormPoint
        /// 0 (newest) … 1 (oldest).
        public var age: Double
    }

    public let smoothing: CursorSmoothing
    public let sampleRate: Double
    /// Mouse-downs of every button, in time order.
    public let clicks: [Click]
    public let drags: [Drag]

    private let times: [Double]
    private let xs: [Double]
    private let ys: [Double]
    private let idTimes: [Double]
    private let ids: [Int]
    private let smoothStart: Double
    private let smoothX: [Float]
    private let smoothY: [Float]

    /// Seconds the spring keeps integrating after the last event, so it settles.
    static let settleTime = 1.5

    /// Angular frequency (rad/s) of the smoothing spring, or nil for no smoothing.
    public static func springOmega(for smoothing: CursorSmoothing) -> Double? {
        switch smoothing {
        case .none: nil
        case .rapid: 30
        case .medium: 14
        case .slow: 7
        }
    }

    public init(events: [InputEvent], smoothing: CursorSmoothing, sampleRate: Double = 240) {
        let sorted = events.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        self.smoothing = smoothing
        self.sampleRate = sampleRate
        times = sorted.map(\.t)
        xs = sorted.map(\.x)
        ys = sorted.map(\.y)

        var idTimes: [Double] = []
        var ids: [Int] = []
        var clicks: [Click] = []
        var drags: [Drag] = []
        var held: [Int: Double] = [:]
        for event in sorted {
            if let id = event.cursor, ids.last != id {
                idTimes.append(event.t)
                ids.append(id)
            }
            switch event.kind {
            case .down:
                let button = event.button ?? 0
                clicks.append(Click(time: event.t, position: NormPoint(x: event.x, y: event.y), button: button))
                if held[button] == nil { held[button] = event.t }
            case .up:
                if let start = held.removeValue(forKey: event.button ?? 0) {
                    drags.append(Drag(start: start, end: event.t))
                }
            case .move, .scroll:
                break
            }
        }
        let lastTime = sorted.last?.t ?? 0
        for start in held.values { drags.append(Drag(start: start, end: lastTime)) }
        self.idTimes = idTimes
        self.ids = ids
        self.clicks = clicks
        self.drags = Self.mergeDrags(drags)

        // Integrate the smoothing spring along the linear path.
        guard let omega = Self.springOmega(for: smoothing), let first = sorted.first else {
            smoothStart = sorted.first?.t ?? 0
            smoothX = []
            smoothY = []
            return
        }
        let start = first.t
        let span = lastTime - start + Self.settleTime
        let count = Int((span * sampleRate).rounded(.up)) + 1
        let spring = CriticallyDampedSpring(omega: omega)
        let dt = 1 / sampleRate
        var sx = [Float](repeating: 0, count: count)
        var sy = [Float](repeating: 0, count: count)
        var x = first.x
        var y = first.y
        var vx = 0.0
        var vy = 0.0
        var cursor = 0
        let times = self.times
        let xs = self.xs
        let ys = self.ys
        for i in 0..<count {
            let t = start + Double(i) * dt
            while cursor + 1 < times.count, times[cursor + 1] <= t { cursor += 1 }
            let (tx, ty) = Self.interpolate(times: times, xs: xs, ys: ys, index: cursor, t: t)
            if i > 0 {
                spring.step(position: &x, velocity: &vx, target: tx, dt: dt)
                spring.step(position: &y, velocity: &vy, target: ty, dt: dt)
            }
            sx[i] = Float(x)
            sy[i] = Float(y)
        }
        smoothStart = start
        smoothX = sx
        smoothY = sy
    }

    /// Time of the first event, before which the cursor is hidden.
    public var firstEventTime: Double? { times.first }
    public var isEmpty: Bool { times.isEmpty }

    /// Unsmoothed position: linear between events, held after the last one. Nil before the first event.
    public func rawPosition(at t: Double) -> NormPoint? {
        guard let i = Self.lastIndex(in: times, atOrBefore: t) else { return nil }
        let (x, y) = Self.interpolate(times: times, xs: xs, ys: ys, index: i, t: t)
        return NormPoint(x: x, y: y)
    }

    /// Displayed (smoothed) position. Nil before the first event.
    public func position(at t: Double) -> NormPoint? {
        guard let first = times.first, t >= first else { return nil }
        guard !smoothX.isEmpty else { return rawPosition(at: t) }
        let f = (t - smoothStart) * sampleRate
        let last = smoothX.count - 1
        if f >= Double(last) { return NormPoint(x: Double(smoothX[last]), y: Double(smoothY[last])) }
        let i = max(0, Int(f))
        let w = Float(f - Double(i))
        return NormPoint(
            x: Double(smoothX[i] + (smoothX[i + 1] - smoothX[i]) * w),
            y: Double(smoothY[i] + (smoothY[i + 1] - smoothY[i]) * w))
    }

    /// The captured cursor image id showing at `t` (the first known id before any was recorded).
    public func cursorID(at t: Double) -> Int? {
        guard !ids.isEmpty else { return nil }
        guard let i = Self.lastIndex(in: idTimes, atOrBefore: t) else { return ids[0] }
        return ids[i]
    }

    /// Time of the latest event at or before `t`.
    public func lastActivity(atOrBefore t: Double) -> Double? {
        Self.lastIndex(in: times, atOrBefore: t).map { times[$0] }
    }

    /// Seconds the cursor takes to fade out once idle.
    public static let idleFadeDuration = 0.25

    /// Cursor opacity 0…1: 0 before the first event; with `hideWhenIdle`, fades out over
    /// `idleFadeDuration` once `idleDelay` seconds pass without any event, and reappears on the next event.
    public func opacity(at t: Double, hideWhenIdle: Bool, idleDelay: Double) -> Double {
        guard let last = lastActivity(atOrBefore: t) else { return 0 }
        guard hideWhenIdle else { return 1 }
        let idle = t - last - max(0, idleDelay)
        if idle <= 0 { return 1 }
        return max(0, 1 - idle / Self.idleFadeDuration)
    }

    /// Mouse-downs with `t − duration < click.time ≤ t`, oldest first.
    public func recentClicks(at t: Double, within duration: Double) -> ArraySlice<Click> {
        guard duration > 0, let hi = Self.lastIndex(in: clicks, atOrBefore: t, key: \.time) else { return [] }
        var lo = hi
        while lo > 0, clicks[lo - 1].time > t - duration { lo -= 1 }
        if clicks[lo].time <= t - duration { return [] }
        return clicks[lo...hi]
    }

    /// The drag in progress at `t`, if a button is held.
    public func drag(at t: Double) -> Drag? {
        guard let i = Self.lastIndex(in: drags, atOrBefore: t, key: \.start) else { return nil }
        return drags[i].end >= t ? drags[i] : nil
    }

    /// Up to `length` earlier positions spaced `spacing` seconds apart while a button is held (newest first).
    public func trail(at t: Double, length: Int, spacing: Double) -> [TrailPoint] {
        guard length > 0, spacing > 0, let drag = drag(at: t) else { return [] }
        var points: [TrailPoint] = []
        points.reserveCapacity(length)
        for i in 1...length {
            let ti = t - Double(i) * spacing
            if ti < drag.start { break }
            guard let p = position(at: ti) else { break }
            points.append(TrailPoint(position: p, age: Double(i) / Double(length)))
        }
        return points
    }

    // MARK: helpers

    private static func interpolate(times: [Double], xs: [Double], ys: [Double], index i: Int, t: Double) -> (
        Double, Double
    ) {
        guard i + 1 < times.count else { return (xs[i], ys[i]) }
        let span = times[i + 1] - times[i]
        guard span > 1e-9 else { return (xs[i + 1], ys[i + 1]) }
        let w = min(max((t - times[i]) / span, 0), 1)
        return (xs[i] + (xs[i + 1] - xs[i]) * w, ys[i] + (ys[i + 1] - ys[i]) * w)
    }

    private static func mergeDrags(_ drags: [Drag]) -> [Drag] {
        var merged: [Drag] = []
        for drag in drags.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, drag.start <= last.end {
                merged[merged.count - 1].end = max(last.end, drag.end)
            } else {
                merged.append(drag)
            }
        }
        return merged
    }

    /// Index of the last element with value ≤ `t`, or nil.
    static func lastIndex(in values: [Double], atOrBefore t: Double) -> Int? {
        lastIndex(in: values, atOrBefore: t, key: \.self)
    }

    static func lastIndex<T>(in values: [T], atOrBefore t: Double, key: (T) -> Double) -> Int? {
        var lo = 0
        var hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(values[mid]) <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}
