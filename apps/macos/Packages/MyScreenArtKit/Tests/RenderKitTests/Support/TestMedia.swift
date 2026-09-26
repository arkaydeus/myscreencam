import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ProjectKit
import Testing

@testable import RenderKit

/// Synthetic recording packages for integration tests.
///
/// `screen.mov` (640×360, 30 fps, 4 s, H.264, BT.709):
/// - background `R = 20 + 60·floor(t)`, `G = B = 40` (so each second is identifiable after cuts);
/// - an 8-px black/white checkerboard at x 400…560, y 40…160 (for blur);
/// - a green (0,200,0) square at x 100…140, y 160…200 (for zoom).
///
/// `webcam.mov`: 160×90 solid blue, 2 s, start offset 1.0 s (covers session 1…3).
/// `sysaudio.m4a`: 440 Hz sine at amplitude 0.5, 4 s. `mic.m4a`: 220 Hz sine at amplitude 0.25, 3 s, offset 0.5.
enum TestMedia {
    static let size = (w: 640, h: 360)
    static let fps = 30
    static let duration = 4.0
    static let webcamOffset = 1.0

    static func backgroundRed(atSecond second: Int) -> Int { 20 + 60 * second }
    static let checker = (x0: 400, y0: 40, x1: 560, y1: 160)
    static let greenSquare = (x0: 100, y0: 160, x1: 140, y1: 200)

    /// Shared package, generated once per test process.
    static let shared: Task<RecordingPackage, any Error> = Task { try await makePackage() }

