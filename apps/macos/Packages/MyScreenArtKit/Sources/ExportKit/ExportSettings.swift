import AVFoundation
import CoreGraphics
import CoreVideo
import UniformTypeIdentifiers

/// The codec an export encodes to.
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    /// H.264 High profile, 8-bit 4:2:0. The most compatible choice.
    case h264
    /// HEVC Main, 8-bit 4:2:0. About 30 % smaller than H.264 at the same quality.
    case hevc
    /// HEVC Main10, 10-bit 4:2:0.
    case hevc10bit
    /// Apple ProRes 422 (`apcn`), the high-quality editing/master format. Always `.mov`.
    case proRes422
    /// Animated GIF, written with ImageIO. Video only, no audio.
    case gif

    /// The container used when the settings don't name one.
    public var defaultContainer: ExportContainer {
        switch self {
        case .h264, .hevc, .hevc10bit: .mp4
        case .proRes422: .mov
        case .gif: .gif
        }
    }

    /// The containers this format can be written to.
    public var supportedContainers: [ExportContainer] {
        switch self {
        case .h264, .hevc, .hevc10bit: [.mp4, .mov]
        case .proRes422: [.mov]
        case .gif: [.gif]
        }
    }

    /// A short name for menus.
    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .hevc10bit: "HEVC 10-bit"
        case .proRes422: "ProRes 422"
        case .gif: "GIF"
        }
    }

    /// The pixel format ExportKit asks the video composition to render.
    ///
    /// A custom compositor (`AVVideoCompositing`) must list this format in its
    /// `requiredPixelBufferAttributesForRenderContext`:
    /// - `420v` (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) for H.264 and HEVC,
    /// - `x420` (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`) for HEVC 10-bit,
    /// - `x422` (`kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange`) for ProRes 422,
    /// - `BGRA` (`kCVPixelFormatType_32BGRA`) for GIF.
    ///
    /// Every buffer is IOSurface-backed, so it stays on the GPU from compositor to encoder.
    public var compositorPixelFormat: OSType {
        switch self {
        case .h264, .hevc: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .hevc10bit: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .proRes422: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .gif: kCVPixelFormatType_32BGRA
        }
    }

    /// The largest frame (long edge × short edge) the encoder accepts. `outputSize(forSource:)` fits into it.
    public var maximumDimensions: (longEdge: Int, shortEdge: Int) {
        switch self {
        // H.264 level 5.2 / the Apple media engine top out at 4096×2304.
        case .h264: (4096, 2304)
        case .hevc, .hevc10bit, .proRes422: (8192, 4320)
        // ImageIO quantises every GIF frame on the CPU; beyond this a GIF is the wrong format.
        case .gif: (1920, 1920)
        }
    }

    var isGIF: Bool { self == .gif }
}

/// The file container.
public enum ExportContainer: String, Codable, CaseIterable, Sendable {
    case mp4
    case mov
    case gif

    /// The filename extension, without the dot.
    public var fileExtension: String { rawValue }

    /// The uniform type, for `NSSavePanel.allowedContentTypes`.
    public var contentType: UTType {
        switch self {
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .gif: .gif
        }
    }

    var avFileType: AVFileType? {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .gif: nil
        }
    }
}

/// Encoder quality. Maps to a bitrate (see ``ExportSettings/videoBitRate(forOutputSize:)``); ProRes and GIF ignore it.
public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case max

    /// H.264 bits per pixel per frame at the 30 fps reference rate.
    ///
    /// Screen content is mostly static text and flat colour, so it needs far fewer bits than camera
    /// footage (≈0.1 bpp there is "high"), but text edges smear quickly when starved. 1080p30 H.264
    /// comes out at ≈2.8 / 4.4 / 6.2 / 10 Mbit/s.
    public var bitsPerPixel: Double {
        switch self {
        case .low: 0.045
        case .medium: 0.07
        case .high: 0.10
        case .max: 0.16
        }
    }

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Maximum"
        }
    }
}

