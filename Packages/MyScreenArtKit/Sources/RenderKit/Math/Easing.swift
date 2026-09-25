import Foundation

/// Easing curves shared by preview and export. There is exactly one implementation of each curve.
public enum Easing {
    /// `p < 0.5 ? 4p³ : 1 − (−2p + 2)³ / 2`, with `p` clamped to 0…1.
    public static func easeInOutCubic(_ p: Double) -> Double {
        let p = min(max(p, 0), 1)
        if p < 0.5 { return 4 * p * p * p }
        let q = -2 * p + 2
        return 1 - q * q * q / 2
    }

    /// Linear interpolation `a + (b − a)·t`.
    @inlinable
    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// Steps a critically damped spring towards a fixed target over `dt` seconds.
///
/// This is the closed-form solution for a constant target, so it is stable for any `dt` and never overshoots a
/// step input when starting from rest.
struct CriticallyDampedSpring {
    /// Angular frequency in rad/s. Higher is snappier; the time constant is `1 / omega`.
    var omega: Double

    func step(position x: inout Double, velocity v: inout Double, target: Double, dt: Double) {
        let delta = x - target
        let decay = exp(-omega * dt)
        let temp = (v + omega * delta) * dt
        v = (v - omega * temp) * decay
        x = target + (delta + temp) * decay
    }
}
