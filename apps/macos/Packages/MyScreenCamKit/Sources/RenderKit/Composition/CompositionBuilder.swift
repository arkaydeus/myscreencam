import AVFoundation
import CoreGraphics
import Foundation
import MyScreenCamCore
import ProjectKit

/// A ready-to-play (or ready-to-export) composition.
///
/// `@unchecked Sendable`: every AVFoundation object here is an immutable copy (`AVComposition`,
/// `AVVideoComposition`, `AVAudioMix`) that is never mutated after the build.
public struct BuiltComposition: @unchecked Sendable {
    /// Screen, webcam, system audio and mic tracks, each cut with the same segments. Its time is edited time.
    public let composition: AVComposition
    /// Uses `VideoCompositor`; `renderSize` = `layout.canvasSize`; `frameDuration` = 1 / frame rate.
    public let videoComposition: AVVideoComposition
    /// Volumes and taps for the audio tracks.
    public let audioMix: AVAudioMix
    public let renderSize: CGSize
    /// Edited duration.
    public let duration: CMTime
    public let timeline: EditTimeline
    public let trackIDs: CompositionTrackIDs
    public let layout: CanvasLayout
    /// Audio tracks that are enabled and not muted (export mixes only these).
    public let audibleAudioTrackIDs: [CMPersistentTrackID]
    let snapshot: RenderSnapshot

    /// Hit-testing helpers for this layout.
    public var geometry: PreviewGeometry { PreviewGeometry(layout: layout) }

    /// A player item with the video composition and audio mix applied.
    @MainActor
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.seekingWaitsForVideoCompositionRendering = true
        return item
    }

    /// The composition's video tracks (for `AVAssetReaderVideoCompositionOutput(videoTracks:)`).
    public func videoTracks() async throws -> [AVAssetTrack] {
        try await composition.loadTracks(withMediaType: .video)
    }

    /// The audible audio tracks (for `AVAssetReaderAudioMixOutput(audioTracks:)`; empty = export no audio).
    public func audibleAudioTracks() async throws -> [AVAssetTrack] {
        try await composition.loadTracks(withMediaType: .audio).filter { audibleAudioTrackIDs.contains($0.trackID) }
    }
}

/// Turns a loaded project into an `AVComposition` + custom video composition + audio mix.
///
/// Changing segments or the webcam sync offset needs a new composition (`assemble`); anything else only needs a
/// new video composition / audio mix around a new `RenderSnapshot` (see `ProjectRenderer`).
public enum CompositionBuilder {
    /// Fixed track IDs inside the composition.
    public enum TrackID {
        public static let screen: CMPersistentTrackID = 1
        public static let webcam: CMPersistentTrackID = 2
        public static let systemAudio: CMPersistentTrackID = 3
        public static let microphone: CMPersistentTrackID = 4
    }

    static let timescale: CMTimeScale = 90_000

    /// Builds everything for `project`. `levels` receives meter data (preview only).
    public static func build(project: RenderProject, options: RenderOptions, levels: AudioLevels? = nil)
        async throws -> BuiltComposition
    {
        try Task.checkCancellation()
        let resources = ProjectResources(project: project)
        let assembled = try await assemble(project: project)
        try Task.checkCancellation()
        return finish(assembled, edit: project.edit, options: options, resources: resources, levels: levels)
    }

    // MARK: - Composition (segments + sync)

    /// The cut composition; depends only on the segments, stream offsets and the webcam sync offset.
    struct Assembled: @unchecked Sendable {
        let composition: AVComposition
        let trackIDs: CompositionTrackIDs
        let timeline: EditTimeline
        let sourceSize: CGSize
        let segments: [Segment]
        let webcamSyncOffset: Double

        var duration: CMTime { max(composition.duration, time(timeline.duration)) }
    }

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

    static func assemble(project: RenderProject) async throws -> Assembled {
        let timeline = EditTimeline(segments: project.edit.segments)
        guard timeline.duration > 0 else { throw RenderError.emptyTimeline }
        let package = project.package
        let available = package.availableStreams()
        guard available.contains(.screen) else { throw RenderError.missingScreenTrack }

        let composition = AVMutableComposition()
        var ids = CompositionTrackIDs(screen: TrackID.screen)
        var sourceSize = project.sourceSize

        func offset(_ kind: StreamKind) -> Double {
            (project.meta.streams[kind]?.startOffset ?? 0) + (kind == .webcam ? project.edit.webcam.syncOffset : 0)
        }

        let streams: [(StreamKind, AVMediaType, CMPersistentTrackID)] = [
            (.screen, .video, TrackID.screen), (.webcam, .video, TrackID.webcam),
            (.systemAudio, .audio, TrackID.systemAudio), (.microphone, .audio, TrackID.microphone),
        ]
        for (kind, mediaType, trackID) in streams where available.contains(kind) {
            try Task.checkCancellation()
            let asset = AVURLAsset(
                url: package.url(for: kind), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let source = try await asset.loadTracks(withMediaType: mediaType).first else {
                if kind == .screen { throw RenderError.missingScreenTrack }
                continue
            }
            try Task.checkCancellation()
            let sourceRange = try await source.load(.timeRange)
            try Task.checkCancellation()
            if kind == .screen {
                let natural = try await source.load(.naturalSize)
                if natural.width > 0, natural.height > 0 { sourceSize = natural }
            }
            guard let track = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: trackID) else {
                continue
            }
            let inserted = try insert(
                source: source, sourceRange: sourceRange, into: track, timeline: timeline, offset: offset(kind))
            if kind == .screen {
                // Pad to the full edited duration so the timeline length never depends on the screen file.
                let end = track.timeRange.end
                let total = time(timeline.duration)
                if end < total { track.insertEmptyTimeRange(CMTimeRange(start: end, end: total)) }
            } else if !inserted {
                composition.removeTrack(track)
                continue
            }
            switch kind {
            case .screen: break
            case .webcam: ids.webcam = trackID
            case .systemAudio: ids.systemAudio = trackID
            case .microphone: ids.microphone = trackID
            }
        }
        guard let immutable = composition.copy() as? AVComposition else { throw RenderError.missingScreenTrack }
        return Assembled(
            composition: immutable, trackIDs: ids, timeline: timeline, sourceSize: sourceSize,
            segments: project.edit.segments, webcamSyncOffset: project.edit.webcam.syncOffset)
    }

