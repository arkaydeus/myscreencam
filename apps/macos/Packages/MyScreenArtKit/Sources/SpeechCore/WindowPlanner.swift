import Foundation

/// How a recogniser's outer work units are cut. These are app defaults, not model limits.
public struct WindowPolicy: Codable, Sendable, Hashable {
    /// Cuts are searched between `minimum` and `maximum` seconds into the window, in the quietest 200 ms stretch.
    public var minimum: Double
    public var maximum: Double
    /// No window may exceed this (a final short remainder is merged into its neighbour only within it).
    public var hardCap: Double
    /// Extra audio read on each side (results outside the owned span are discarded).
    public var context: Double
    /// A final window shorter than this is merged into the previous one when the cap allows.
    public var minimumFinal: Double

    public init(minimum: Double, maximum: Double, hardCap: Double, context: Double, minimumFinal: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.hardCap = hardCap
        self.context = context
        self.minimumFinal = minimumFinal
    }

    /// Parakeet: ~60–120 s units (FluidAudio handles its own 15 s internal windows inside), with a little context
    /// so a word at the cut isn't clipped; each word belongs to the unit that owns its start.
    public static let parakeet = WindowPolicy(minimum: 60, maximum: 120, hardCap: 150, context: 0.5, minimumFinal: 10)
    /// Qwen: 20–30 s windows cut near silence, 60 s hard cap, no overlap (text-only output can't resolve
    /// overlapping hypotheses without inventing timing).
    public static let qwen = WindowPolicy(minimum: 20, maximum: 30, hardCap: 60, context: 0, minimumFinal: 4)
    /// A retry of a failed/truncated Qwen window uses shorter windows.
    public static let qwenRetry = WindowPolicy(minimum: 8, maximum: 14, hardCap: 20, context: 0, minimumFinal: 2)
}

public enum WindowPlanner {
    public static let frameSamples = Int(PreparedAudio.sampleRate) / 50  // 20 ms

    /// Plans windows over `range` of the prepared audio. `energies` are RMS values of consecutive 20 ms frames
    /// of the whole file (``PreparedSamples/frameEnergies(frame:)``). Low energy only chooses **where** to cut;
    /// quiet audio is never skipped.
    public static func plan(
        range: SampleRange, energies: [Float], policy: WindowPolicy, firstIndex: Int = 0, totalSamples: Int64? = nil
    ) -> [WorkWindow] {
        let sr = Double(PreparedAudio.sampleRate)
        let total = totalSamples ?? range.end
        let minimum = Int64(policy.minimum * sr)
        let maximum = Int64(policy.maximum * sr)
        var owned: [SampleRange] = []
        var position = range.start
        while range.end - position > maximum {
            let lo = position + minimum
            let hi = position + maximum
            let cut = quietestFrameBoundary(from: lo, to: hi, energies: energies, preferNear: (lo + hi) / 2)
            owned.append(SampleRange(start: position, end: cut))
            position = cut
        }
        if position < range.end { owned.append(SampleRange(start: position, end: range.end)) }
        // Merge a short tail into its neighbour when that stays within the hard cap.
        if owned.count >= 2, let last = owned.last, Double(last.count) / sr < policy.minimumFinal,
            Double(last.end - owned[owned.count - 2].start) / sr <= policy.hardCap
        {
            owned[owned.count - 2].end = last.end
            owned.removeLast()
        }
        let context = Int64(policy.context * sr)
        return owned.enumerated().map { i, r in
            WorkWindow(
                index: firstIndex + i, owned: r,
                read: SampleRange(start: max(0, r.start - context), end: min(total, r.end + context)))
        }
    }

    /// Frames averaged when judging quiet: 200 ms, so a cut lands inside a pause rather than a gap between syllables.
    static let quietSpan = 10

    /// Sample index at the centre of the quietest `quietSpan`-frame stretch between `from` and `to`
    /// (ties → nearest `preferNear`).
    static func quietestFrameBoundary(from: Int64, to: Int64, energies: [Float], preferNear: Int64) -> Int64 {
        let f = Int64(frameSamples)
        let first = Int(from / f)
        let last = min(Int(to / f), energies.count - 1)
        guard first <= last else { return min(max(preferNear, from), to) }
        let half = quietSpan / 2
        func smoothed(_ i: Int) -> Float {
            let lo = max(0, i - half)
            let hi = min(energies.count - 1, i + half - 1)
            var sum: Float = 0
            for j in lo...hi { sum += energies[j] }
            return sum / Float(hi - lo + 1)
        }
        var best = first
        var bestEnergy = smoothed(first)
        for i in first...last {
            let e = smoothed(i)
            if e < bestEnergy || (e == bestEnergy && abs(Int64(i) * f - preferNear) < abs(Int64(best) * f - preferNear))
            {
                best = i
                bestEnergy = e
            }
        }
        return min(max(Int64(best) * f + f / 2, from), to)
    }
}
