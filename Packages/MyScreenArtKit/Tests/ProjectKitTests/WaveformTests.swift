import Foundation
import Testing

@testable import ProjectKit

struct WaveformTests {
    /// 2 s of 0.5 sine, 3 s silence, 1 s of 0.25 sine.
    let tone: [(seconds: Double, amplitude: Float)] = [(2, 0.5), (3, 0), (1, 0.25)]

    func makePackage(in dir: TempDirectory, micOffset: Double? = nil) throws -> RecordingPackage {
        var streams: [StreamKind: StreamTiming] = [:]
        if let micOffset { streams[.microphone] = StreamTiming(startOffset: micOffset) }
        let package = try Fixtures.package(in: dir.url, meta: Fixtures.meta(streams: streams))
        try Fixtures.writeTone(to: package.url(for: .microphone), segments: tone)
        return package
    }

    func all(_ values: [Float], within range: ClosedRange<Float>) -> Bool { values.allSatisfy(range.contains) }

    @Test(.timeLimit(.minutes(1)))
    func buildsPeaksAndPyramid() async throws {
        let dir = try TempDirectory()
        let package = try makePackage(in: dir)
        let waveform = try await Waveform.load(package: package, stream: .microphone)

        #expect(abs(waveform.duration - 6) < 0.05)
        #expect(waveform.levels.map(\.bucketsPerSecond) == [200, 50, 12.5, 3.125])
        #expect(abs(waveform.levels[0].bucketCount - 1200) <= 10)
        #expect(waveform.levels[1].bucketCount == (waveform.levels[0].bucketCount + 3) / 4)

        let loud = waveform.peaks(from: 0.2, to: 1.8, count: 16)
        #expect(all(loud, within: 0.45...0.56), "\(loud)")
        let silent = waveform.peaks(from: 2.3, to: 4.7, count: 24)
        #expect(all(silent, within: 0...0.02), "\(silent)")
        let quiet = waveform.peaks(from: 5.2, to: 5.8, count: 6)
        #expect(all(quiet, within: 0.2...0.3), "\(quiet)")
        let rms = waveform.rms(from: 0.2, to: 1.8, count: 8)
        #expect(all(rms, within: 0.32...0.39), "\(rms)")  // 0.5 / √2 ≈ 0.354

        // Coarse query uses a coarse level.
        #expect(waveform.levelIndex(forSpan: 1) == 3)
        #expect(waveform.levelIndex(forSpan: 0.001) == 0)
        let overview = waveform.peaks(from: 0, to: 6, count: 6)
        #expect(overview[0] > 0.45 && overview[1] > 0.45)
        #expect(overview[3] < 0.02)
        #expect(overview[5] > 0.2 && overview[5] < 0.3)

        // Outside the audio: silent; degenerate queries are safe.
        #expect(waveform.peaks(from: 7, to: 9, count: 4) == [0, 0, 0, 0])
        #expect(waveform.peaks(from: 1, to: 1, count: 3) == [0, 0, 0])
        #expect(waveform.peaks(from: 0, to: 1, count: 0).isEmpty)
        #expect(waveform.peaks(from: -.infinity, to: .nan, count: 2) == [0, 0])
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheIsReusedAndRebuiltWhenStale() async throws {
        let dir = try TempDirectory()
        let package = try makePackage(in: dir)
        let cache = package.url(PackageLayout.waveformCache(for: .microphone))
        let first = try await Waveform.load(package: package, stream: .microphone)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        let size = try #require(try cache.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size < 64 + 2 * 1700)  // header + counts + UInt8 peaks/RMS for ~1600 buckets
        let written = try Data(contentsOf: cache)

        let second = try await Waveform.load(package: package, stream: .microphone)
        #expect(second == first)
        #expect(try Data(contentsOf: cache) == written)

        // Corrupt cache → rebuilt, same result.
        try Data("garbage".utf8).write(to: cache)
        #expect(try await Waveform.load(package: package, stream: .microphone) == first)
        #expect(try Data(contentsOf: cache) == written)

        // Audio file changed → rebuilt.
        try Fixtures.writeTone(to: package.url(for: .microphone), segments: [(1, 0.8)])
        let rebuilt = try await Waveform.load(package: package, stream: .microphone)
        #expect(abs(rebuilt.duration - 1) < 0.05)
        #expect(try Data(contentsOf: cache) != written)
    }

    @Test(.timeLimit(.minutes(1)))
    func queriesAreInSessionTime() async throws {
        let dir = try TempDirectory()
        let package = try makePackage(in: dir, micOffset: 1)
        let waveform = try await Waveform.load(package: package, stream: .microphone)
        #expect(waveform.startOffset == 1)
        #expect(waveform.peaks(from: 0, to: 0.95, count: 5) == [0, 0, 0, 0, 0])
        #expect(all(waveform.peaks(from: 1.2, to: 2.8, count: 8), within: 0.45...0.56))
    }

    @Test(.timeLimit(.minutes(1)))
    func stereo44kHz() async throws {
        let dir = try TempDirectory()
        let url = dir.url.appending(path: "stereo.m4a")
        try Fixtures.writeTone(to: url, segments: [(2, 0.6)], sampleRate: 44_100, channels: 2)
        let waveform = try await Waveform.build(contentsOf: url)
        #expect(abs(waveform.levels[0].bucketCount - 400) <= 10)
        #expect(all(waveform.peaks(from: 0.2, to: 1.8, count: 8), within: 0.55...0.66))
    }

    @Test func missingStreamThrows() async throws {
        let dir = try TempDirectory()
        let package = try Fixtures.package(in: dir.url, meta: Fixtures.meta())
        await #expect(throws: Waveform.WaveformError.missingStream(.systemAudio)) {
            try await Waveform.load(package: package, stream: .systemAudio)
        }
    }

