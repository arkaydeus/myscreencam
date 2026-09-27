@preconcurrency import AVFoundation
import Foundation
import MyScreenArtCore
import ProjectKit

/// Speech-model input prepared from one recorded track: 16 kHz mono Float32 in a disk-backed raw file
/// (`<key>.f32`, little-endian, no header) plus this descriptor (`<key>.json`).
///
/// Time map: prepared sample `i` sits at session time `(originSample + i) / 16 000` — exact, in the 16 kHz
/// timescale. Gaps inside the source file are filled with silence so the map stays one contiguous piece; the
/// number of filled gaps is recorded.
public struct PreparedAudio: Codable, Sendable, Hashable {
    public static let sampleRate: Int32 = 16_000
    public static let sampleFileExtension = "f32"
    /// Decoder + downmix + resampler recipe. Bump when any of them changes: it's part of every cache key.
    public static let recipe = "avassetreader-float32-16k/midside-block-v1"

    public var identity: String
    public var sourceMediaID: String
    public var stream: StreamKind
    public var sourceChannelCount: Int
    public var sourceSampleRate: Double
    /// Session-timeline position of prepared sample 0, in 16 kHz samples.
    public var originSample: Int64
    public var sampleCount: Int64
    /// Silence inserted for gaps between decoded buffers.
    public var filledGaps: Int
    public var recipe: String
    public var samplesFileName: String

    public var duration: Double { Double(sampleCount) / Double(Self.sampleRate) }

    /// Session time of a prepared sample index.
    public func sourceTime(sample: Int64) -> MediaTime {
        MediaTime(value: originSample + sample, timescale: Self.sampleRate)
    }

    /// Session range of prepared samples `range`, clamped to the valid samples (padding never becomes time).
    public func sourceRange(_ range: SampleRange) -> MediaRange {
        let start = min(max(range.start, 0), sampleCount)
        let end = min(max(range.end, start), sampleCount)
        return MediaRange(start: sourceTime(sample: start), end: sourceTime(sample: end))
    }
}

public enum AudioPreparationError: Error, Sendable, Equatable {
    case noAudioTrack
    case readerFailed(String)
    case cancelled
}

/// Reads prepared samples from disk (memory-mapped; windows are copied out on demand).
public struct PreparedSamples: Sendable {
    public let url: URL
    public let count: Int64
    private let data: Data

    public init(url: URL) throws {
        self.url = url
        data = try Data(contentsOf: url, options: .alwaysMapped)
        count = Int64(data.count / MemoryLayout<Float>.size)
    }

    /// Samples in `range` (clamped); zero-padded to at least `minimumCount`.
    public func read(_ range: SampleRange, minimumCount: Int = 0) -> [Float] {
        let start = Int(min(max(range.start, 0), count))
        let end = Int(min(max(range.end, Int64(start)), count))
        var out = [Float](repeating: 0, count: max(end - start, minimumCount))
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<(end - start) { out[i] = floats[start + i] }
        }
        return out
    }

    /// RMS energy of consecutive `frame`-sample frames (for choosing window cuts).
    public func frameEnergies(frame: Int) -> [Float] {
        guard frame > 0 else { return [] }
        let n = Int(count) / frame + (Int(count) % frame == 0 ? 0 : 1)
        var energies = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for f in 0..<n {
                let lo = f * frame
                let hi = min(lo + frame, Int(count))
                var sum: Float = 0
                for i in lo..<hi { sum += floats[i] * floats[i] }
                energies[f] = (sum / Float(max(1, hi - lo))).squareRoot()
            }
        }
        return energies
    }
}

public enum AudioPreparation {
    /// The prepared-audio cache key: source identity (recording id, stream, file size and modification date),
    /// the stream's session offset and the recipe. A replaced file at the same path gets a new key.
    public static func key(package: RecordingPackage, meta: RecordingMeta, stream: StreamKind) -> String {
        let file = package.url(for: stream)
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Fingerprint.of(strings: [
            meta.id.uuidString, stream.rawValue, String(values?.fileSize ?? -1),
            String(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1),
            String(meta.streams[stream]?.startOffset ?? 0), PreparedAudio.recipe,
        ])
    }

