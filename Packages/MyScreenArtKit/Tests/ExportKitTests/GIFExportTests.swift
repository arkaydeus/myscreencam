import AVFoundation
import Foundation
import Testing

@testable import ExportKit

@Suite(.serialized)
struct GIFExportTests {
    @Test func identicalFramesAreMergedIntoOneLongerFrame() async throws {
        let source = try await Fixtures.shared.clip(.still)
        let url = try await Fixtures.shared.outputDirectory("gif-still").appendingPathComponent("out.gif")

        let result = try await VideoExporter().start(
            asset: AVURLAsset(url: source), to: url, settings: ExportPreset.gif.settings
        ).result

        // 30 decoded frames of a static H.264 clip collapse to the first frame plus at most a couple
        // of small patches where the P-frames sharpen the I-frame's edges.
        let gif = try GIFInfo.load(url)
        #expect(gif.frameCount <= 3)
        #expect(result.frameCount == gif.frameCount)
        #expect(abs(gif.totalDelay - 2) < 0.011)
        #expect(gif.size == CGSize(width: 640, height: 360))
        #expect(result.fileSize < 20_000)
    }

    @Test func oddSourceAndFrameTiming() async throws {
        var settings = ExportPreset.gif.settings
        settings.frameRate = .fps24
        let source = try await Fixtures.shared.clip(.odd)
        let url = try await Fixtures.shared.outputDirectory("gif-odd").appendingPathComponent("out.gif")

        let result = try await VideoExporter().start(asset: AVURLAsset(url: source), to: url, settings: settings).result

        let gif = try GIFInfo.load(url)
        // 2056×1329 fitted into 720 on the long edge: 720×465.4 → 720×466.
        #expect(gif.size == CGSize(width: 720, height: 466))
        #expect(gif.loopCount == 0)
        #expect(gif.frameCount == 24)
        // Delays are whole centiseconds but rounded on the cumulative timeline, so the total is exact.
        #expect(abs(gif.totalDelay - 1) < 0.011)
        #expect(abs(result.duration - 1) < 0.011)
    }

    @Test func cancelMidwayDeletesThePartialGIF() async throws {
        let source = try await Fixtures.shared.clip(.long)
        let directory = try await Fixtures.shared.outputDirectory("gif-cancel")
        let job = VideoExporter(options: .init(progressInterval: .zero)).start(
            asset: AVURLAsset(url: source), to: directory.appendingPathComponent("out.gif"),
            settings: ExportPreset.gif.settings)
        for await update in job.progress where update.stage == .encoding && update.framesWritten >= 3 {
            job.cancel()
            break
        }
        await #expect {
            _ = try await job.result
        } throws: { error in
            if case ExportError.cancelled = error { return true }
            return false
        }
        #expect(try filesIn(directory).isEmpty)
    }

    @Test func frameSplicingRoundTrips() throws {
        let width = 64
        let height = 48
        let encoder = GIFFrameEncoder(width: width, height: height)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportKitTests-splice-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("splice.gif")
        let writer = try GIFStreamWriter(url: url, width: width, height: height)

        func buffer(fill: UInt32, square: (Int, Int)?) throws -> CVPixelBuffer {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = (base + y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width {
                    var value = fill
                    if let (sx, sy) = square, (sx..<sx + 8).contains(x), (sy..<sy + 8).contains(y) {
                        value = 0xFFFF_FFFF
                    }
                    row[x] = value
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }

        let first = try #require(try encoder.encode(try buffer(fill: 0xFF20_4080, square: nil)))
        #expect(first.width == width && first.height == height)
        try writer.append(first, delayCentiseconds: 10)
        #expect(try encoder.encode(try buffer(fill: 0xFF20_4080, square: nil)) == nil)
        let moved = try #require(try encoder.encode(try buffer(fill: 0xFF20_4080, square: (10, 20))))
        #expect(moved.left == 10 && moved.top == 20 && moved.width == 8 && moved.height == 8)
        try writer.append(moved, delayCentiseconds: 7)
        try writer.close()

        let gif = try GIFInfo.load(url)
        #expect(gif.frameCount == 2)
        #expect(abs(gif.totalDelay - 0.17) < 0.001)
        #expect(gif.size == CGSize(width: width, height: height))
        try? FileManager.default.removeItem(at: directory)
    }
}
