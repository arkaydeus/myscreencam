import AVFoundation
import Accelerate
import Foundation
import MyScreenArtCore

/// Peak/RMS overview of an audio stream for drawing waveforms, cached in `cache/waveform-<stream>.bin`.
///
/// Level 0 has ``baseBucketsPerSecond`` buckets per second; each further level is ``levelFactor``× coarser,
/// down to a few dozen buckets. Values are quantised to 0…255 (`UInt8`) and returned as 0…1.
///
/// **Time base:** query times are **session (source) seconds**, like every other time in the edit model. The
/// stream file's t=0 sits at ``startOffset`` (from `meta.streams[kind].startOffset`); outside the file the
/// waveform is silent.
public struct Waveform: Sendable, Equatable {
    public static let baseBucketsPerSecond = 200.0
    public static let levelFactor = 4
    /// Levels are added until one has at most this many buckets.
    static let coarsestBucketCount = 64

    public enum WaveformError: Error, Sendable, Equatable {
        case missingStream(StreamKind)
        case noAudioTrack(URL)
        case readFailed(String)
        case corruptCache
    }

    public struct Level: Sendable, Equatable {
        public let bucketsPerSecond: Double
        /// Peak magnitude per bucket, 0…255.
        public let peaks: [UInt8]
        /// RMS per bucket, 0…255.
        public let rms: [UInt8]

        public var bucketCount: Int { peaks.count }
    }

    /// Finest first.
    public let levels: [Level]
    /// Seconds of decoded audio.
    public let duration: Double
    /// Session time of the file's first sample.
    public var startOffset: Double

    init(levels: [Level], duration: Double, startOffset: Double = 0) {
        self.levels = levels
        self.duration = duration
        self.startOffset = startOffset
    }

    // MARK: Loading

