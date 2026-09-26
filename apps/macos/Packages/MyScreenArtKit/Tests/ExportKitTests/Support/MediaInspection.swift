import AVFoundation
import Foundation
import ImageIO
import Testing

@testable import ExportKit

/// What AVFoundation reports about an exported movie.
struct MovieInfo {
    var codec: String
    var size: CGSize
    var nominalFrameRate: Float
    var duration: Double
    var audioFormat: AudioFormatID?
    var isPlayable: Bool
    var colorPrimaries: String?
    var transferFunction: String?
    var yCbCrMatrix: String?
    var bitsPerComponent: Int?
    /// Whether `moov` precedes `mdat` (fast start).
    var isFastStart: Bool

    static func load(_ url: URL) async throws -> MovieInfo {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (formats, size, fps) = try await track.load(.formatDescriptions, .naturalSize, .nominalFrameRate)
        let format = try #require(formats.first)
        let duration = try await asset.load(.duration).seconds
        let playable = try await asset.load(.isPlayable)

        var audioFormat: AudioFormatID?
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
            let description = try await audio.load(.formatDescriptions).first,
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        {
            audioFormat = asbd.pointee.mFormatID
        }

        func string(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
        }
        return MovieInfo(
            codec: fourCC(CMFormatDescriptionGetMediaSubType(format)),
            size: size,
            nominalFrameRate: fps,
            duration: duration,
            audioFormat: audioFormat,
            isPlayable: playable,
            colorPrimaries: string(kCMFormatDescriptionExtension_ColorPrimaries),
            transferFunction: string(kCMFormatDescriptionExtension_TransferFunction),
            yCbCrMatrix: string(kCMFormatDescriptionExtension_YCbCrMatrix),
            bitsPerComponent: (CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue,
            isFastStart: try moovPrecedesMdat(url)
        )
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Walks the top-level ISO BMFF boxes.
    static func moovPrecedesMdat(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            let header = try #require(try handle.read(upToCount: 16))
            var size = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if size == 1, header.count >= 16 {
                size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            } else if size == 0 {
                size = fileSize - offset
            }
            if type == "moov" { return true }
            if type == "mdat" { return false }
            guard size >= 8 else { return false }
            offset += size
        }
        return false
    }
}

/// What ImageIO reports about an exported GIF.
struct GIFInfo {
    var frameCount: Int
    var size: CGSize
    var loopCount: Int?
    var totalDelay: Double

    static func load(_ url: URL) throws -> GIFInfo {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        var totalDelay = 0.0
        for index in 0..<count {
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let frameGIF = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay =
                (frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (frameGIF?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            totalDelay += delay
        }
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Decode the last frame too, so a corrupt stream fails here.
        _ = try #require(CGImageSourceCreateImageAtIndex(source, max(0, count - 1), nil))
        return GIFInfo(
            frameCount: count,
            size: CGSize(width: first.width, height: first.height),
            loopCount: gif?[kCGImagePropertyGIFLoopCount] as? Int,
            totalDelay: totalDelay)
    }
}

/// Collects a job's progress stream.
func collectProgress(_ job: ExportJob) -> Task<[ExportProgress], Never> {
    Task {
        var values: [ExportProgress] = []
        for await value in job.progress { values.append(value) }
        return values
    }
}

/// Files in `directory`, including hidden ones (the exporter's temporary files are hidden).
func filesIn(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}
