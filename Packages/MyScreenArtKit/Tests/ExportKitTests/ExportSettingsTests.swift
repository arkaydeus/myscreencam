import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import ExportKit

struct ExportSettingsTests {
    @Test(arguments: [
        (CGSize(width: 2056, height: 1329), CGSize(width: 2056, height: 1330)),
        (CGSize(width: 1281, height: 721), CGSize(width: 1282, height: 722)),
        (CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1080)),
        (CGSize(width: 1, height: 1), CGSize(width: 2, height: 2)),
    ])
    func fullSizeRoundsToEven(source: CGSize, expected: CGSize) {
        let settings = ExportSettings(format: .hevc)
        #expect(settings.outputSize(forSource: source) == expected)
    }

    @Test func scaleIsAppliedBeforeRounding() {
        var settings = ExportSettings(format: .hevc, scale: .threeQuarters)
        // 2056×1329 × 0.75 = 1542×996.75 → 1542×996.
        #expect(settings.outputSize(forSource: CGSize(width: 2056, height: 1329)) == CGSize(width: 1542, height: 996))
        settings.scale = .half
        // 1028×664.5 → 1028×664 (664.5 / 2 = 332.25 → 332).
        #expect(settings.outputSize(forSource: CGSize(width: 2056, height: 1329)) == CGSize(width: 1028, height: 664))
    }

    @Test func webPresetCapsAt1080pInEitherOrientation() {
        let settings = ExportPreset.web.settings
        #expect(settings.outputSize(forSource: CGSize(width: 3008, height: 1692)) == CGSize(width: 1920, height: 1080))
        #expect(settings.outputSize(forSource: CGSize(width: 1692, height: 3008)) == CGSize(width: 1080, height: 1920))
        // Never upscales.
        #expect(settings.outputSize(forSource: CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
        // Ultra-wide: the long edge binds.
        #expect(settings.outputSize(forSource: CGSize(width: 5120, height: 1440)) == CGSize(width: 1920, height: 540))
    }

    @Test func gifPresetCapsLongEdgeAt720() {
        let size = ExportPreset.gif.settings.outputSize(forSource: CGSize(width: 3008, height: 1692))
        #expect(size == CGSize(width: 720, height: 406))
    }

    @Test func h264IsCappedToTheEncoderMaximum() {
        let settings = ExportSettings(format: .h264)
        let size = settings.outputSize(forSource: CGSize(width: 6016, height: 3384))
        #expect(size.width <= 4096 && size.height <= 2304)
        #expect(ExportSettings.isEncodable(size))
        // ProRes keeps the full 6K frame.
        #expect(
            ExportSettings(format: .proRes422).outputSize(forSource: CGSize(width: 6016, height: 3384))
                == CGSize(width: 6016, height: 3384))
    }

    @Test func encodableSizes() {
        #expect(ExportSettings.isEncodable(CGSize(width: 1920, height: 1080)))
        #expect(!ExportSettings.isEncodable(CGSize(width: 2056, height: 1329)))
        #expect(!ExportSettings.isEncodable(CGSize(width: 1920.5, height: 1080)))
        #expect(!ExportSettings.isEncodable(CGSize(width: 0, height: 0)))
    }

    @Test func bitRateModel() throws {
        let size = CGSize(width: 1920, height: 1080)
        func rate(_ format: ExportFormat, _ quality: ExportQuality, _ fps: ExportFrameRate) -> Int? {
            ExportSettings(format: format, quality: quality, frameRate: fps).videoBitRate(forOutputSize: size)
        }
        let low = try #require(rate(.h264, .low, .fps30))
        let medium = try #require(rate(.h264, .medium, .fps30))
        let high = try #require(rate(.h264, .high, .fps30))
        let max = try #require(rate(.h264, .max, .fps30))
        #expect(low < medium && medium < high && high < max)
        // 1080p30 H.264 high ≈ 6.2 Mbit/s.
        #expect((5_500_000...7_000_000).contains(high))
        // 60 fps costs more than 30 but less than double.
        let high60 = try #require(rate(.h264, .high, .fps60))
        #expect(high60 > high && high60 < 2 * high)
        // HEVC is cheaper than H.264.
        #expect(try #require(rate(.hevc, .high, .fps30)) < high)
        #expect(rate(.proRes422, .high, .fps30) == nil)
        #expect(rate(.gif, .high, .fps30) == nil)
    }

    @Test func containersAndAudio() throws {
        #expect(ExportSettings(format: .h264).container == .mp4)
        #expect(ExportSettings(format: .proRes422).container == .mov)
        #expect(ExportSettings(format: .gif).container == .gif)
        #expect(ExportSettings(format: .h264).audioCodec == .aac)
        #expect(ExportSettings(format: .proRes422).audioCodec == .linearPCM)
        #expect(ExportSettings(format: .gif).audioCodec == nil)
        try ExportSettings(format: .hevc, container: .mov).validate()
        #expect(throws: ExportError.self) { try ExportSettings(format: .proRes422, container: .mp4).validate() }
        #expect(throws: ExportError.self) { try ExportSettings(format: .h264, container: .gif).validate() }
        #expect(throws: ExportError.self) { try ExportSettings(format: .gif, container: .mp4).validate() }
    }

    @Test func gifFrameRateIsCappedAt30() {
        #expect(ExportSettings(format: .gif, frameRate: .fps60).effectiveFrameRate == .fps30)
        #expect(ExportSettings(format: .gif, frameRate: .fps15).effectiveFrameRate == .fps15)
        #expect(ExportSettings(format: .h264, frameRate: .fps60).effectiveFrameRate == .fps60)
    }

    @Test func compositorPixelFormats() {
        #expect(ExportFormat.h264.compositorPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(ExportFormat.hevc10bit.compositorPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(ExportFormat.gif.compositorPixelFormat == kCVPixelFormatType_32BGRA)
    }

    @Test(arguments: ExportPreset.allCases)
    func presetsAreValidAndCodable(preset: ExportPreset) throws {
        let settings = preset.settings
        try settings.validate()
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ExportSettings.self, from: data) == settings)
        let presetData = try JSONEncoder().encode(preset)
        #expect(try JSONDecoder().decode(ExportPreset.self, from: presetData) == preset)
    }

    @Test func presetShapes() {
        #expect(ExportPreset.web.settings.format == .h264)
        #expect(ExportPreset.web.settings.frameRate == .fps30)
        #expect(ExportPreset.smooth.settings.frameRate == .fps60)
        #expect(ExportPreset.compact.settings.frameRate == .fps24)
        #expect(ExportPreset.master.settings.format == .proRes422)
        #expect(ExportPreset.master.settings.maxLongEdge == nil)
        #expect(ExportPreset.gif.settings.format == .gif)
        #expect(ExportPreset.gif.settings.frameRate == .fps15)
    }

    @Test func settingsDecodeLeniently() throws {
        let json = Data(#"{"format":"proRes422","frameRate":60}"#.utf8)
        let settings = try JSONDecoder().decode(ExportSettings.self, from: json)
        #expect(settings.format == .proRes422)
        #expect(settings.container == .mov)
        #expect(settings.frameRate == .fps60)
        #expect(settings.quality == .high)
        #expect(settings.includesAudio)
    }
}

struct GIFParserTests {
    @Test func rejectsGarbage() {
        #expect(GIFParser.firstFrame(in: Data([1, 2, 3])) == nil)
        #expect(GIFParser.firstFrame(in: Data("GIF89a".utf8)) == nil)
    }
}