    /// Inserts each kept segment of a stream whose t=0 sits at session time `offset`. Parts of a segment the file
    /// doesn't cover stay empty. Returns whether anything was inserted.
    private static func insert(
        source: AVAssetTrack, sourceRange: CMTimeRange, into track: AVMutableCompositionTrack, timeline: EditTimeline,
        offset: Double
    ) throws -> Bool {
        let fileStart = sourceRange.start.seconds
        let fileEnd = sourceRange.end.seconds
        var inserted = false
        for piece in timeline.pieces {
            try Task.checkCancellation()
            // Session range → file range, clipped to what the file holds.
            let start = max(piece.segment.start - offset, fileStart)
            let end = min(piece.segment.end - offset, fileEnd)
            guard end - start > 1e-4 else { continue }
            let at = time(piece.editedStart + (start + offset - piece.segment.start))
            let trackEnd = track.timeRange.isValid ? track.timeRange.end : .zero
            if at > trackEnd { track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: at)) }
            let range = CMTimeRange(start: time(start), end: time(end))
            try track.insertTimeRange(range, of: source, at: at)
            inserted = true
        }
        return inserted
    }

    // MARK: - Render state (everything else)

    static func makeSnapshot(
        assembled: Assembled, edit: EditConfig, options: RenderOptions, resources: ProjectResources
    ) -> RenderSnapshot {
        let layout = CanvasLayout.make(
            sourceSize: assembled.sourceSize, background: edit.background, sizing: options.sizing)
        return RenderSnapshot(
            edit: edit, timeline: assembled.timeline, layout: layout, trackIDs: assembled.trackIDs,
            resources: resources)
    }

    static func makeVideoComposition(snapshot: RenderSnapshot, duration: CMTime, frameRate: Int) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = VideoCompositor.self
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        composition.renderSize = snapshot.layout.canvasSize
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.instructions = [
            RenderInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), snapshot: snapshot)
        ]
        return composition.copy() as? AVVideoComposition ?? composition
    }

    static func makeAudioMix(
        audio: AudioSettings, trackIDs: CompositionTrackIDs, purpose: RenderOptions.Purpose, levels: AudioLevels?
    ) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        var inputs: [AVAudioMixInputParameters] = []
        let tracks: [(CMPersistentTrackID?, TrackAudio, AudioTrackKind)] = [
            (trackIDs.systemAudio, audio.system, .systemAudio), (trackIDs.microphone, audio.microphone, .microphone),
        ]
        for case (let id?, let settings, let kind) in tracks {
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = id
            let gain = Float(settings.isAudible ? settings.linearGain : 0)
            let wantsTap = (purpose == .preview && levels != nil) || gain > 1
            if wantsTap,
                let tap = AudioTap.make(
                    gain: gain, limit: gain > 1, meter: purpose == .preview ? levels.map { ($0, kind) } : nil)
            {
                parameters.audioTapProcessor = tap
                parameters.setVolume(1, at: .zero)
            } else {
                parameters.setVolume(min(gain, 1), at: .zero)
            }
            inputs.append(parameters)
        }
        mix.inputParameters = inputs
        return mix.copy() as? AVAudioMix ?? mix
    }

    static func audibleTrackIDs(audio: AudioSettings, trackIDs: CompositionTrackIDs) -> [CMPersistentTrackID] {
        var ids: [CMPersistentTrackID] = []
        if let id = trackIDs.systemAudio, audio.system.isAudible { ids.append(id) }
        if let id = trackIDs.microphone, audio.microphone.isAudible { ids.append(id) }
        return ids
    }

    static func finish(
        _ assembled: Assembled, edit: EditConfig, options: RenderOptions, resources: ProjectResources,
        levels: AudioLevels?
    ) -> BuiltComposition {
        let snapshot = makeSnapshot(assembled: assembled, edit: edit, options: options, resources: resources)
        return finish(assembled, snapshot: snapshot, edit: edit, options: options, levels: levels)
    }

    static func finish(
        _ assembled: Assembled, snapshot: RenderSnapshot, edit: EditConfig, options: RenderOptions,
        levels: AudioLevels?, audioMix: AVAudioMix? = nil
    ) -> BuiltComposition {
        let duration = assembled.duration
        return BuiltComposition(
            composition: assembled.composition,
            videoComposition: makeVideoComposition(
                snapshot: snapshot, duration: duration, frameRate: options.frameRate),
            audioMix: audioMix
                ?? makeAudioMix(
                    audio: edit.audio, trackIDs: assembled.trackIDs, purpose: options.purpose, levels: levels),
            renderSize: snapshot.layout.canvasSize,
            duration: duration,
            timeline: assembled.timeline,
            trackIDs: assembled.trackIDs,
            layout: snapshot.layout,
            audibleAudioTrackIDs: audibleTrackIDs(audio: edit.audio, trackIDs: assembled.trackIDs),
            snapshot: snapshot)
    }
}
