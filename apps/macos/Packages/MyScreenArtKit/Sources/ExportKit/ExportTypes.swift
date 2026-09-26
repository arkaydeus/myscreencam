import CoreGraphics
import Foundation

/// Where an export is in its lifecycle.
public enum ExportStage: String, Codable, Sendable {
    /// Loading tracks, building the pipeline.
    case preparing
    /// Rendering and encoding frames.
    case encoding
    /// Flushing the encoder and writing the index (fast-start relocation).
    case finalizing
    /// The file is complete at its final URL.
    case finished
}

/// A progress snapshot. Emitted at most ~10 times a second, and on every stage change.
public struct ExportProgress: Sendable, Hashable {
    /// 0…1, never decreasing. Encoding covers 0…0.99; it reaches 1 only when the file is complete.
    public var fraction: Double
    public var stage: ExportStage
    /// A user-facing description of the stage, e.g. "Encoding video…".
    public var stageText: String
    /// Bytes written to the output so far.
    public var bytesWritten: Int64
    /// Video frames encoded so far (GIF: frames rendered).
    public var framesWritten: Int
    /// Seconds since the export started.
    public var elapsed: TimeInterval
    /// Estimated seconds left; `nil` until the estimate is meaningful.
    public var estimatedTimeRemaining: TimeInterval?

    public init(
        fraction: Double,
        stage: ExportStage,
        stageText: String,
        bytesWritten: Int64 = 0,
        framesWritten: Int = 0,
        elapsed: TimeInterval = 0,
        estimatedTimeRemaining: TimeInterval? = nil
    ) {
        self.fraction = fraction
        self.stage = stage
        self.stageText = stageText
        self.bytesWritten = bytesWritten
        self.framesWritten = framesWritten
        self.elapsed = elapsed
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
}

/// Which encoder produced the video.
public enum ExportEncoder: String, Codable, Sendable {
    /// VideoToolbox, with a hardware encoder required.
    case hardware
    /// VideoToolbox, hardware preferred. Used when no hardware encoder was found for the codec and size
    /// (e.g. ProRes on a Mac without a ProRes engine), so the encoder may be software.
    case bestAvailable
    /// ImageIO (GIF).
    case imageIO
}

/// A completed export.
public struct ExportResult: Sendable, Hashable {
    public var url: URL
    /// The file size in bytes.
    public var fileSize: Int64
    /// The output duration in seconds.
    public var duration: TimeInterval
    /// The encoded frame size in pixels.
    public var dimensions: CGSize
    /// Frames written. For GIF, identical consecutive frames are merged, so this can be lower than
    /// duration × fps.
    public var frameCount: Int
    /// Wall-clock seconds from `start` to completion.
    public var wallTime: TimeInterval
    public var encoder: ExportEncoder
    public var settings: ExportSettings

    public init(
        url: URL,
        fileSize: Int64,
        duration: TimeInterval,
        dimensions: CGSize,
        frameCount: Int,
        wallTime: TimeInterval,
        encoder: ExportEncoder,
        settings: ExportSettings
    ) {
        self.url = url
        self.fileSize = fileSize
        self.duration = duration
        self.dimensions = dimensions
        self.frameCount = frameCount
        self.wallTime = wallTime
        self.encoder = encoder
        self.settings = settings
    }
}

/// Why an export failed. Reader and writer failures carry AVFoundation's underlying error.
public enum ExportError: Error, LocalizedError, Sendable {
    /// The settings are inconsistent (e.g. ProRes in .mp4).
    case invalidSettings(String)
    /// The video composition's `renderSize` isn't positive, integral and even. Build the composition
    /// at `ExportSettings.outputSize(forSource:)`.
    case invalidRenderSize(CGSize)
    /// The asset has no video track.
    case noVideoTrack
    /// The asset's duration is zero or indefinite.
    case emptyAsset
    /// The output file couldn't be created or moved into place.
    case outputFailed(URL, underlying: (any Error)?)
    /// `AVAssetReader` (decoding or compositing) failed.
    case readerFailed(underlying: (any Error)?)
    /// `AVAssetWriter` (encoding or muxing) failed.
    case writerFailed(underlying: (any Error)?)
    /// ImageIO couldn't encode a GIF frame.
    case gifEncodingFailed(String)
    /// No frame was produced or encoded for this many seconds, so the export was abandoned rather than hang.
    case stalled(seconds: Double)
    /// `ExportJob.cancel()` was called. The partial file has been deleted.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidSettings(let message):
            "Invalid export settings: \(message)"
        case .invalidRenderSize(let size):
            "The video frame size \(Int(size.width))×\(Int(size.height)) can't be encoded; "
                + "both sides must be even whole numbers."
        case .noVideoTrack:
            "The recording has no video to export."
        case .emptyAsset:
            "The recording is empty."
        case .outputFailed(let url, let underlying):
            "Couldn't write \(url.lastPathComponent)"
                + (underlying.map { ": \($0.localizedDescription)" } ?? ".")
        case .readerFailed(let underlying):
            "Rendering the video failed" + (underlying.map { ": \($0.localizedDescription)" } ?? ".")
        case .writerFailed(let underlying):
            "Encoding the video failed" + (underlying.map { ": \($0.localizedDescription)" } ?? ".")
        case .gifEncodingFailed(let message):
            "Encoding the GIF failed: \(message)"
        case .stalled(let seconds):
            "The export stopped making progress for \(Int(seconds)) seconds and was stopped."
        case .cancelled:
            "The export was cancelled."
        }
    }

    /// The AVFoundation error behind a reader, writer or output failure.
    public var underlyingError: (any Error)? {
        switch self {
        case .outputFailed(_, let underlying), .readerFailed(let underlying), .writerFailed(let underlying):
            underlying
        default:
            nil
        }
    }
}