    /// Loads the cached waveform for `stream`, or decodes the audio file and writes the cache first. The cache is
    /// rebuilt when the audio file's size or modification date changed, or when it's unreadable.
    public static func load(package: RecordingPackage, stream: StreamKind) async throws -> Waveform {
        let audio = package.url(for: stream)
        guard FileManager.default.fileExists(atPath: audio.path) else { throw WaveformError.missingStream(stream) }
        let stamp = try SourceStamp(of: audio)
        let offset = (try? package.loadMeta().streams[stream]?.startOffset) ?? 0
        let cacheURL = package.url(PackageLayout.waveformCache(for: stream))

        if let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
            let (cached, cachedStamp) = try? decode(data), cachedStamp == stamp
        {
            var waveform = cached
            waveform.startOffset = offset
            return waveform
        }

        var waveform = try await build(contentsOf: audio)
        waveform.startOffset = offset
        do {
            let cacheDirectory = cacheURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: false)
            }
            try waveform.encoded(stamp: stamp).write(to: cacheURL, options: .atomic)
        } catch {
            Log.app.error("Couldn't write waveform cache \(cacheURL.path, privacy: .public): \(error)")
        }
        return waveform
    }

    /// Decodes an audio file (any format AVFoundation reads) to Float32 in chunks and builds the pyramid.
    /// Channels are folded into one waveform without a downmix: a bucket's peak is the loudest sample of any
    /// channel and its RMS is taken over all channels, so out-of-phase or one-sided audio still shows.
    /// Memory is O(duration × 200 buckets/s), independent of the sample rate and file length. Cancellable.
    public static func build(contentsOf url: URL) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WaveformError.noAudioTrack(url)
        }
        let durationHint = try? await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WaveformError.readFailed("Can't read audio track") }
        reader.add(output)
        guard reader.startReading() else {
            throw WaveformError.readFailed(reader.error.map { String(describing: $0) } ?? "startReading failed")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var accumulator: WaveformAccumulator?
        var scratch: [Float] = []
        var buffersRead = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            buffersRead += 1
            if buffersRead % 64 == 0 { try Task.checkCancellation() }
            if accumulator == nil {
                guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                    asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0
                else { continue }
                accumulator = WaveformAccumulator(
                    sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame),
                    expectedDuration: durationHint ?? 0)
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }

            var lengthAtOffset = 0
            var pointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil,
                dataPointerOut: &pointer)
            if status == kCMBlockBufferNoErr, let pointer, lengthAtOffset >= length {
                pointer.withMemoryRebound(to: Float.self, capacity: count) {
                    accumulator!.append(UnsafeBufferPointer(start: $0, count: count))
                }
            } else {
                // Non-contiguous block: copy out.
                if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
                scratch.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                scratch.withUnsafeBufferPointer { accumulator!.append(UnsafeBufferPointer(rebasing: $0[0..<count])) }
            }
        }
        if reader.status == .failed {
            throw WaveformError.readFailed(reader.error.map { String(describing: $0) } ?? "read failed")
        }
        guard var accumulator else { return Waveform(levels: [], duration: 0) }
        return accumulator.finish()
    }

    // MARK: Queries

    /// `count` peak values (0…1) evenly covering session time `from…to`, each the maximum over its span.
    /// Uses the coarsest level that still has at least one bucket per output value; O(count).
    public func peaks(from: Double, to: Double, count: Int) -> [Float] {
        query(from: from, to: to, count: count, rms: false)
    }

    /// Like ``peaks(from:to:count:)`` but RMS (root of the mean square over each span).
    public func rms(from: Double, to: Double, count: Int) -> [Float] {
        query(from: from, to: to, count: count, rms: true)
    }

    /// Index into ``levels`` used for output values `span` seconds wide.
    public func levelIndex(forSpan span: Double) -> Int {
        var index = 0
        for (i, level) in levels.enumerated() where 1 / level.bucketsPerSecond <= span { index = i }
        return index
    }

    private func query(from: Double, to: Double, count: Int, rms: Bool) -> [Float] {
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        guard from.isFinite, to.isFinite, to > from, !levels.isEmpty else { return result }
        let span = (to - from) / Double(count)
        let level = levels[levelIndex(forSpan: span)]
        let values = rms ? level.rms : level.peaks
        let n = values.count
        let rate = level.bucketsPerSecond
        let start = from - startOffset
        guard n > 0 else { return result }

        values.withUnsafeBufferPointer { buffer in
            for i in 0..<count {
                let t0 = (start + Double(i) * span) * rate
                let t1 = (start + Double(i + 1) * span) * rate
                if t1 <= 0 || t0 >= Double(n) { continue }
                let lo = max(0, Int(t0.rounded(.down)))
                let hi = min(n, max(lo + 1, Int(t1.rounded(.up))))
                if rms {
                    var sum: Float = 0
                    for j in lo..<hi {
                        let v = Float(buffer[j])
                        sum += v * v
                    }
                    result[i] = (sum / Float(hi - lo)).squareRoot() / 255
                } else {
                    var peak: UInt8 = 0
                    for j in lo..<hi where buffer[j] > peak { peak = buffer[j] }
                    result[i] = Float(peak) / 255
                }
            }
        }
        return result
    }
}

// MARK: - Building

/// Streams interleaved samples into fixed-rate buckets (peak and mean square), then builds the pyramid.
/// Bucket edges fall on frame boundaries.
struct WaveformAccumulator {
    let sampleRate: Double
    let channels: Int
    let framesPerBucket: Double
    private(set) var sampleIndex = 0
    private var nextBoundary: Int
    private var bucketPeak: Float = 0
    private var bucketSumSquares: Double = 0
    private var bucketCount = 0
    private(set) var peaks: [Float] = []
    private(set) var rms: [Float] = []