    @Test func downsampleTakesMaxPeakAndTrueRMS() {
        let (peaks, rms) = WaveformAccumulator.downsample(
            peaks: [0.1, 0.5, 0.2, 0.3, 0.9], rms: [1, 1, 1, 1, 0.5], factor: 4)
        #expect(peaks == [0.5, 0.9])
        #expect(approx(rms.map(Double.init), [1, 0.5], tolerance: 1e-6))
    }

    @Test func accumulatorTakesLoudestChannel() {
        // Stereo, 48 kHz: left silent, right ±0.4 (a mono downmix would halve or cancel it).
        var accumulator = WaveformAccumulator(sampleRate: 48_000, channels: 2)
        var samples = [Float](repeating: 0, count: 2 * 4_800)
        for frame in 0..<4_800 { samples[2 * frame + 1] = frame.isMultiple(of: 2) ? 0.4 : -0.4 }
        samples.withUnsafeBufferPointer { accumulator.append($0) }
        let waveform = accumulator.finish()
        #expect(waveform.levels[0].bucketCount == 20)
        #expect(approx(waveform.duration, 0.1))
        #expect(all(waveform.peaks(from: 0, to: 0.1, count: 10), within: 0.4...0.41))
        #expect(all(waveform.rms(from: 0, to: 0.1, count: 10), within: 0.27...0.3))  // √(0.16 / 2) ≈ 0.283
    }

    @Test func accumulatorHandlesFractionalBucketSizes() {
        var accumulator = WaveformAccumulator(sampleRate: 44_100)  // 220.5 samples per bucket
        let samples = [Float](repeating: 0.5, count: 44_100)
        samples.withUnsafeBufferPointer { accumulator.append($0) }
        let waveform = accumulator.finish()
        #expect(waveform.levels[0].bucketCount == 200)
        #expect(waveform.duration == 1)
    }

    /// One hour at 48 kHz, fed in chunks: bucket counts, levels and cache size stay small.
    @Test(.timeLimit(.minutes(2)))
    func oneHourStaysCompact() throws {
        var accumulator = WaveformAccumulator(sampleRate: 48_000, expectedDuration: 3600)
        let chunk = [Float](repeating: 0.3, count: 4800)
        chunk.withUnsafeBufferPointer { buffer in
            for _ in 0..<36_000 { accumulator.append(buffer) }
        }
        let waveform = accumulator.finish()
        #expect(waveform.duration == 3600)
        #expect(waveform.levels.map(\.bucketCount) == [720_000, 180_000, 45_000, 11_250, 2_813, 704, 176, 44])
        let encoded = waveform.encoded(stamp: SourceStamp(size: 1, modified: 2))
        #expect(encoded.count < 2_000_000)

        let (decoded, stamp) = try Waveform.decode(encoded)
        #expect(decoded == waveform)
        #expect(stamp == SourceStamp(size: 1, modified: 2))
        #expect(throws: Waveform.WaveformError.corruptCache) { try Waveform.decode(encoded.dropLast()) }

        let overview = waveform.peaks(from: 0, to: 3600, count: 1000)
        #expect(overview.count == 1000)
        #expect(all(overview, within: 0.29...0.31))
        #expect(waveform.levelIndex(forSpan: 3.6) == 4)  // 1.28 s buckets
    }
}
