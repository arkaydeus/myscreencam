import AVFoundation
import CoreVideo
import Foundation
import Synchronization

@testable import ProjectKit

/// A temporary directory removed on deinit.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "pk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

enum Fixtures {
    static func meta(
        name: String = "Test", createdAt: Date = Date(timeIntervalSince1970: 1_790_000_000), duration: Double = 10,
        streams: [StreamKind: StreamTiming] = [:]
    ) -> RecordingMeta {
        RecordingMeta(
            name: name,
            createdAt: createdAt,
            duration: duration,
            source: .display(displayID: 1, name: "Built-in"),
            screen: ScreenStreamInfo(
                pixelWidth: 1280, pixelHeight: 720, scale: 2, frameRate: 60, codec: "avc1",
                contentRectPoints: RectPoints(x: 0, y: 0, width: 640, height: 360)),
            streams: streams
        )
    }

    /// Creates a package with a meta in `root`.
    static func package(in root: URL, meta: RecordingMeta) throws -> RecordingPackage {
        let package = try RecordingPackage.create(in: root, date: meta.createdAt, id: meta.id)
        try package.saveMeta(meta)
        return package
    }

    /// Writes an H.264 `.mov` of `frameCount` solid-colour BGRA frames at `fps`.
    static func writeSolidVideo(
        to url: URL, width: Int = 1280, height: Int = 720, frameCount: Int = 10, fps: Int32 = 10,
        bgra: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 255)
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = base + y * bytesPerRow
                for x in 0..<width {
                    row[x * 4] = bgra.0
                    row[x * 4 + 1] = bgra.1
                    row[x * 4 + 2] = bgra.2
                    row[x * 4 + 3] = bgra.3
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: fps))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Writes an AAC `.m4a` from `segments` of (seconds, amplitude) sine at 440 Hz (amplitude 0 = silence).
    static func writeTone(
        to url: URL, segments: [(seconds: Double, amplitude: Float)], sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 1
    ) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ])
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 4096
        var phase = 0.0
        let step = 2 * Double.pi * 440 / sampleRate
        for segment in segments {
            var remaining = Int(segment.seconds * sampleRate)
            while remaining > 0 {
                let frames = AVAudioFrameCount(min(Int(chunk), remaining))
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                for i in 0..<Int(frames) {
                    let value = segment.amplitude * Float(sin(phase))
                    phase += step
                    for c in 0..<Int(channels) { buffer.floatChannelData![c][i] = value }
                }
                try file.write(from: buffer)
                remaining -= Int(frames)
            }
        }
        file.close()
    }
}

/// Counts values delivered by an async stream consumer.
actor Counter {
    private(set) var value = 0

    func increment() { value += 1 }
}

func approx(_ a: [Double], _ b: [Double], tolerance: Double = 1e-9) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

/// A mutex-protected value that closures can share.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<R>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}
