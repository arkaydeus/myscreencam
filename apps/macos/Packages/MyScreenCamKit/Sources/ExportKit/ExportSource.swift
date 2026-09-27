import AVFoundation
import CoreGraphics

/// The loaded, validated input of an export: tracks, duration and the video composition to read through.
struct ExportSource: @unchecked Sendable {
    // AVAssetTrack and AVVideoComposition are immutable once loaded; they're only read from here on.
    let asset: AVAsset
    let videoTracks: [AVAssetTrack]
    let audioTracks: [AVAssetTrack]
    let duration: CMTime
    /// The composition the reader renders through, retimed to the export frame rate and tagged BT.709.
    let videoComposition: AVVideoComposition
    var renderSize: CGSize { videoComposition.renderSize }

    /// Loads the asset and prepares the video composition.
    ///
    /// - A caller-supplied composition is copied, its `frameDuration` set to the export rate and its
    ///   colour properties set to BT.709 (the output's colour space). Its `renderSize` must already be even (see
    ///   `ExportSettings.outputSize(forSource:)`); otherwise this throws `invalidRenderSize`.
    /// - Without one, a composition is built that scales the first video track (with its preferred
    ///   transform) to `settings.outputSize(forSource:)`.
    static func load(
        asset: AVAsset,
        videoComposition: AVVideoComposition?,
        settings: ExportSettings
    ) async throws(ExportError) -> ExportSource {
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks =
                settings.includesAudio && !settings.format.isGIF
                ? try await asset.loadTracks(withMediaType: .audio) : []
        } catch {
            throw .readerFailed(underlying: error)
        }
        guard duration.isNumeric, duration > .zero else { throw .emptyAsset }
        guard let firstVideo = videoTracks.first else { throw .noVideoTrack }

        let frameDuration = settings.effectiveFrameRate.frameDuration
        let composition: AVMutableVideoComposition
        if let videoComposition {
            guard let copy = videoComposition.mutableCopy() as? AVMutableVideoComposition else {
                throw .invalidSettings("The video composition couldn't be copied.")
            }
            composition = copy
        } else {
            composition = try await makeScalingComposition(
                track: firstVideo, duration: duration, settings: settings)
        }
        composition.frameDuration = frameDuration
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        // The file is tagged BT.709, so the composition must render BT.709 too.
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        guard ExportSettings.isEncodable(composition.renderSize) else {
            throw .invalidRenderSize(composition.renderSize)
        }
        return ExportSource(
            asset: asset,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            duration: duration,
            videoComposition: composition.copy() as? AVVideoComposition ?? composition
        )
    }

    private static func makeScalingComposition(
        track: AVAssetTrack,
        duration: CMTime,
        settings: ExportSettings
    ) async throws(ExportError) -> AVMutableVideoComposition {
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        do {
            (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
        } catch {
            throw .readerFailed(underlying: error)
        }
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        guard oriented.width >= 1, oriented.height >= 1 else { throw .noVideoTrack }
        let renderSize = settings.outputSize(forSource: oriented.size)
        let transform =
            preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(
                CGAffineTransform(
                    scaleX: renderSize.width / oriented.width, y: renderSize.height / oriented.height))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.instructions = [instruction]
        return composition
    }
}

/// The partially written file. Exports write to a hidden sibling and move it over the destination
/// only on success, so a cancelled or failed export never leaves a partial file or clobbers an
/// existing one.
struct OutputFile: Sendable {
    let finalURL: URL
    let temporaryURL: URL

    init(finalURL: URL) {
        self.finalURL = finalURL
        let directory = finalURL.deletingLastPathComponent()
        let token = UUID().uuidString.prefix(8)
        let name = ".\(finalURL.deletingPathExtension().lastPathComponent).export-\(token)"
        let pathExtension = finalURL.pathExtension
        temporaryURL = directory.appendingPathComponent(
            pathExtension.isEmpty ? name : "\(name).\(pathExtension)")
    }

    /// Ensures the directory exists and no stale temporary file is in the way.
    func prepare() throws(ExportError) {
        do {
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: temporaryURL)
        } catch {
            throw .outputFailed(finalURL, underlying: error)
        }
    }

    /// Deletes the partial file, and the scratch files AVAssetWriter keeps beside it
    /// (`<name>.sb-…`, left behind by `cancelWriting`). The temporary name is unique per job, so the
    /// prefix match can't touch anything else.
    func discard() {
        let manager = FileManager.default
        try? manager.removeItem(at: temporaryURL)
        let directory = temporaryURL.deletingLastPathComponent()
        let prefix = temporaryURL.lastPathComponent
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Moves the finished file into place, replacing any existing file. Returns its size in bytes.
    func commit() throws(ExportError) -> Int64 {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: finalURL.path) {
                _ = try manager.replaceItemAt(finalURL, withItemAt: temporaryURL)
            } else {
                try manager.moveItem(at: temporaryURL, to: finalURL)
            }
            let size = try finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return Int64(size)
        } catch {
            discard()
            throw .outputFailed(finalURL, underlying: error)
        }
    }
}