    /// Decodes `stream` of `package` into `directory/<key>.f32` (+ `.json`), reusing a previous preparation with
    /// the same key. `progress` receives the fraction of source duration decoded. Checks `Task.isCancelled`
    /// between buffers.
    public static func prepare(
        package: RecordingPackage, meta: RecordingMeta, stream: StreamKind, directory: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PreparedAudio {
        let key = key(package: package, meta: meta, stream: stream)
        let descriptorURL = directory.appending(path: "\(key).json")
        let samplesURL = directory.appending(path: "\(key).\(PreparedAudio.sampleFileExtension)")
        if let data = try? Data(contentsOf: descriptorURL),
            let existing = try? JSONDecoder().decode(PreparedAudio.self, from: data),
            let size = try? samplesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            Int64(size) == existing.sampleCount * 4
        {
            return existing
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: "\(key).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        let decoded = try await decode(
            file: package.url(for: stream), to: partial, durationHint: meta.duration, progress: progress)
        let offset = meta.streams[stream]?.startOffset ?? 0
        let prepared = PreparedAudio(
            identity: key, sourceMediaID: meta.id.uuidString, stream: stream,
            sourceChannelCount: decoded.channels, sourceSampleRate: decoded.sampleRate,
            originSample: Int64(((offset + decoded.firstTime) * Double(PreparedAudio.sampleRate)).rounded()),
            sampleCount: decoded.samples, filledGaps: decoded.gaps, recipe: PreparedAudio.recipe,
            samplesFileName: samplesURL.lastPathComponent)
        _ = try? FileManager.default.removeItem(at: samplesURL)
        try FileManager.default.moveItem(at: partial, to: samplesURL)
        try JSONEncoder().encode(prepared).write(to: descriptorURL, options: .atomic)
        return prepared
    }

    struct Decoded {
        var channels: Int
        var sampleRate: Double
        /// Presentation time of the first decoded sample in the file (seconds).
        var firstTime: Double
        var samples: Int64
        var gaps: Int
    }

    /// Block length for the mid/side decision (0.25 s at 16 kHz).
    static let downmixBlock = 4_000

    /// Decodes and resamples to 16 kHz with AVAssetReader (which applies the file's edit list and codec priming and
    /// keeps presentation timestamps through its resampler), downmixes, and streams Float32 to `url`.
    static func decode(
        file: URL, to url: URL, durationHint: Double, progress: (@Sendable (Double) -> Void)?
    ) async throws -> Decoded {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioPreparationError.noAudioTrack
        }
        let descriptions = try await track.load(.formatDescriptions)
        let asbd = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = max(1, Int(asbd?.mChannelsPerFrame ?? 1))
        let rate = asbd?.mSampleRate ?? 48_000
        guard rate > 0 else { throw AudioPreparationError.readerFailed("Unknown sample rate") }

        let reader = try AVAssetReader(asset: asset)
        let sr = Double(PreparedAudio.sampleRate)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: sr,
                AVNumberOfChannelsKey: channels,
            ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AudioPreparationError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var firstTime: Double?
        var written: Int64 = 0
        var gaps = 0

        func write(_ samples: [Float]) throws {
            guard !samples.isEmpty else { return }
            try samples.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
            written += Int64(samples.count)
        }

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw AudioPreparationError.cancelled
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let ptsSeconds = pts.isValid ? pts.seconds : Double(written) / sr
            if firstTime == nil { firstTime = ptsSeconds }
            // Position of this buffer in output samples relative to the first one.
            let position = Int64(((ptsSeconds - (firstTime ?? 0)) * sr).rounded())
            var skip = 0
            if position > written + Int64(sr / 100) {
                // A gap: keep the time map contiguous with silence.
                try write([Float](repeating: 0, count: Int(position - written)))
                gaps += 1
            } else if position < written - Int64(sr / 100) {
                // Overlap: drop what's already written.
                skip = Int(min(Int64(frames), written - position))
            }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard
                CMBlockBufferGetDataPointer(
                    block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                    == kCMBlockBufferNoErr, let pointer
            else { continue }
            let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: length / 4)
            let usable = min(frames, length / 4 / channels)
            if skip < usable { try write(downmix(floats, frames: usable, channels: channels, skip: skip)) }
            if durationHint > 0 { progress?(min(1, Double(written) / sr / durationHint)) }
        }
        if reader.status == .failed {
            throw AudioPreparationError.readerFailed(reader.error?.localizedDescription ?? "Reader failed")
        }
        return Decoded(channels: channels, sampleRate: rate, firstTime: firstTime ?? 0, samples: written, gaps: gaps)
    }

    /// Mono from interleaved frames. Mono passes through; otherwise, per block, the mid signal `(L+R)/2` unless the
    /// side signal `(L−R)/2` of the first two channels carries clearly more energy (phase-inverted channels, where
    /// averaging would cancel the speech). Extra channels beyond two are averaged into mid.
    static func downmix(_ interleaved: UnsafePointer<Float>, frames: Int, channels: Int, skip: Int = 0) -> [Float] {
        let count = frames - skip
        guard count > 0 else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: interleaved + skip, count: count)) }
        var out = [Float](repeating: 0, count: count)
        var blockStart = 0
        while blockStart < count {
            let blockEnd = min(blockStart + downmixBlock, count)
            var midEnergy: Float = 0
            var sideEnergy: Float = 0
            for i in blockStart..<blockEnd {
                let base = (i + skip) * channels
                let l = interleaved[base]
                let r = interleaved[base + 1]
                let mid = (l + r) / 2
                let side = (l - r) / 2
                midEnergy += mid * mid
                sideEnergy += side * side
            }
            let useSide = sideEnergy > 4 * midEnergy
            for i in blockStart..<blockEnd {
                let base = (i + skip) * channels
                if useSide {
                    out[i] = (interleaved[base] - interleaved[base + 1]) / 2
                } else {
                    var sum: Float = 0
                    for c in 0..<channels { sum += interleaved[base + c] }
                    out[i] = sum / Float(channels)
                }
            }
            blockStart = blockEnd
        }
        return out
    }
}
