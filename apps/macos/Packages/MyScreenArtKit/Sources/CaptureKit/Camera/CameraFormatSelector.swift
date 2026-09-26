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
}
