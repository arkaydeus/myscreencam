import CoreGraphics
import Foundation
import ProjectKit

/// The zoom transform at one moment: scale `z` about the pivot `(tx·W, ty·H)` of the source frame.
public struct ZoomState: Sendable, Equatable {
    public var scale: Double
    /// Normalised pivot (0…1, y down). The source point under the pivot stays put while zooming.
    public var pivot: NormPoint

    public init(scale: Double, pivot: NormPoint) {
        self.scale = scale
        self.pivot = pivot
    }

    public static let identity = ZoomState(scale: 1, pivot: .center)

    public var isIdentity: Bool { scale <= 1 + 1e-9 }

    /// The visible part of a `size` frame (y-down pixels): origin `tx·(W − W/z), ty·(H − H/z)`, size `W/z × H/z`.
    /// Stays in bounds for pivots in 0…1.
    public func cropRect(in size: CGSize) -> CGRect {
        let z = max(scale, 1)
        let w = size.width / z
        let h = size.height / z
        let tx = min(max(pivot.x, 0), 1)
        let ty = min(max(pivot.y, 0), 1)
        return CGRect(x: tx * (size.width - w), y: ty * (size.height - h), width: w, height: h)
    }

    /// Maps a normalised point of the zoomed (visible) frame back to normalised source coordinates.
    public func sourcePoint(fromVisible p: NormPoint) -> NormPoint {
        let crop = cropRect(in: CGSize(width: 1, height: 1))
        return NormPoint(x: crop.minX + p.x * crop.width, y: crop.minY + p.y * crop.height)
    }

    /// Maps a normalised source point to normalised coordinates of the zoomed (visible) frame.
    public func visiblePoint(fromSource p: NormPoint) -> NormPoint {
        let crop = cropRect(in: CGSize(width: 1, height: 1))
        return NormPoint(x: (p.x - crop.minX) / crop.width, y: (p.y - crop.minY) / crop.height)
    }

    /// The pivot that puts normalised `center` in the middle of the view at `scale`, clamped so the crop stays in
    /// bounds.
    public static func pivot(centeredOn center: NormPoint, scale: Double) -> NormPoint {
        let z = max(scale, 1)
        let visible = 1 / z
        let slack = 1 - visible
        guard slack > 1e-6 else { return center.clamped }
        func axis(_ c: Double) -> Double {
            let origin = min(max(c - visible / 2, 0), slack)
            return origin / slack
        }
        return NormPoint(x: axis(center.x), y: axis(center.y))
    }
}

/// Keyframe timing: ease-in, hold and ease-out phases.
public enum ZoomPhase: Sendable, Equatable {
    case easeIn(progress: Double)
    case hold
    case easeOut(progress: Double)
}

/// Evaluates zoom keyframes at a source time.
///
/// Only enabled keyframes render, and only when zoom is enabled. Where keyframes overlap, the one that starts
/// earliest wins. Timing: `inEnd = t + in`, `holdEnd = inEnd + hold`, `end = holdEnd + out`; instant keyframes
/// have `in = out = 0`. Scale is `lerp(1, s, easeInOutCubic(p))`.
///
/// Zooms happen inside `crop`: targets and the follow camera (normalised source points) are mapped into the crop, so
/// the states are relative to it.
public struct ZoomEvaluator: Sendable {
    public let keyframes: [ZoomKeyframe]
    public let follow: FollowCameraTrack?
    /// The part of the source the zoom works in (normalised).
    public let crop: NormRect

    public init(settings: ZoomSettings, crop: NormRect = .full, follow: FollowCameraTrack? = nil) {
        keyframes =
            settings.enabled
            ? settings.keyframes.filter { $0.enabled && $0.end > $0.time }.sorted { $0.time < $1.time } : []
        self.follow = follow
        self.crop = crop
    }

    /// A normalised source point in the crop's normalised coordinates.
    private func cropPoint(_ p: NormPoint) -> NormPoint {
        NormPoint(x: (p.x - crop.x) / max(crop.w, 1e-9), y: (p.y - crop.y) / max(crop.h, 1e-9))
    }

    /// Whether any keyframe uses follow-mouse (so a `FollowCameraTrack` is needed).
    public static func needsFollowTrack(_ settings: ZoomSettings) -> Bool {
        settings.enabled && settings.keyframes.contains { $0.enabled && $0.mode == .followMouse }
    }

    /// The keyframe rendering at `t` (earliest start wins among overlapping ones).
    public func activeKeyframe(at t: Double) -> ZoomKeyframe? {
        for keyframe in keyframes {
            if keyframe.time > t { break }
            if t < keyframe.end { return keyframe }
        }
        return nil
    }