/// Output frame rate. The UI offers ``videoRates``; 15 fps exists for GIF.
public enum ExportFrameRate: Int, Codable, CaseIterable, Sendable {
    case fps15 = 15
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    /// The rates offered for video formats.
    public static let videoRates: [ExportFrameRate] = [.fps24, .fps30, .fps60]

    public var framesPerSecond: Int { rawValue }

    /// One frame, in a timescale that represents it exactly.
    public var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(rawValue)) }
}

/// Output resolution relative to the source (100 / 75 / 50 %).
public enum ExportScale: Double, Codable, CaseIterable, Sendable {
    case full = 1.0
    case threeQuarters = 0.75
    case half = 0.5

    public var displayName: String {
        switch self {
        case .full: "100%"
        case .threeQuarters: "75%"
        case .half: "50%"
        }
    }
}

/// The audio codec an export writes, derived from the format and container.
public enum ExportAudioCodec: String, Codable, Sendable {
    /// AAC-LC, 48 kHz stereo, 192 kbit/s.
    case aac
    /// 24-bit integer linear PCM, 48 kHz stereo (ProRes masters).
    case linearPCM
}

/// Everything that determines an export's output. `Codable`, so the UI can remember the user's choices.
///
/// Colour is always tagged BT.709 (primaries, transfer function and matrix). MP4 and MOV files are
/// written fast-start (`moov` first) so they stream over the network.
public struct ExportSettings: Codable, Hashable, Sendable {
    public var format: ExportFormat
    public var container: ExportContainer
    public var quality: ExportQuality
    public var frameRate: ExportFrameRate
    public var scale: ExportScale
    /// Caps the output's long edge (width for landscape). Applied after `scale`; never upscales.
    public var maxLongEdge: Int?
    /// Caps the output's short edge (height for landscape). Applied after `scale`; never upscales.
    public var maxShortEdge: Int?
    /// Whether to write an audio track (when the source has audio). GIF never has audio.
    public var includesAudio: Bool

    /// - Parameter container: `nil` picks `format.defaultContainer`.
    public init(
        format: ExportFormat = .hevc,
        container: ExportContainer? = nil,
        quality: ExportQuality = .high,
        frameRate: ExportFrameRate = .fps30,
        scale: ExportScale = .full,
        maxLongEdge: Int? = nil,
        maxShortEdge: Int? = nil,
        includesAudio: Bool = true
    ) {
        self.format = format
        self.container = container ?? format.defaultContainer
        self.quality = quality
        self.frameRate = frameRate
        self.scale = scale
        self.maxLongEdge = maxLongEdge
        self.maxShortEdge = maxShortEdge
        self.includesAudio = includesAudio
    }

    private enum CodingKeys: String, CodingKey {
        case format, container, quality, frameRate, scale, maxLongEdge, maxShortEdge, includesAudio
    }