    init(sampleRate: Double, channels: Int = 1, expectedDuration: Double = 0) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        framesPerBucket = max(1, sampleRate / Waveform.baseBucketsPerSecond)
        nextBoundary = Int(framesPerBucket.rounded(.down)) * self.channels
        if expectedDuration.isFinite, expectedDuration > 0 {
            let capacity = Int(expectedDuration * Waveform.baseBucketsPerSecond) + 2
            peaks.reserveCapacity(capacity)
            rms.reserveCapacity(capacity)
        }
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard var base = samples.baseAddress else { return }
        var remaining = samples.count
        while remaining > 0 {
            let take = min(remaining, nextBoundary - sampleIndex)
            var peak: Float = 0
            var sumSquares: Float = 0
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(take))
            vDSP_svesq(base, 1, &sumSquares, vDSP_Length(take))
            bucketPeak = max(bucketPeak, peak)
            bucketSumSquares += Double(sumSquares)
            bucketCount += take
            sampleIndex += take
            base += take
            remaining -= take
            if sampleIndex >= nextBoundary { emitBucket() }
        }
    }

    private mutating func emitBucket() {
        peaks.append(bucketPeak)
        rms.append(bucketCount > 0 ? Float((bucketSumSquares / Double(bucketCount)).squareRoot()) : 0)
        bucketPeak = 0
        bucketSumSquares = 0
        bucketCount = 0
        nextBoundary = Int((Double(peaks.count + 1) * framesPerBucket).rounded(.down)) * channels
    }

    /// Flushes the partial last bucket and builds all levels.
    mutating func finish() -> Waveform {
        if bucketCount > 0 { emitBucket() }
        let duration = Double(sampleIndex / channels) / sampleRate
        var levels: [Waveform.Level] = []
        var peaks = self.peaks
        var rms = self.rms
        var rate = Waveform.baseBucketsPerSecond
        while true {
            levels.append(Waveform.Level(bucketsPerSecond: rate, peaks: quantize(peaks, up: true), rms: quantize(rms)))
            guard peaks.count > Waveform.coarsestBucketCount else { break }
            (peaks, rms) = Self.downsample(peaks: peaks, rms: rms, factor: Waveform.levelFactor)
            rate /= Double(Waveform.levelFactor)
        }
        return Waveform(levels: levels, duration: duration)
    }

    /// Groups `factor` buckets: max of peaks, RMS of RMS (a short last group is averaged over its real size).
    static func downsample(peaks: [Float], rms: [Float], factor: Int) -> ([Float], [Float]) {
        let n = peaks.count
        let m = (n + factor - 1) / factor
        guard m > 0 else { return ([], []) }
        let padding = repeatElement(Float(0), count: m * factor - n)
        let paddedPeaks = peaks + padding
        let squares = vDSP.square(rms) + padding

        var outPeaks = [Float](repeating: 0, count: m)
        var outSquares = [Float](repeating: 0, count: m)
        paddedPeaks.withUnsafeBufferPointer { p in
            squares.withUnsafeBufferPointer { s in
                outPeaks.withUnsafeMutableBufferPointer { op in
                    outSquares.withUnsafeMutableBufferPointer { os in
                        let stride = vDSP_Stride(factor)
                        let length = vDSP_Length(m)
                        for k in 0..<factor {
                            vDSP_vmax(p.baseAddress! + k, stride, op.baseAddress!, 1, op.baseAddress!, 1, length)
                            vDSP_vadd(s.baseAddress! + k, stride, os.baseAddress!, 1, os.baseAddress!, 1, length)
                        }
                    }
                }
            }
        }
        outSquares = vDSP.divide(outSquares, Float(factor))
        let lastSize = n - (m - 1) * factor
        if lastSize < factor { outSquares[m - 1] *= Float(factor) / Float(lastSize) }
        return (outPeaks, vForce.sqrt(outSquares))
    }

    /// 0…1 → 0…255. Peaks round up so any non-silent bucket is visible; RMS rounds to nearest.
    private func quantize(_ values: [Float], up: Bool = false) -> [UInt8] {
        guard !values.isEmpty else { return [] }
        var scaled = vDSP.multiply(255, vDSP.clip(values, to: 0...1))
        if up { scaled = vDSP.add(0.999, scaled) }
        var out = [UInt8](repeating: 0, count: values.count)
        vDSP.convertElements(of: scaled, to: &out, rounding: up ? .towardZero : .towardNearestInteger)
        return out
    }
}

