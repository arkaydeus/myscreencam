import AVFoundation
import CaptureKit
import CoreMedia
import CoreVideo
import Foundation
import ProjectKit
import Testing

@testable import RecordingKit

/// Capture-like buffers without TCC: IOSurface-backed `420v` pixel buffers from a pool (what ScreenCaptureKit
/// and AVCapture deliver) and Float32 PCM, stamped with host-clock times.
final class SyntheticVideo {
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool
    private var frameIndex = 0

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        self.pool = try #require(pool)
    }

    /// A frame at `hostTime` seconds. Content is a moving luma ramp (filled here only because it's a test; the
    /// recording path never locks pixel buffers).
    func frame(at hostTime: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        let buffer = try #require(pixelBuffer)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        fill(buffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: HostClock.time(seconds: hostTime), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: try #require(format), sampleTiming: &timing,
            sampleBufferOut: &sample)
        return try #require(sample)
    }

    private func fill(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        frameIndex += 1
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<rows {
                memset(
                    bytes + row * bytesPerRow, plane == 0 ? Int32((row + frameIndex * 7) % 220 + 16) : 128, bytesPerRow)
            }
        }
    }
}

enum SyntheticAudio {
    /// `frames` of interleaved Float32 PCM (a 440 Hz tone) at `hostTime`.
    static func buffer(at hostTime: Double, frames: Int = 1024, channels: Int = 2, sampleRate: Double = 48_000)
        throws -> CMSampleBuffer
    {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        let byteCount = frames * channels * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let blockBuffer = try #require(block)
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = 0.3 * sin(2 * Float.pi * 440 * Float(frame) / Float(sampleRate))
            for channel in 0..<channels { samples[frame * channels + channel] = value }
        }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: try #require(format), sampleCount: frames,
            presentationTimeStamp: HostClock.time(seconds: hostTime), packetDescriptions: nil,
            sampleBufferOut: &sample)
        return try #require(sample)
    }
}

enum TestPackages {
    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "recordingkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func configuration(
        in root: URL, width: Int, height: Int, codec: VideoCodec = .hevc, systemAudio: Bool = false,
        microphone: Bool = false, events: Bool = false
    ) throws -> RecordingPipelineConfiguration {
        let id = UUID()
        let createdAt = Date()
        return RecordingPipelineConfiguration(
            package: try RecordingPackage.create(in: root, date: createdAt, id: id), id: id,
            name: RecordingOptions.defaultName(for: createdAt), createdAt: createdAt,
            source: .region(displayID: 1, x: 10, y: 20, width: Double(width), height: Double(height)),
            screen: ScreenStreamInfo(
                pixelWidth: width, pixelHeight: height, scale: 1, frameRate: 60, codec: codec.fourCC,
                contentRectPoints: RectPoints(x: 10, y: 20, width: Double(width), height: Double(height))),
            microphone: microphone ? AudioDeviceInfo(deviceID: "test-mic", name: "Test Mic") : nil,
            capturesSystemAudio: systemAudio, systemCursorHidden: true, codec: codec, recordsEvents: events,
            appVersion: "test")
    }
}

/// Top-level ISO BMFF box types in a file (to check fragmentation).
func topLevelBoxes(of url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    var boxes: [String] = []
    var offset = 0
    while offset + 8 <= data.count {
        var size = Int(data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt64($1) })
        let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
        if size == 1, offset + 16 <= data.count {
            size = Int(data[offset + 8..<offset + 16].reduce(0) { $0 << 8 | UInt64($1) })
        } else if size == 0 {
            size = data.count - offset
        }
        boxes.append(type)
        guard size >= 8 else { break }
        offset += size
    }
    return boxes
}

/// Presentation times (seconds, file time base) of every sample in a track, in decode order.
func samplePresentationTimes(of track: AVAssetTrack, in asset: AVAsset) throws -> [Double] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        if sample.numSamples > 0 { times.append(sample.presentationTimeStamp.seconds) }
    }
    return times
}
