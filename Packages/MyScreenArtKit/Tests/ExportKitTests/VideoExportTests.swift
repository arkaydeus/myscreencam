import AVFoundation
import Foundation
import Testing

@testable import ExportKit

/// End-to-end exports of synthetic clips, verified with AVFoundation/ImageIO. Serialised so the
/// hardware encoders aren't shared and timing-sensitive tests (cancel) stay deterministic.
@Suite(.serialized)
struct VideoExportTests {
    static let expectedCodec: [ExportFormat: String] = [
        .h264: "avc1", .hevc: "hvc1", .hevc10bit: "hvc1", .proRes422: "apcn",
    ]

    @Test(arguments: ExportPreset.allCases)
    func exportsEveryPreset(preset: ExportPreset) async throws {
        let settings = preset.settings
        let source = try await Fixtures.shared.clip(.hd)
        let fixture = try await CompositionFixture.make(source: source, settings: settings)
        let directory = try await Fixtures.shared.outputDirectory(preset.rawValue)
        let url = directory.appendingPathComponent("out.\(settings.fileExtension)")

        let job = VideoExporter().start(
            asset: fixture.composition, videoComposition: fixture.videoComposition,
            audioMix: fixture.audioMix, to: url, settings: settings)
        let progress = collectProgress(job)
        let result = try await job.result
        let updates = await progress.value

        let expectedSize = settings.outputSize(forSource: fixture.sourceSize)
        #expect(result.url == url)
        #expect(result.dimensions == expectedSize)
        #expect(result.fileSize > 0)
        #expect(try filesIn(directory) == ["out.\(settings.fileExtension)"])
        expectWellFormed(updates)

        let frame = 1 / Double(settings.effectiveFrameRate.framesPerSecond)
        if settings.format == .gif {
            let gif = try GIFInfo.load(url)
            #expect(gif.size == expectedSize)
            #expect(gif.loopCount == 0)
            #expect(gif.frameCount > 1)
            #expect(gif.frameCount <= Int(fixture.duration.seconds * 15) + 1)
            #expect(abs(gif.totalDelay - fixture.duration.seconds) <= frame + 0.011)
            #expect(result.encoder == .imageIO)
        } else {
            let info = try await MovieInfo.load(url)
            #expect(info.codec == Self.expectedCodec[settings.format])
            #expect(info.size == expectedSize)
            #expect(ExportSettings.isEncodable(info.size))
            #expect(abs(Double(info.nominalFrameRate) - Double(settings.frameRate.framesPerSecond)) < 0.5)
            #expect(abs(info.duration - fixture.duration.seconds) <= frame + 0.001)
            #expect(info.isPlayable)
            #expect(info.isFastStart)
            #expect(info.colorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
            #expect(info.transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
            #expect(info.yCbCrMatrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))
            #expect(
                info.audioFormat == (settings.audioCodec == .linearPCM ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC))
            #expect(result.encoder == .hardware)
            #expect(abs(result.duration - info.duration) < 0.001)
        }
    }

    @Test func exportsHEVC10BitWithCoreImageCompositor() async throws {
        let settings = ExportSettings(format: .hevc10bit, container: .mov, frameRate: .fps30, scale: .half)
        let source = try await Fixtures.shared.clip(.hd)
        let fixture = try await CompositionFixture.make(
            source: source, settings: settings, compositor: CoreImageTestCompositor.self)
        let url = try await Fixtures.shared.outputDirectory("hevc10").appendingPathComponent("out.mov")

        let result = try await VideoExporter().start(
            asset: fixture.composition, videoComposition: fixture.videoComposition,
            audioMix: fixture.audioMix, to: url, settings: settings
        ).result

        let info = try await MovieInfo.load(url)
        #expect(info.codec == "hvc1")
        #expect(info.size == CGSize(width: 640, height: 360))
        #expect(info.bitsPerComponent == nil || info.bitsPerComponent == 10)
        #expect(info.audioFormat == kAudioFormatMPEG4AAC)
        #expect(result.frameCount == 60)
        #expect(
            CoreImageTestCompositor.seenFormats.withLock {
                $0.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            })
    }

    @Test(arguments: [ExportFormat.h264, .proRes422, .gif])
    func customCompositorGetsTheRequestedPixelFormat(format: ExportFormat) async throws {
        let settings = ExportSettings(format: format, frameRate: .fps30, scale: .half)
        let source = try await Fixtures.shared.clip(.hd)
        let fixture = try await CompositionFixture.make(
            source: source, settings: settings, compositor: CoreImageTestCompositor.self)
        let url = try await Fixtures.shared.outputDirectory("ci-\(format)")
            .appendingPathComponent("out.\(settings.fileExtension)")

        _ = try await VideoExporter().start(
            asset: fixture.composition, videoComposition: fixture.videoComposition,
            audioMix: fixture.audioMix, to: url, settings: settings
        ).result

        #expect(CoreImageTestCompositor.seenFormats.withLock { $0.contains(format.compositorPixelFormat) })
        if format != .gif {
            #expect(try await MovieInfo.load(url).isPlayable)
        }
    }

    @Test func exportsWithoutVideoComposition() async throws {
        let settings = ExportSettings(format: .h264, container: .mov, quality: .medium, frameRate: .fps24, scale: .half)
        let source = try await Fixtures.shared.clip(.hd)
        let url = try await Fixtures.shared.outputDirectory("plain").appendingPathComponent("out.mov")

        let result = try await VideoExporter().start(asset: AVURLAsset(url: source), to: url, settings: settings).result

        let info = try await MovieInfo.load(url)
        #expect(info.codec == "avc1")
        #expect(info.size == CGSize(width: 640, height: 360))
        #expect(abs(info.nominalFrameRate - 24) < 0.5)
        #expect(abs(info.duration - 2) <= 1 / 24 + 0.001)
        #expect(info.audioFormat == kAudioFormatMPEG4AAC)
        #expect(result.frameCount == 48)
    }

    @Test(arguments: [true, false])
    func oddSizedSourceExports(withVideoComposition: Bool) async throws {
        let settings = ExportSettings(format: .h264, frameRate: .fps30)
        let source = try await Fixtures.shared.clip(.odd)
        let url = try await Fixtures.shared.outputDirectory("odd-\(withVideoComposition)")
            .appendingPathComponent("out.mp4")

        let job: ExportJob
        if withVideoComposition {
            let fixture = try await CompositionFixture.make(source: source, settings: settings)
            #expect(fixture.sourceSize == CGSize(width: 2056, height: 1329))
            job = VideoExporter().start(
                asset: fixture.composition, videoComposition: fixture.videoComposition,
                audioMix: fixture.audioMix, to: url, settings: settings)
        } else {
            job = VideoExporter().start(asset: AVURLAsset(url: source), to: url, settings: settings)
        }
        let result = try await job.result

        let info = try await MovieInfo.load(url)
        #expect(result.dimensions == CGSize(width: 2056, height: 1330))
        #expect(info.size == CGSize(width: 2056, height: 1330))
        #expect(info.codec == "avc1")
        #expect(info.isPlayable)
    }

    @Test func oddRenderSizeFailsUpFrontWithoutWritingAFile() async throws {
        let settings = ExportSettings(format: .h264)
        let source = try await Fixtures.shared.clip(.odd)
        let fixture = try await CompositionFixture.make(
            source: source, settings: settings, renderSize: CGSize(width: 2056, height: 1329))
        let directory = try await Fixtures.shared.outputDirectory("odd-render")
        let url = directory.appendingPathComponent("out.mp4")

        let job = VideoExporter().start(
            asset: fixture.composition, videoComposition: fixture.videoComposition, to: url, settings: settings)
        await #expect {
            _ = try await job.result
        } throws: { error in
            guard case ExportError.invalidRenderSize(let size) = error else { return false }
            return size == CGSize(width: 2056, height: 1329)
        }
        #expect(try filesIn(directory).isEmpty)
    }

    @Test func cancelMidwayDeletesThePartialFileAndKeepsAnExistingOne() async throws {
        let settings = ExportSettings(format: .proRes422, frameRate: .fps60)
        let source = try await Fixtures.shared.clip(.long)
        let fixture = try await CompositionFixture.make(source: source, settings: settings)
        let directory = try await Fixtures.shared.outputDirectory("cancel")
        let url = directory.appendingPathComponent("out.mov")
        try Data("previous export".utf8).write(to: url)

        let exporter = VideoExporter(options: .init(progressInterval: .zero))
        let job = exporter.start(
            asset: fixture.composition, videoComposition: fixture.videoComposition,
            audioMix: fixture.audioMix, to: url, settings: settings)
        var sawEncoding = false
        var sawPartialBytes = false
        for await update in job.progress where update.stage == .encoding && update.framesWritten >= 5 {
            sawEncoding = true
            // The partial file (plus AVAssetWriter's scratch file) sits beside the untouched original.
            sawPartialBytes = try filesIn(directory).count >= 2
            job.cancel()
            break
        }
        #expect(sawEncoding)
        #expect(sawPartialBytes)
        await #expect(throws: ExportError.self) { _ = try await job.result }
        do {
            _ = try await job.result
        } catch {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
        }
        #expect(job.isCancelled)
        #expect(try filesIn(directory) == ["out.mov"])
        #expect(try Data(contentsOf: url) == Data("previous export".utf8))
    }

    @Test func cancelBeforeWorkStartsThrowsCancelled() async throws {
        let source = try await Fixtures.shared.clip(.hd)
        let directory = try await Fixtures.shared.outputDirectory("cancel-early")
        let job = VideoExporter().start(
            asset: AVURLAsset(url: source), to: directory.appendingPathComponent("out.mp4"),
            settings: ExportPreset.web.settings)
        job.cancel()
        await #expect {
            _ = try await job.result
        } throws: { error in
            if case ExportError.cancelled = error { return true }
            return false
        }
        #expect(try filesIn(directory).isEmpty)
    }

    @Test func successReplacesAnExistingFile() async throws {
        let settings = ExportSettings(format: .hevc, frameRate: .fps30, scale: .half)
        let source = try await Fixtures.shared.clip(.hd)
        let directory = try await Fixtures.shared.outputDirectory("replace")
        let url = directory.appendingPathComponent("out.mp4")
        try Data("stale".utf8).write(to: url)

        _ = try await VideoExporter().start(asset: AVURLAsset(url: source), to: url, settings: settings).result

        #expect(try await MovieInfo.load(url).codec == "hvc1")
        #expect(try filesIn(directory) == ["out.mp4"])
    }

    @Test func invalidSettingsFailFast() async throws {
        let source = try await Fixtures.shared.clip(.hd)
        let directory = try await Fixtures.shared.outputDirectory("invalid")
        let job = VideoExporter().start(
            asset: AVURLAsset(url: source), to: directory.appendingPathComponent("out.mp4"),
            settings: ExportSettings(format: .proRes422, container: .mp4))
        await #expect {
            _ = try await job.result
        } throws: { error in
            if case ExportError.invalidSettings = error { return true }
            return false
        }
        #expect(try filesIn(directory).isEmpty)
    }

    @Test func wedgedCompositorFailsInsteadOfFreezing() async throws {
        let settings = ExportSettings(format: .h264, frameRate: .fps30, scale: .half)
        let source = try await Fixtures.shared.clip(.hd)
        let fixture = try await CompositionFixture.make(
            source: source, settings: settings, compositor: HangingTestCompositor.self)
        let directory = try await Fixtures.shared.outputDirectory("stall")

        let job = VideoExporter(options: .init(stallTimeout: .seconds(1))).start(
            asset: fixture.composition, videoComposition: fixture.videoComposition,
            to: directory.appendingPathComponent("out.mp4"), settings: settings)
        let started = ContinuousClock.now
        await #expect {
            _ = try await job.result
        } throws: { error in
            if case ExportError.stalled = error { return true }
            return false
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(try filesIn(directory).isEmpty)
    }

    private func expectWellFormed(_ updates: [ExportProgress]) {
        #expect(updates.count >= 3)
        let fractions = updates.map(\.fraction)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards: \(fractions)")
        #expect(updates.last?.fraction == 1)
        #expect(updates.last?.stage == .finished)
        #expect(updates.contains { $0.stage == .encoding })
        #expect((updates.last?.bytesWritten ?? 0) > 0)
    }
}