// MARK: - Cache file

/// Identifies the audio file a cache was built from.
struct SourceStamp: Equatable {
    var size: UInt64
    var modified: Double

    init(size: UInt64, modified: Double) {
        self.size = size
        self.modified = modified
    }

    init(of url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        size = UInt64(values.fileSize ?? 0)
        modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
    }
}

/// Cache layout (little-endian):
/// ```
/// 0  "MSAW"            magic
/// 4  UInt16 version    (1)
/// 6  UInt16 reserved
/// 8  Float64 base buckets per second
/// 16 Float64 duration (s)
/// 24 UInt64 source size
/// 32 Float64 source modification time (s since 1970)
/// 40 UInt32 level count L
/// 44 UInt32 level factor
/// 48 UInt32 × L bucket counts
///    then per level: peaks [UInt8 × count], rms [UInt8 × count]
/// ```
extension Waveform {
    static let magic: [UInt8] = Array("MSAW".utf8)
    static let formatVersion: UInt16 = 1

    func encoded(stamp: SourceStamp) -> Data {
        var data = Data()
        data.reserveCapacity(48 + levels.reduce(0) { $0 + 4 + 2 * $1.bucketCount })
        data.append(contentsOf: Self.magic)
        data.appendLE(Self.formatVersion)
        data.appendLE(UInt16(0))
        data.appendLE(Self.baseBucketsPerSecond.bitPattern)
        data.appendLE(duration.bitPattern)
        data.appendLE(stamp.size)
        data.appendLE(stamp.modified.bitPattern)
        data.appendLE(UInt32(levels.count))
        data.appendLE(UInt32(Self.levelFactor))
        for level in levels { data.appendLE(UInt32(level.bucketCount)) }
        for level in levels {
            data.append(contentsOf: level.peaks)
            data.append(contentsOf: level.rms)
        }
        return data
    }

    static func decode(_ data: Data) throws -> (Waveform, SourceStamp) {
        var reader = ByteReader(data: data)
        guard try reader.bytes(4) == magic else { throw WaveformError.corruptCache }
        guard try reader.read(UInt16.self) == formatVersion else { throw WaveformError.corruptCache }
        _ = try reader.read(UInt16.self)
        let baseRate = Double(bitPattern: try reader.read(UInt64.self))
        let duration = Double(bitPattern: try reader.read(UInt64.self))
        let size = try reader.read(UInt64.self)
        let modified = Double(bitPattern: try reader.read(UInt64.self))
        let levelCount = Int(try reader.read(UInt32.self))
        let factor = Double(try reader.read(UInt32.self))
        guard baseRate > 0, factor >= 2, levelCount <= 64, duration.isFinite else { throw WaveformError.corruptCache }
        var counts: [Int] = []
        for _ in 0..<levelCount { counts.append(Int(try reader.read(UInt32.self))) }
        var levels: [Level] = []
        var rate = baseRate
        for count in counts {
            let peaks = try reader.bytes(count)
            let rms = try reader.bytes(count)
            levels.append(Level(bucketsPerSecond: rate, peaks: peaks, rms: rms))
            rate /= factor
        }
        guard reader.isAtEnd else { throw WaveformError.corruptCache }
        return (Waveform(levels: levels, duration: duration), SourceStamp(size: size, modified: modified))
    }
}

private struct ByteReader {
    let data: Data
    var offset: Int

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, data.endIndex - offset >= count else { throw Waveform.WaveformError.corruptCache }
        defer { offset += count }
        return [UInt8](data[offset..<offset + count])
    }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard data.endIndex - offset >= size else { throw Waveform.WaveformError.corruptCache }
        defer { offset += size }
        return data[offset..<offset + size].withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }
}

extension Data {
    fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
