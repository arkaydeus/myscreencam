import Foundation
import Synchronization

/// The two audio tracks the editor meters.
public enum AudioTrackKind: String, Sendable, CaseIterable {
    case systemAudio
    case microphone
}

/// One meter reading, linear amplitude (0…1+, 1 = full scale).
public struct AudioLevel: Sendable, Equatable {
    public var rms: Float
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silent = AudioLevel(rms: 0, peak: 0)
}

/// Lock-free level storage written by the audio taps (real-time thread) and read by the UI at ~30 Hz.
///
/// The taps publish each processed block's RMS and fold its peak into a running maximum; `level(for:)` returns the
/// latest RMS and the peak since the previous call, then resets the peak. Use one reader (the meter view).
public final class AudioLevels: Sendable {
    private struct Slot: ~Copyable {
        let rms = Atomic<UInt32>(0)
        let peak = Atomic<UInt32>(0)
        let updates = Atomic<UInt64>(0)
    }

    private let system = Slot()
    private let microphone = Slot()

    public init() {}

    private func withSlot<R>(_ kind: AudioTrackKind, _ body: (borrowing Slot) -> R) -> R {
        switch kind {
        case .systemAudio: body(system)
        case .microphone: body(microphone)
        }
    }

    /// Latest RMS and the peak since the last call (which resets it).
    public func level(for kind: AudioTrackKind) -> AudioLevel {
        withSlot(kind) { slot in
            AudioLevel(
                rms: Float(bitPattern: slot.rms.load(ordering: .relaxed)),
                peak: Float(bitPattern: slot.peak.exchange(0, ordering: .relaxed)))
        }
    }

    /// Number of blocks published for `kind` (lets tests and the UI see that audio is flowing).
    public func updateCount(for kind: AudioTrackKind) -> UInt64 {
        withSlot(kind) { $0.updates.load(ordering: .relaxed) }
    }

    /// Publishes a processed block. Real-time safe (atomics only).
    public func publish(_ kind: AudioTrackKind, rms: Float, peak: Float) {
        withSlot(kind) { slot in
            slot.rms.store(rms.bitPattern, ordering: .relaxed)
            // Non-negative floats order the same as their bit patterns.
            var current = slot.peak.load(ordering: .relaxed)
            while Float(bitPattern: current) < peak {
                let (exchanged, original) = slot.peak.compareExchange(
                    expected: current, desired: peak.bitPattern, ordering: .relaxed)
                if exchanged { break }
                current = original
            }
            slot.updates.add(1, ordering: .relaxed)
        }
    }

    /// Clears both meters (e.g. when playback stops).
    public func reset() {
        for kind in AudioTrackKind.allCases {
            withSlot(kind) { slot in
                slot.rms.store(0, ordering: .relaxed)
                slot.peak.store(0, ordering: .relaxed)
            }
        }
    }
}

/// Meter display behaviour from the legacy audio panel: bar = RMS × 2, peak held 1.5 s then decaying, clip at 0.99.
public struct MeterBallistics: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        /// Bar height 0…1.
        public var level: Float
        /// Peak-hold marker 0…1.
        public var peakHold: Float
        public var isClipping: Bool
    }

    public static let holdDuration = 1.5
    /// Peak marker fall rate after the hold, in full scales per second.
    public static let decayPerSecond: Float = 1.5
    public static let clipThreshold: Float = 0.99

    private var heldPeak: Float = 0
    private var heldAt: Double = -.infinity
    private var lastTime: Double?

    public init() {}

    /// Feeds one reading at time `now` (seconds, any monotonic clock).
    public mutating func update(_ level: AudioLevel, now: Double) -> Reading {
        let peak = min(max(level.peak, 0), 1)
        if let last = lastTime, now - heldAt > Self.holdDuration {
            heldPeak = max(0, heldPeak - Self.decayPerSecond * Float(now - max(last, heldAt + Self.holdDuration)))
        }
        if peak >= heldPeak {
            heldPeak = peak
            heldAt = now
        }
        lastTime = now
        return Reading(
            level: min(1, max(0, level.rms * 2)), peakHold: heldPeak, isClipping: level.peak >= Self.clipThreshold)
    }
}

/// The soft limiter used on every gained track (and available to export for the final mix).
///
/// Identity below `knee`, then a tanh curve that approaches ±1 without a hard corner, so gain above 0 dB and the
/// sum of two tracks never clip harshly.
public enum AudioSoftLimiter {
    public static let knee: Float = 0.8

    @inlinable
    public static func process(_ x: Float) -> Float {
        let a = abs(x)
        if a <= knee { return x }
        let headroom = 1 - knee
        let y = knee + headroom * tanh((a - knee) / headroom)
        return x < 0 ? -y : y
    }

    /// Limits `count` samples in place.
    public static func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { samples[i] = process(samples[i]) }
    }
}
