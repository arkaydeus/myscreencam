import AVFoundation
import CoreAudio
import VideoToolbox

/// Video codec for `screen.mov` and `webcam.mov`.
public enum VideoCodec: String, Sendable, Hashable, CaseIterable, Codable {
    /// HEVC Main (default): best size/quality, hardware-encoded on Apple silicon.
    case hevc
    case h264
    /// ProRes 422 Proxy: large files, cheapest to scrub and re-encode.
    case proRes422Proxy

    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes422Proxy: .proRes422Proxy
        }
    }

    /// Sample-description four-character code, as stored in `ScreenStreamInfo.codec`.
    public var fourCC: String {
        switch self {
        case .hevc: "hvc1"
        case .h264: "avc1"
        case .proRes422Proxy: "apco"
        }
    }
}

/// `AVAssetWriterInput` output settings for the recorder.
enum EncoderSettings {
    /// Average bitrate from pixel rate: `width × height × fps × bitsPerPixel`, clamped to 2…80 Mbit/s.
    /// Screen content compresses well; camera content (sensor noise) needs roughly 1.6× more.
    static func averageBitRate(codec: VideoCodec, width: Int, height: Int, frameRate: Int, isCamera: Bool) -> Int {
        let bitsPerPixel = (codec == .h264 ? 0.08 : 0.05) * (isCamera ? 1.6 : 1)
        let raw = Double(width * height * max(frameRate, 1)) * bitsPerPixel
        return Int(min(max(raw, 2_000_000), 80_000_000))
    }

    /// Hardware real-time video encoding with ~1 s keyframe spacing (responsive scrubbing) and no frame
    /// reordering (lower latency, simpler VFR timing). BT.709 tags match the capture colour matrix.
    static func video(
        codec: VideoCodec, width: Int, height: Int, frameRate: Int, isCamera: Bool
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ],
        ]
        guard codec != .proRes422Proxy else { return settings }
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitRate(
                codec: codec, width: width, height: height, frameRate: frameRate, isCamera: isCamera),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoAllowFrameReorderingKey: false,
            kVTCompressionPropertyKey_RealTime as String: true,
            kVTCompressionPropertyKey_MaximizePowerEfficiency as String: true,
        ]
        compression[AVVideoProfileLevelKey] =
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel
        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
    }

    /// Drops the VideoToolbox-specific keys if this OS's writer rejects them.
    static func validated(_ settings: [String: Any], for writer: AVAssetWriter) -> [String: Any] {
        if writer.canApply(outputSettings: settings, forMediaType: .video) { return settings }
        var fallback = settings
        if var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] {
            compression[kVTCompressionPropertyKey_RealTime as String] = nil
            compression[kVTCompressionPropertyKey_MaximizePowerEfficiency as String] = nil
            fallback[AVVideoCompressionPropertiesKey] = compression
        }
        fallback[AVVideoEncoderSpecificationKey] = nil
        return fallback
    }

    /// AAC-LC at 48 kHz, mono or stereo (more source channels are downmixed to stereo).
    static func aac(sourceChannels: Int) -> [String: Any] {
        let channels = sourceChannels <= 1 ? 1 : 2
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 160_000 : 192_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }
}