    /// Decodes leniently: missing keys fall back to the defaults, so remembered settings survive new fields.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let format = try values.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .hevc
        self.init(
            format: format,
            container: try values.decodeIfPresent(ExportContainer.self, forKey: .container),
            quality: try values.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .high,
            frameRate: try values.decodeIfPresent(ExportFrameRate.self, forKey: .frameRate) ?? .fps30,
            scale: try values.decodeIfPresent(ExportScale.self, forKey: .scale) ?? .full,
            maxLongEdge: try values.decodeIfPresent(Int.self, forKey: .maxLongEdge),
            maxShortEdge: try values.decodeIfPresent(Int.self, forKey: .maxShortEdge),
            includesAudio: try values.decodeIfPresent(Bool.self, forKey: .includesAudio) ?? true
        )
    }

    // MARK: Derived values

    /// The filename extension for the container, without the dot.
    public var fileExtension: String { container.fileExtension }

    /// The frame rate actually written. GIF is capped at 30 fps because GIF delays are whole
    /// centiseconds and players stretch delays under 2 cs to 10 cs.
    public var effectiveFrameRate: ExportFrameRate {
        format.isGIF && frameRate == .fps60 ? .fps30 : frameRate
    }

    /// The audio codec written, or `nil` for GIF.
    public var audioCodec: ExportAudioCodec? {
        switch format {
        case .gif: nil
        case .proRes422: container == .mov ? .linearPCM : .aac
        case .h264, .hevc, .hevc10bit: .aac
        }
    }

    /// The exact frame size to export for a source (oriented) size.
    ///
    /// The app must ask the renderer for a video composition whose `renderSize` is exactly this value.
    /// The steps, in order:
    /// 1. multiply by `scale`,
    /// 2. fit inside `maxLongEdge`/`maxShortEdge` and the codec's maximum, keeping the aspect ratio
    ///    and never upscaling,
    /// 3. round each side to the nearest **even** number, minimum 2. 4:2:0 chroma needs even
    ///    dimensions; the hardware encoders pad to their macroblock/CTU size internally, so no
    ///    coarser alignment is needed. This is why an odd 2056×1329 capture exports at 2056×1330.
    public func outputSize(forSource source: CGSize) -> CGSize {
        let sourceWidth = max(1, abs(source.width))
        let sourceHeight = max(1, abs(source.height))
        var width = sourceWidth * scale.rawValue
        var height = sourceHeight * scale.rawValue

        let codecLimit = format.maximumDimensions
        let longLimit = min(Double(maxLongEdge ?? .max), Double(codecLimit.longEdge))
        let shortLimit = min(Double(maxShortEdge ?? .max), Double(codecLimit.shortEdge))
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        let fit = min(1, longLimit / longEdge, shortLimit / shortEdge)
        width *= fit
        height *= fit

        return CGSize(width: Self.roundedToEven(width), height: Self.roundedToEven(height))
    }

    /// Whether a size can be encoded: positive, integral and even on both sides.
    public static func isEncodable(_ size: CGSize) -> Bool {
        func valid(_ value: CGFloat) -> Bool {
            value >= 2 && value.rounded() == value && Int(value) % 2 == 0
        }
        return valid(size.width) && valid(size.height)
    }

    /// The average video bitrate in bit/s for an output size, or `nil` for ProRes (fixed-quality) and GIF.
    ///
    /// Model: `width × height × effectiveFps × bitsPerPixel × codecFactor`, where
    /// `effectiveFps = 30 × (fps / 30)^0.75`. Higher frame rates need proportionally fewer bits per
    /// frame because consecutive frames are more alike. HEVC gets 0.7× H.264 (0.75× for 10-bit).
    /// The result is clamped to 0.5–240 Mbit/s.
    public func videoBitRate(forOutputSize size: CGSize) -> Int? {
        let codecFactor: Double
        switch format {
        case .h264: codecFactor = 1.0
        case .hevc: codecFactor = 0.7
        case .hevc10bit: codecFactor = 0.75
        case .proRes422, .gif: return nil
        }
        let fps = Double(effectiveFrameRate.framesPerSecond)
        let effectiveFps = 30 * pow(fps / 30, 0.75)
        let bits = Double(size.width * size.height) * effectiveFps * quality.bitsPerPixel * codecFactor
        return Int(min(max(bits, 500_000), 240_000_000))
    }

    /// Checks that the format and container go together.
    public func validate() throws(ExportError) {
        guard format.supportedContainers.contains(container) else {
            throw .invalidSettings(
                "\(format.displayName) can't be written to .\(container.fileExtension); use "
                    + format.supportedContainers.map { ".\($0.fileExtension)" }.joined(separator: " or ") + "."
            )
        }
        if let maxLongEdge, maxLongEdge < 2 {
            throw .invalidSettings("maxLongEdge must be at least 2 pixels.")
        }
        if let maxShortEdge, maxShortEdge < 2 {
            throw .invalidSettings("maxShortEdge must be at least 2 pixels.")
        }
    }

    static func roundedToEven(_ value: CGFloat) -> CGFloat {
        max(2, 2 * (value / 2).rounded())
    }
}
