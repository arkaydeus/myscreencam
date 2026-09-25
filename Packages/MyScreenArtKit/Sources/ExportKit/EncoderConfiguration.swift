import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox

/// AVFoundation settings dictionaries for the reader outputs and writer inputs.
enum EncoderConfiguration {
    static let audioSampleRate = 48_000.0
    static let audioChannels = 2
    static let aacBitRate = 192_000

    /// Pixel buffer attributes for `AVAssetReaderVideoCompositionOutput`: the format's compositor pixel
    /// format, IOSurface-backed and Metal-compatible so frames stay on the GPU.
    static func readerVideoSettings(for format: ExportFormat) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: format.compositorPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    /// Decoded audio from `AVAssetReaderAudioMixOutput`: 48 kHz stereo interleaved Float32.
    static var readerAudioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannels,
            AVChannelLayoutKey: stereoLayout,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Writer audio settings for the settings' audio codec.
    static func writerAudioSettings(for codec: ExportAudioCodec) -> [String: Any] {
        switch codec {
        case .aac:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannels,
                AVChannelLayoutKey: stereoLayout,
                AVEncoderBitRateKey: aacBitRate,
            ]
        case .linearPCM:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannels,
                AVChannelLayoutKey: stereoLayout,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }

    /// Writer video settings: codec, size, BT.709 tags, VideoToolbox encoder specification and, for
    /// H.264/HEVC, bitrate, profile, 2 s keyframe interval and the expected frame rate.
    static func writerVideoSettings(
        for settings: ExportSettings,
        size: CGSize,
        requireHardware: Bool
    ) -> [String: Any] {
        let fps = settings.effectiveFrameRate.framesPerSecond
        var output: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoEncoderSpecificationKey: encoderSpecification(requireHardware: requireHardware),
        ]
        var compression: [String: Any] = [:]
        if let bitRate = settings.videoBitRate(forOutputSize: size) {
            compression[AVVideoAverageBitRateKey] = bitRate
            compression[AVVideoExpectedSourceFrameRateKey] = fps
            compression[AVVideoMaxKeyFrameIntervalKey] = fps * 2
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2.0
            compression[AVVideoAllowFrameReorderingKey] = true
        }
        switch settings.format {
        case .h264:
            output[AVVideoCodecKey] = AVVideoCodecType.h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        case .hevc:
            output[AVVideoCodecKey] = AVVideoCodecType.hevc
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .hevc10bit:
            output[AVVideoCodecKey] = AVVideoCodecType.hevc
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .proRes422:
            output[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .gif:
            break
        }
        if !compression.isEmpty {
            output[AVVideoCompressionPropertiesKey] = compression
        }
        return output
    }

    static func encoderSpecification(requireHardware: Bool) -> [String: Any] {
        requireHardware
            ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
            : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
    }

    /// Whether VideoToolbox has a hardware encoder for the format at this size. Decides between
    /// requiring hardware and merely preferring it (graceful software fallback).
    static func hasHardwareEncoder(for format: ExportFormat, size: CGSize) -> Bool {
        let codec: CMVideoCodecType
        switch format {
        case .h264: codec = kCMVideoCodecType_H264
        case .hevc, .hevc10bit: codec = kCMVideoCodecType_HEVC
        case .proRes422: codec = kCMVideoCodecType_AppleProRes422
        case .gif: return false
        }
        let specification =
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        var encoderID: CFString?
        var properties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: Int32(size.width),
            height: Int32(size.height),
            codecType: codec,
            encoderSpecification: specification,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &properties
        )
        return status == noErr
    }

    private static var stereoLayout: Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
}
