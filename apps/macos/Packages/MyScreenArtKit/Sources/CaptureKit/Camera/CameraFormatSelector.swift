import CoreMedia

/// A camera format candidate, reduced to what matters for choosing one.
public struct CameraFormatCandidate: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var maxFrameRate: Double

    public init(width: Int, height: Int, maxFrameRate: Double) {
        self.width = width
        self.height = height
        self.maxFrameRate = maxFrameRate
    }
}

/// Picks the camera format closest to a requested size and frame rate.
public enum CameraFormatSelector {
    /// Index of the best candidate: formats that reach `frameRate` win over ones that don't; then the closest
    /// aspect ratio; then the smallest pixel-count difference (ties prefer the larger format).
    public static func bestIndex(
        of candidates: [CameraFormatCandidate], width: Int, height: Int, frameRate: Double
    ) -> Int? {
        let targetAspect = Double(width) / Double(max(height, 1))
        let targetArea = Double(width * height)
        return candidates.indices.min { lhs, rhs in
            key(candidates[lhs]) < key(candidates[rhs])
        }

        func key(_ c: CameraFormatCandidate) -> (Int, Double, Double, Double) {
            let reachesRate = c.maxFrameRate + 0.01 >= frameRate ? 0 : 1
            let aspect = Double(c.width) / Double(max(c.height, 1))
            let aspectError = (abs(aspect - targetAspect) * 100).rounded() / 100
            let areaError = abs(Double(c.width * c.height) - targetArea)
            return (reachesRate, aspectError, areaError, -Double(c.width * c.height))
        }
    }

    /// The frame duration to lock for `frameRate`, always within one of `ranges`. AVFoundation raises an
    /// Objective-C exception (which crashes the app) for a duration outside every supported range, and UVC
    /// cameras often report discrete rates such as 30.00003 fps (1000000/30000030), so an exact `1/30` is
    /// rejected. Uses a range containing `frameRate` when there is one, else the fastest range slower than it,
    /// else the slowest range. Nil when there are no ranges or `frameRate` isn't positive.
    public static func frameDuration(for frameRate: Int, in ranges: [CameraFrameDurationRange]) -> CMTime? {
        guard frameRate > 0 else { return nil }
        let target = Double(frameRate)
        let tolerance = 0.01
        if let range = ranges.filter({
            $0.maxRate + tolerance >= target && $0.minRate - tolerance <= target
        }).max(by: { $0.maxRate < $1.maxRate }) {
            let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            if CMTimeCompare(duration, range.min) <= 0 { return range.min }
            if CMTimeCompare(duration, range.max) >= 0 { return range.max }
            return duration
        }
        if let slower = ranges.filter({ $0.maxRate < target }).max(by: { $0.maxRate < $1.maxRate }) {
            return slower.min
        }
        return ranges.min(by: { $0.minRate < $1.minRate })?.max
    }
}

/// A supported frame-rate range as the frame durations AVFoundation accepts (`AVFrameRateRange`).
public struct CameraFrameDurationRange: Sendable, Equatable {
    /// The shortest frame duration (the fastest rate).
    public var min: CMTime
    /// The longest frame duration (the slowest rate).
    public var max: CMTime

    public init(min: CMTime, max: CMTime) {
        self.min = min
        self.max = max
    }

    var maxRate: Double { 1 / min.seconds }
    var minRate: Double { 1 / max.seconds }
}
