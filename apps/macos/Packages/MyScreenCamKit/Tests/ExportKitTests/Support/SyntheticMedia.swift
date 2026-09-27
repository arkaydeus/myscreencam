import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import ExportKit

/// A synthetic source clip: colour-cycling frames with a moving white square, plus a 440 Hz sine.
struct ClipSpec: Hashable, Sendable {
    var width: Int
    var height: Int
    var fps: Int
    var seconds: Double
    var codec: AVVideoCodecType = .h264
    var audio = true
    /// Every frame identical (for GIF frame merging).
    var isStatic = false

    var name: String {
        "\(codec.rawValue)-\(width)x\(height)@\(fps)-\(seconds)s\(audio ? "-audio" : "")\(isStatic ? "-static" : "")"
    }

    static let hd = ClipSpec(width: 1280, height: 720, fps: 60, seconds: 2)
    static let odd = ClipSpec(width: 2056, height: 1329, fps: 30, seconds: 1, codec: .proRes422)
    static let long = ClipSpec(width: 1280, height: 720, fps: 30, seconds: 8)
    static let still = ClipSpec(width: 640, height: 360, fps: 30, seconds: 2, audio: false, isStatic: true)
}

/// Generates each clip once per test run and hands out its URL.
actor Fixtures {
    static let shared = Fixtures()

    static let prefix = "ExportKitTests-"

    let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    private var clips: [ClipSpec: Task<URL, any Error>] = [:]

    init() {
        Self.pruneStaleDirectories()
    }

    /// Deletes fixture directories left by earlier test processes that are no longer running.
    private static func pruneStaleDirectories() {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: temporary.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            guard let pid = pid_t(name.dropFirst(prefix.count)) else { continue }
            if pid != ProcessInfo.processInfo.processIdentifier && kill(pid, 0) != 0 && errno == ESRCH {
                try? manager.removeItem(at: temporary.appendingPathComponent(name))
            }
        }
    }

    func clip(_ spec: ClipSpec) async throws -> URL {
        if let task = clips[spec] { return try await task.value }
        let url = directory.appendingPathComponent("\(spec.name).mov")
        let task = Task {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await SyntheticMedia.write(spec, to: url)
            return url
        }
        clips[spec] = task
        return try await task.value
    }

    /// A fresh output directory for one test.
    func outputDirectory(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent("out-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum SyntheticMedia {
    static let sampleRate = 48_000.0

    static func write(_ spec: ClipSpec, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
        ]
        if spec.codec == .h264 || spec.codec == .hevc {
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 8_000_000]
        }
        // ProRes (4:2:2) keeps odd heights; the H.264/HEVC encoders crop them to even.
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if spec.audio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((spec.seconds * Double(spec.fps)).rounded())
        let totalAudioFrames = Int(spec.seconds * sampleRate)
        var audioFramesWritten = 0
        let audioChunk = 1024

        // Feed whichever input the writer is ready for: its interleaver may hold video back until
        // more audio arrives (or the reverse), so waiting on one input alone can deadlock.
        var frame = 0
        var videoDone = false
        var audioDone = audioInput == nil
        while !videoDone || !audioDone {
            var progressed = false
            if !videoDone && videoInput.isReadyForMoreMediaData {
                let buffer = try makeFrame(spec: spec, index: frame, pool: adaptor.pixelBufferPool)
                let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(spec.fps))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                frame += 1
                if frame == frameCount {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                progressed = true
            }
            if let audioInput, !audioDone, audioInput.isReadyForMoreMediaData {
                let count = min(audioChunk, totalAudioFrames - audioFramesWritten)
                guard audioInput.append(try makeSine(start: audioFramesWritten, count: count)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                audioFramesWritten += count
                if audioFramesWritten == totalAudioFrames {
                    audioInput.markAsFinished()
                    audioDone = true
                }
                progressed = true
            }
            if !progressed { try await Task.sleep(for: .milliseconds(1)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func makeFrame(spec: ClipSpec, index: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        guard let pool else { throw CocoaError(.fileWriteUnknown) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: spec.width, height: spec.height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let phase = spec.isStatic ? 0 : Double(index) / Double(spec.fps)
        context.setFillColor(
            CGColor(
                red: 0.5 + 0.5 * sin(phase * 2.1), green: 0.5 + 0.5 * sin(phase * 1.3 + 2),
                blue: 0.5 + 0.5 * sin(phase * 0.7 + 4), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let side = Double(spec.height) / 5
        let x = (Double(spec.width) - side) * (0.5 + 0.5 * sin(phase * 3))
        context.fill(CGRect(x: x, y: Double(spec.height) / 2 - side / 2, width: side, height: side))
        return buffer
    }

    private static func makeSine(start: Int, count: Int) throws -> CMSampleBuffer {
        var samples = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            let value = Float(0.25 * sin(2 * Double.pi * 440 * Double(start + i) / sampleRate))
            samples[2 * i] = value
            samples[2 * i + 1] = value
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        try check(
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &format))
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        try check(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block))
        guard let block, let format else { throw CocoaError(.fileWriteUnknown) }
        try samples.withUnsafeBytes { bytes in
            try check(
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount))
        }
        var sample: CMSampleBuffer?
        try check(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample))
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// Wraps a source clip the way the renderer will: an `AVMutableComposition`, a video composition at
/// `settings.outputSize(forSource:)` with a scaling layer instruction, and an audio mix.
struct CompositionFixture: @unchecked Sendable {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let sourceSize: CGSize
    let duration: CMTime

    static func make(
        source url: URL,
        settings: ExportSettings,
        renderSize overrideSize: CGSize? = nil,
        compositor: (any AVVideoCompositing.Type)? = nil
    ) async throws -> CompositionFixture {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()

        let sourceVideo = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoTrack = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)

        var audioMix: AVMutableAudioMix?
        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
            let audioTrack = try #require(
                composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
            let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
            parameters.setVolumeRamp(fromStartVolume: 0.2, toEndVolume: 1, timeRange: range)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            audioMix = mix
        }

        let sourceSize = try await sourceVideo.load(.naturalSize)
        let renderSize = overrideSize ?? settings.outputSize(forSource: sourceSize)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(
            CGAffineTransform(
                scaleX: renderSize.width / sourceSize.width, y: renderSize.height / sourceSize.height),
            at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        if let compositor {
            videoComposition.customVideoCompositorClass = compositor
        }
        return CompositionFixture(
            composition: composition, videoComposition: videoComposition, audioMix: audioMix,
            sourceSize: sourceSize, duration: duration)
    }
}
