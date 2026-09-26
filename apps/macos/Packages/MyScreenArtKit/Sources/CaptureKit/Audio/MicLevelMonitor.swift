import CoreMedia
import Foundation

/// Live microphone level for the recorder's meter (before recording). Readings arrive at ~30 Hz; drive a
/// `CALayer` with them rather than SwiftUI state.
///
/// ```swift
/// let monitor = try MicLevelMonitor(deviceID: mic.id)
/// for await level in await monitor.start() { meterLayer.update(level) }
/// ```
public final class MicLevelMonitor: @unchecked Sendable {
    private let capture: MicrophoneCapture
    private let updateRate: Double
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioLevel>.Continuation?

    /// Opens the microphone (`nil` = system default). Needs microphone permission.
    public init(deviceID: String?, updateRate: Double = 30) throws {
        capture = try MicrophoneCapture(deviceID: deviceID, format: .float32)
        self.updateRate = updateRate
    }

    /// Starts metering. The stream finishes when ``stop()`` is called.
    public func start() async -> AsyncStream<AudioLevel> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioLevel.self, bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            self.continuation?.finish()
            self.continuation = continuation
        }
        let meter = MeterState(updateRate: updateRate)
        await capture.start { sampleBuffer in
            if let level = meter.process(sampleBuffer) { continuation.yield(level) }
        }
        return stream
    }

    public func stop() async {
        await capture.stop()
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}

/// Meter state confined to the microphone output queue.
private final class MeterState: @unchecked Sendable {
    private let updateRate: Double
    private var meter: AudioLevelMeter?

    init(updateRate: Double) {
        self.updateRate = updateRate
    }

    func process(_ sampleBuffer: CMSampleBuffer) -> AudioLevel? {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32
        else { return nil }
        if meter?.sampleRate != format.mSampleRate {
            meter = AudioLevelMeter(sampleRate: format.mSampleRate, updateRate: updateRate)
        }
        var reading: AudioLevel?
        try? sampleBuffer.withAudioBufferList { list, _ in
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
                if let level = meter?.process(samples, channels: Int(buffer.mNumberChannels)) { reading = level }
            }
        }
        return reading
    }
}
