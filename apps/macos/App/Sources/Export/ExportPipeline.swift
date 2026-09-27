import AVFoundation
import ExportKit
import Foundation
import MyScreenCamCore
import ProjectKit
import RenderKit

// Export orchestration: settings → RenderKit options → a composition ExportKit can encode.
//
// Only engine modules are used here (no app types), so a headless harness can compile this file on its own.

/// How the renderer must be sized so its canvas is exactly the export frame size.
nonisolated struct ExportSizing: Equatable, Sendable {
    /// The frame size ExportKit will encode (`ExportSettings.outputSize(forSource:)` of the natural canvas).
    var outputSize: CGSize
    /// The sizing to hand RenderKit. `CanvasLayout.make(…, sizing:)` yields `renderSize`.
    var renderSizing: RenderSizing
    /// The canvas RenderKit will produce with `renderSizing`. Equal to `outputSize` except in rare rounding
    /// corner cases, where it differs by at most one even step (still encodable).
    var renderSize: CGSize

    /// Plans the render size for `settings`.
    ///
    /// RenderKit sizes its canvas from the *natural* canvas (the source, widened to the background's aspect ratio
    /// when one is set) times a factor, rounding each side to even pixels. The unrounded natural canvas is fed to
    /// `outputSize(forSource:)` (the user's scale, the preset's long/short edge caps — e.g. GIF's 720 px — and the
    /// codec's maximum), then a RenderKit sizing that reproduces that size exactly is picked by checking candidates
    /// with the pure `CanvasLayout.make`.
    static func plan(sourceSize: CGSize, background: BackgroundSettings, settings: ExportSettings) -> ExportSizing {
        let natural = naturalCanvas(sourceSize: sourceSize, background: background)
        let target = settings.outputSize(forSource: natural)

        func canvas(_ sizing: RenderSizing) -> CGSize {
            CanvasLayout.make(sourceSize: sourceSize, background: background, sizing: sizing).canvasSize
        }
        let widthScale = target.width / max(natural.width, 1)
        let heightScale = target.height / max(natural.height, 1)
        var candidates: [RenderSizing] = [
            .scale(exportFactor(natural: natural, settings: settings)),
            .scale(widthScale), .scale(heightScale), .scale((widthScale + heightScale) / 2),
            .fit(width: target.width, height: target.height),
        ]
        // Nudge by fractions of a pixel for the odd case where rounding lands one even step off.
        for step in [-0.75, -0.5, -0.25, 0.25, 0.5, 0.75] {
            candidates.append(.scale(widthScale + step / max(natural.width, 1)))
            candidates.append(.scale(heightScale + step / max(natural.height, 1)))
        }
        var best: (sizing: RenderSizing, size: CGSize, error: Double)?
        for candidate in candidates {
            let size = canvas(candidate)
            if size == target {
                return ExportSizing(outputSize: target, renderSizing: candidate, renderSize: size)
            }
            let error = abs(size.width - target.width) + abs(size.height - target.height)
            if error < (best?.error ?? .infinity) { best = (candidate, size, error) }
        }
        let fallback = best ?? (.fit(width: target.width, height: target.height), target, 0)
        return ExportSizing(outputSize: target, renderSizing: fallback.sizing, renderSize: fallback.size)
    }

    /// The factor `ExportSettings.outputSize(forSource:)` applies before rounding: the user's scale, then a fit
    /// inside the preset's long/short edge caps and the codec's maximum (never upscaling).
    static func exportFactor(natural: CGSize, settings: ExportSettings) -> Double {
        let scale = settings.scale.rawValue
        let longEdge = max(natural.width, natural.height) * scale
        let shortEdge = min(natural.width, natural.height) * scale
        let codec = settings.format.maximumDimensions
        let longLimit = min(Double(settings.maxLongEdge ?? .max), Double(codec.longEdge))
        let shortLimit = min(Double(settings.maxShortEdge ?? .max), Double(codec.shortEdge))
        return scale * min(1, longLimit / max(longEdge, 1), shortLimit / max(shortEdge, 1))
    }

    /// The canvas at 100 % before even-rounding, as `CanvasLayout.make` computes it: the source, widened or
    /// heightened to the background's aspect ratio when a background with a fixed aspect is on.
    static func naturalCanvas(sourceSize: CGSize, background: BackgroundSettings) -> CGSize {
        let width = max(sourceSize.width, 1)
        let height = max(sourceSize.height, 1)
        guard background.enabled, let ratio = background.aspect.ratio else {
            return CGSize(width: width, height: height)
        }
        return ratio >= width / height
            ? CGSize(width: height * ratio, height: height) : CGSize(width: width, height: width / ratio)
    }
}

/// A composition ready for `VideoExporter.start`.
nonisolated struct PreparedExport: @unchecked Sendable {
    // AVFoundation objects here are immutable copies that are never mutated after preparation.
    /// The composition with inaudible (disabled or muted) audio tracks removed, so ExportKit — which mixes
    /// every audio track of the asset — exports only what the editor plays.
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    /// The editor's audio mix restricted to the remaining tracks, or nil when nothing is audible.
    let audioMix: AVAudioMix?
    let renderSize: CGSize
    /// Edited duration in seconds.
    let duration: Double
    let hasAudio: Bool
    /// The settings to encode with (`includesAudio` is cleared when no track is audible).
    let settings: ExportSettings
}