    /// Phase of `keyframe` at `t`, or nil outside `[time, end)`.
    public static func phase(of keyframe: ZoomKeyframe, at t: Double) -> ZoomPhase? {
        guard t >= keyframe.time, t < keyframe.end else { return nil }
        let easeIn = keyframe.effectiveEaseIn
        let inEnd = keyframe.time + easeIn
        let holdEnd = inEnd + keyframe.hold
        if t < inEnd { return .easeIn(progress: (t - keyframe.time) / easeIn) }
        if t < holdEnd { return .hold }
        let easeOut = keyframe.effectiveEaseOut
        return .easeOut(progress: easeOut > 0 ? (t - holdEnd) / easeOut : 1)
    }

    /// Scale of `keyframe` at `t` (1 outside it).
    public static func scale(of keyframe: ZoomKeyframe, at t: Double) -> Double {
        let target = max(keyframe.scale, 1)
        switch phase(of: keyframe, at: t) {
        case nil: return 1
        case .easeIn(let p): return Easing.lerp(1, target, Easing.easeInOutCubic(p))
        case .hold: return target
        case .easeOut(let p): return Easing.lerp(1, target, 1 - Easing.easeInOutCubic(p))
        }
    }

    /// The zoom at source time `t`, relative to `crop`.
    public func state(at t: Double) -> ZoomState {
        guard let keyframe = activeKeyframe(at: t) else { return .identity }
        let scale = Self.scale(of: keyframe, at: t)
        switch keyframe.mode {
        case .manual, .click:
            return ZoomState(scale: scale, pivot: cropPoint(keyframe.target).clamped)
        case .followMouse:
            let center = cropPoint(follow?.center(at: t) ?? keyframe.target)
            return ZoomState(scale: scale, pivot: ZoomState.pivot(centeredOn: center, scale: scale))
        }
    }
}

/// A smoothed camera centre that follows the cursor for follow-mouse zooms.
///
/// The camera only moves once the cursor leaves a dead zone around it, then eases after it with a critically
/// damped spring, so small cursor jitter never moves the view. Precomputed at `sampleRate` Hz.
public struct FollowCameraTrack: Sendable {
    public let deadZone: Double
    public let omega: Double
    public let sampleRate: Double
    private let start: Double
    private let xs: [Float]
    private let ys: [Float]

    public init(cursor: CursorTrack, deadZone: Double = 0.1, omega: Double = 5, sampleRate: Double = 60) {
        self.deadZone = deadZone
        self.omega = omega
        self.sampleRate = sampleRate
        guard let first = cursor.firstEventTime, let p0 = cursor.position(at: first) else {
            start = 0
            xs = []
            ys = []
            return
        }
        let end = (cursor.lastActivity(atOrBefore: .infinity) ?? first) + CursorTrack.settleTime + 2
        let count = Int(((end - first) * sampleRate).rounded(.up)) + 1
        let spring = CriticallyDampedSpring(omega: omega)
        let dt = 1 / sampleRate
        var cx = min(max(p0.x, 0), 1)
        var cy = min(max(p0.y, 0), 1)
        var vx = 0.0
        var vy = 0.0
        var xs = [Float](repeating: 0, count: count)
        var ys = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = first + Double(i) * dt
            if i > 0, let p = cursor.position(at: t) {
                let px = min(max(p.x, 0), 1)
                let py = min(max(p.y, 0), 1)
                // Desired centre: the nearest point to the camera that keeps the cursor inside the dead zone.
                let dx = min(max(cx, px - deadZone), px + deadZone)
                let dy = min(max(cy, py - deadZone), py + deadZone)
                spring.step(position: &cx, velocity: &vx, target: dx, dt: dt)
                spring.step(position: &cy, velocity: &vy, target: dy, dt: dt)
            }
            xs[i] = Float(cx)
            ys[i] = Float(cy)
        }
        start = first
        self.xs = xs
        self.ys = ys
    }

    /// Camera centre at `t` (normalised), or nil when there are no cursor events.
    public func center(at t: Double) -> NormPoint? {
        guard !xs.isEmpty else { return nil }
        let f = min(max((t - start) * sampleRate, 0), Double(xs.count - 1))
        let i = Int(f)
        let j = min(i + 1, xs.count - 1)
        let w = Float(f - Double(i))
        return NormPoint(x: Double(xs[i] + (xs[j] - xs[i]) * w), y: Double(ys[i] + (ys[j] - ys[i]) * w))
    }
}