    static func makePackage() async throws -> RecordingPackage {
        let root = FileManager.default.temporaryDirectory.appending(path: "RenderKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = try RecordingPackage.create(in: root)
        try await writeVideo(
            to: package.url(for: .screen), width: size.w, height: size.h, frames: Int(duration) * fps
        ) { frame, x, y in
            let t = Double(frame) / Double(fps)
            if x >= greenSquare.x0, x < greenSquare.x1, y >= greenSquare.y0, y < greenSquare.y1 { return (0, 200, 0) }
            if x >= checker.x0, x < checker.x1, y >= checker.y0, y < checker.y1 {
                return ((x / 8 + y / 8) % 2 == 0) ? (255, 255, 255) : (0, 0, 0)
            }
            return (backgroundRed(atSecond: Int(t)), 40, 40)
        }
        try await writeVideo(to: package.url(for: .webcam), width: 160, height: 90, frames: 2 * fps) { _, _, _ in
            (0, 0, 255)
        }
        try writeSine(to: package.url(for: .systemAudio), frequency: 440, amplitude: 0.5, seconds: duration)
        try writeSine(to: package.url(for: .microphone), frequency: 220, amplitude: 0.25, seconds: 3)

        let meta = RecordingMeta(
            name: "Synthetic", duration: duration, source: .display(displayID: 1, name: "Test"),
            screen: ScreenStreamInfo(
                pixelWidth: size.w, pixelHeight: size.h, scale: 1, frameRate: fps, codec: "avc1",
                contentRectPoints: RectPoints(x: 0, y: 0, width: Double(size.w), height: Double(size.h))),
            webcam: WebcamStreamInfo(deviceID: "cam", name: "Cam", pixelWidth: 160, pixelHeight: 90, frameRate: 30),
            microphone: AudioDeviceInfo(deviceID: "mic", name: "Mic"), capturedSystemAudio: true,
            streams: [
                .screen: StreamTiming(startOffset: 0), .webcam: StreamTiming(startOffset: webcamOffset),
                .systemAudio: StreamTiming(startOffset: 0), .microphone: StreamTiming(startOffset: 0.5),
            ],
            systemCursorHidden: true)
        try package.saveMeta(meta)
        return package
    }

    /// A project for the shared package with `edit` and `events`.
    static func project(edit: EditConfig? = nil, events: [InputEvent] = []) async throws -> RenderProject {
        let package = try await shared.value
        let meta = try package.loadMeta()
        var base = EditConfig.initial(for: meta)
        base.webcam.enabled = false
        base.cursor.enabled = false
        return RenderProject(
            package: package, meta: meta, edit: edit ?? base, events: events, cursorIndex: CursorIndex())
    }

    /// A baseline edit: whole recording, no effects.
    static func plainEdit() async throws -> EditConfig {
        try await project().edit
    }

    // MARK: writers

    private static func writeVideo(
        to url: URL, width: Int, height: Int, frames: Int, color: (Int, Int, Int) -> (Int, Int, Int)
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let buffer = try makeBGRA(width: width, height: height) { x, y in color(frame, x, y) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func makeBGRA(width: Int, height: Int, color: (Int, Int) -> (Int, Int, Int)) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let p = base + y * stride + x * 4
                p[0] = UInt8(b)
                p[1] = UInt8(g)
                p[2] = UInt8(r)
                p[3] = 255
            }
        }
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    private static func writeSine(to url: URL, frequency: Double, amplitude: Float, seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(rate * seconds)
        let chunk = 4800
        var written = 0
        while written < total {
            let n = min(chunk, total - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            let samples = buffer.floatChannelData![0]
            for i in 0..<n {
                samples[i] = amplitude * Float(sin(2 * .pi * frequency * Double(written + i) / rate))
            }
            try file.write(from: buffer)
            written += n
        }
        file.close()
    }
}

/// An RGBA8 bitmap of a rendered frame for pixel assertions (row 0 = top). Values stay in the frame's own
/// encoding (BT.709 R'G'B'), so they compare directly with the synthetic source colours.
struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709)!
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.itur_709)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.bytes = bytes
    }

    /// Renders a composed pixel buffer (BGRA or 420v) back to R'G'B' in its own (BT.709) encoding.
    init(pixelBuffer: CVPixelBuffer) {
        // Decode with the buffer's own tags and re-encode into the same space: no transfer-curve change.
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let space =
            CVImageBufferCreateColorSpaceFromAttachments(
                CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) ?? [:] as CFDictionary)?
            .takeRetainedValue() ?? CGColorSpace(name: CGColorSpace.itur_709)!
        let context = CIContext(options: [.workingColorSpace: space])
        let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)!
        self.init(cgImage: cg)
    }

    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// Luma-ish mean and standard deviation over a rect (for smoothness checks).
    func stats(x0: Int, y0: Int, x1: Int, y1: Int) -> (mean: Double, std: Double) {
        var values: [Double] = []
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = pixel(x, y)
                values.append(Double(p.r + p.g + p.b) / 3)
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    /// Number of pixels in a rect that differ from `reference` by more than `threshold` (sum of channel deltas).
    func countDiffering(from reference: (r: Int, g: Int, b: Int), threshold: Int, x0: Int, y0: Int, x1: Int, y1: Int)
        -> (count: Int, minX: Int, minY: Int)
    {
        var count = 0
        var minX = Int.max
        var minY = Int.max
        for y in max(0, y0)..<min(height, y1) {
            for x in max(0, x0)..<min(width, x1) {
                let p = pixel(x, y)
                if abs(p.r - reference.r) + abs(p.g - reference.g) + abs(p.b - reference.b) > threshold {
                    count += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                }
            }
        }
        return (count, minX, minY)
    }
}

func close(_ a: (r: Int, g: Int, b: Int), _ b: (Int, Int, Int), tolerance: Int = 12) -> Bool {
    abs(a.r - b.0) <= tolerance && abs(a.g - b.1) <= tolerance && abs(a.b - b.2) <= tolerance
}

/// Renders frames of a built composition.
enum FrameGrabber {
    /// The frame at edited time `seconds` via `AVAssetImageGenerator` with the custom video composition.
    static func frame(_ built: BuiltComposition, at seconds: Double) async throws -> Bitmap {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return Bitmap(cgImage: image)
    }

    /// The first `count` frames via `AVAssetReaderVideoCompositionOutput` in `pixelFormat`.
    static func readerFrames(_ built: BuiltComposition, pixelFormat: OSType, count: Int = 1) async throws
        -> [CVPixelBuffer]
    {
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.videoTracks(),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        output.videoComposition = built.videoComposition
        reader.add(output)
        #expect(reader.startReading())
        var buffers: [CVPixelBuffer] = []
        while buffers.count < count, let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { buffers.append(buffer) }
        }
        reader.cancelReading()
        return buffers
    }
}
