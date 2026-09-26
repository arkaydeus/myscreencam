import Accelerate

/// A level reading, linear amplitude 0…1 (full scale = 1).
public struct AudioLevel: Sendable, Equatable {
    public var rms: Float
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silence = AudioLevel(rms: 0, peak: 0)
}

/// Accumulates Float32 PCM into RMS + peak readings at a fixed rate (default ~30 Hz). Uses vDSP, so a
/// 10 ms buffer costs well under a microsecond.
public struct AudioLevelMeter: Sendable {
    public let sampleRate: Double
    public let updateRate: Double
    private var sumOfSquares: Float = 0
    private var peak: Float = 0
    private var frames = 0

    public init(sampleRate: Double, updateRate: Double = 30) {
        self.sampleRate = sampleRate
        self.updateRate = updateRate
    }

    private var framesPerReading: Int { max(1, Int(sampleRate / updateRate)) }

    /// Adds interleaved samples (`channels` per frame). Returns a reading each time a window completes.
    public mutating func process(_ samples: UnsafeBufferPointer<Float>, channels: Int) -> AudioLevel? {
        guard let base = samples.baseAddress, !samples.isEmpty else { return nil }
        let count = vDSP_Length(samples.count)
        var squares: Float = 0
        var maxMagnitude: Float = 0
        vDSP_svesq(base, 1, &squares, count)
        vDSP_maxmgv(base, 1, &maxMagnitude, count)
        sumOfSquares += squares
        peak = max(peak, maxMagnitude)
        frames += samples.count / max(1, channels)
        guard frames >= framesPerReading else { return nil }
        let reading = AudioLevel(
            rms: (sumOfSquares / Float(frames * max(1, channels))).squareRoot(), peak: min(peak, 1))
        sumOfSquares = 0
        peak = 0
        frames = 0
        return reading
    }
}