nonisolated enum ExportPipeline {
    enum PipelineError: LocalizedError {
        case missingScreen

        var errorDescription: String? {
            switch self {
            case .missingScreen: "The recording's screen video is missing."
            }
        }
    }

    /// The source (screen) pixel size the renderer will use: the screen track's natural size, as
    /// `CompositionBuilder` does, falling back to the metadata.
    @concurrent
    static func sourceSize(of package: RecordingPackage, meta: RecordingMeta) async -> CGSize {
        let fallback = CGSize(width: meta.screen.pixelWidth, height: meta.screen.pixelHeight)
        let asset = AVURLAsset(url: package.url(for: .screen))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let natural = try? await track.load(.naturalSize), natural.width > 0, natural.height > 0
        else { return fallback }
        return natural
    }

    /// Loads the project, builds the export composition at the export size and frame rate, and strips
    /// inaudible audio. Runs off the main actor (file I/O and asset loading).
    @concurrent
    static func prepare(package: RecordingPackage, edit: EditConfig, settings: ExportSettings) async throws
        -> PreparedExport
    {
        guard FileManager.default.fileExists(atPath: package.url(for: .screen).path) else {
            throw PipelineError.missingScreen
        }
        var project = try RenderProject.load(package)
        project.edit = edit
        try Task.checkCancellation()

        let source = await sourceSize(of: package, meta: project.meta)
        let sizing = ExportSizing.plan(sourceSize: source, background: edit.background, settings: settings)
        let options = RenderOptions(
            purpose: .export, frameRate: settings.effectiveFrameRate.framesPerSecond, sizing: sizing.renderSizing)
        let built = try await CompositionBuilder.build(project: project, options: options)
        try Task.checkCancellation()
        if built.renderSize != sizing.outputSize {
            Log.app.info(
                "Export canvas \(Int(built.renderSize.width))×\(Int(built.renderSize.height)) differs from the planned \(Int(sizing.outputSize.width))×\(Int(sizing.outputSize.height))"
            )
        }

        // ExportKit reads every audio track of the asset, so hand it a copy without the inaudible ones.
        let audible = Set(built.audibleAudioTrackIDs)
        guard let composition = built.composition.mutableCopy() as? AVMutableComposition else {
            throw PipelineError.missingScreen
        }
        for track in composition.tracks where track.mediaType == .audio && !audible.contains(track.trackID) {
            composition.removeTrack(track)
        }
        let hasAudio = composition.tracks.contains { $0.mediaType == .audio }
        var audioMix: AVAudioMix?
        if hasAudio {
            let mix = AVMutableAudioMix()
            mix.inputParameters = built.audioMix.inputParameters.filter { audible.contains($0.trackID) }
            audioMix = mix.copy() as? AVAudioMix ?? mix
        }
        var settings = settings
        if !hasAudio { settings.includesAudio = false }

        return PreparedExport(
            asset: composition.copy() as? AVComposition ?? composition,
            videoComposition: built.videoComposition,
            audioMix: audioMix,
            renderSize: built.renderSize,
            duration: built.duration.seconds,
            hasAudio: hasAudio,
            settings: settings)
    }

    /// A rough file-size estimate in bytes for the export dialog.
    static func estimatedFileSize(
        settings: ExportSettings, outputSize: CGSize, duration: Double, hasAudio: Bool
    ) -> Int64 {
        let seconds = max(0, duration)
        let fps = Double(settings.effectiveFrameRate.framesPerSecond)
        let pixels = Double(outputSize.width * outputSize.height)
        var videoBitsPerSecond: Double
        switch settings.format {
        case .h264, .hevc, .hevc10bit:
            // Screen recordings are mostly static, so the average lands under the target bitrate.
            videoBitsPerSecond = Double(settings.videoBitRate(forOutputSize: outputSize) ?? 0) * 0.8
        case .proRes422:
            // Apple's ProRes 422 target: ~147 Mbit/s at 1080p29.97, proportional to pixels × frame rate.
            videoBitsPerSecond = 147_000_000 * pixels / (1920 * 1080) * fps / 29.97
        case .gif:
            // Merged static frames and LZW on flat UI colour: about 0.4 bits per pixel per frame.
            videoBitsPerSecond = pixels * fps * 0.4
        }
        videoBitsPerSecond = max(0, videoBitsPerSecond)
        var audioBitsPerSecond = 0.0
        if hasAudio, settings.includesAudio {
            switch settings.audioCodec {
            case .aac: audioBitsPerSecond = 192_000
            case .linearPCM: audioBitsPerSecond = 48_000 * 24 * 2
            case nil: audioBitsPerSecond = 0
            }
        }
        return Int64((videoBitsPerSecond + audioBitsPerSecond) * seconds / 8)
    }
}
