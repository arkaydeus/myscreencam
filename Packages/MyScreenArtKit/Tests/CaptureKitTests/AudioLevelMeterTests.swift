import Foundation
import Testing

@testable import CaptureKit

struct AudioLevelMeterTests {
    @Test func sineWaveReadsExpectedRMSAndPeak() throws {
        var meter = AudioLevelMeter(sampleRate: 48_000, updateRate: 30)
        let amplitude: Float = 0.5
        // Stereo interleaved 1 kHz sine, 10 ms buffers.
        var readings: [AudioLevel] = []
        var phase = 0
        for _ in 0..<20 {
            var samples = [Float](repeating: 0, count: 480 * 2)
            for frame in 0..<480 {
                let value = amplitude * sin(2 * .pi * 1000 * Float(phase) / 48_000)
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
                phase += 1
            }
            if let reading = samples.withUnsafeBufferPointer({ meter.process($0, channels: 2) }) {
                readings.append(reading)
            }
        }
        // 200 ms of audio at 30 Hz → 6 readings (each covers ≥ 1600 frames).
        #expect(readings.count == 5 || readings.count == 6)
        let reading = try #require(readings.last)
        #expect(abs(reading.rms - amplitude / Float(2).squareRoot()) < 0.01)
        #expect(abs(reading.peak - amplitude) < 0.01)
    }

    @Test func silenceIsZero() throws {
        var meter = AudioLevelMeter(sampleRate: 48_000, updateRate: 100)
        let samples = [Float](repeating: 0, count: 480)
        let reading = try #require(samples.withUnsafeBufferPointer { meter.process($0, channels: 1) })
        #expect(reading == .silence)
    }

    @Test func peakIsClampedToFullScale() throws {
        var meter = AudioLevelMeter(sampleRate: 100, updateRate: 100)
        let reading = try #require([Float(-1.7)].withUnsafeBufferPointer { meter.process($0, channels: 1) })
        #expect(reading.peak == 1)
    }
}
