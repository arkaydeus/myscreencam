import AVFoundation
import CoreGraphics
import Foundation
import ProjectKit

/// The editor's handle on the render engine: owns the current `BuiltComposition` and makes cheap updates.
///
/// Typical editor use:
/// ```swift
/// let renderer = try await ProjectRenderer(project: project, options: .preview(maxSize: backingSize))
/// player.replaceCurrentItem(with: renderer.makePlayerItem())
/// meterLayer.levels = renderer.audioLevels            // read ~30 Hz from a display link
///
/// // After every edit:
/// let kind = try await renderer.update(edit: newEdit)
/// renderer.apply(kind, to: player)
/// ```
/// `apply` reassigns `playerItem.videoComposition` / `audioMix` for render-state changes (and, when paused,
/// re-seeks to the current time with zero tolerance so the frame on screen re-renders), or swaps in a new
/// player item at the same source position when the composition itself changed (segments / webcam sync).
@MainActor
public final class ProjectRenderer {
    /// What an update changed, and so what the player needs.
    public struct UpdateKind: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// A new `videoComposition` (effects, layout, size, frame rate).
        public static let videoComposition = UpdateKind(rawValue: 1 << 0)
        /// A new `audioMix` (volumes, mute, gain).
        public static let audioMix = UpdateKind(rawValue: 1 << 1)
        /// A new `composition` (segments or webcam sync offset): make a new player item.
        public static let composition = UpdateKind(rawValue: 1 << 2)
    }

    public private(set) var project: RenderProject
    public private(set) var options: RenderOptions
    /// The current composition, video composition, audio mix and layout.
    public private(set) var built: BuiltComposition
    /// Meter levels written by the preview audio taps while `isMetering`.
    public let audioLevels = AudioLevels()
    /// Whether the preview audio mix meters every audio track into `audioLevels`. Each meter is an
    /// `MTAudioProcessingTap` running on the audio thread, so turn it on only while meters are on screen. Tracks
    /// with gain above 0 dB get a tap either way.
    public private(set) var isMetering: Bool

    private let resources: ProjectResources
    private var assembled: CompositionBuilder.Assembled

    /// Builds the initial composition for `project`.
    public init(project: RenderProject, options: RenderOptions, metering: Bool = false) async throws {
        let resources = ProjectResources(project: project)
        let assembled = try await CompositionBuilder.assemble(project: project)
        self.project = project
        self.options = options
        self.resources = resources
        self.assembled = assembled
        isMetering = metering
        built = CompositionBuilder.finish(
            assembled, edit: project.edit, options: options, resources: resources,
            levels: metering ? audioLevels : nil)
    }

    public var composition: AVComposition { built.composition }
    public var videoComposition: AVVideoComposition { built.videoComposition }
    public var audioMix: AVAudioMix { built.audioMix }
    public var layout: CanvasLayout { built.layout }
    public var geometry: PreviewGeometry { built.geometry }
    public var timeline: EditTimeline { built.timeline }

    /// A player item for the current composition, with video composition and audio mix applied.
    public func makePlayerItem() -> AVPlayerItem { built.makePlayerItem() }

    /// Applies a new edit, rebuilding only what changed.
    ///
    /// Safe to call rapidly: if a newer update starts while a composition rebuild is awaiting, the older call
    /// returns `[]` and the newer one wins. On error the previous state is kept.
    @discardableResult
    public func update(edit: EditConfig) async throws -> UpdateKind {
        let old = project.edit
        guard edit != old else { return [] }
        updateGeneration += 1
        let generation = updateGeneration
        var kind: UpdateKind = []
        if edit.segments != old.segments || edit.webcam.syncOffset != old.webcam.syncOffset {
            var next = project
            next.edit = edit
            let newAssembled = try await CompositionBuilder.assemble(project: next)
            guard generation == updateGeneration else { return [] }
            timelineBeforeRecompose = timelineBeforeRecompose ?? built.timeline
            assembled = newAssembled
            kind = [.composition, .videoComposition, .audioMix]
        } else {
            if edit.audio != old.audio { kind.insert(.audioMix) }
            var visualOld = old
            visualOld.audio = edit.audio
            if visualOld != edit { kind.insert(.videoComposition) }
        }
        project.edit = edit
        rebuild(kind)
        return kind
    }

    private var updateGeneration = 0

    /// Changes the output size (e.g. the preview view resized) or frame rate. Only the video composition changes.
    @discardableResult
    public func update(options newOptions: RenderOptions) -> UpdateKind {
        guard newOptions != options else { return [] }
        let purposeChanged = newOptions.purpose != options.purpose
        options = newOptions
        let kind: UpdateKind = purposeChanged ? [.videoComposition, .audioMix] : [.videoComposition]
        rebuild(kind)
        return kind
    }

    /// Turns metering on or off (see `isMetering`); returns `.audioMix` when the mix changed.
    @discardableResult
    public func setMetering(_ metering: Bool) -> UpdateKind {
        guard metering != isMetering else { return [] }
        isMetering = metering
        if !metering { audioLevels.reset() }
        rebuild(.audioMix)
        return .audioMix
    }

    private func rebuild(_ kind: UpdateKind) {
        guard !kind.isEmpty else { return }
        // Audio-only changes keep the render snapshot (and the static layers it has already rendered).
        let snapshot =
            kind.contains(.videoComposition) || kind.contains(.composition)
            ? CompositionBuilder.makeSnapshot(
                assembled: assembled, edit: project.edit, options: options, resources: resources) : built.snapshot
        built = CompositionBuilder.finish(
            assembled, snapshot: snapshot, edit: project.edit, options: options,
            levels: isMetering ? audioLevels : nil, audioMix: kind.contains(.audioMix) ? nil : built.audioMix)
    }

    /// Applies an update to a player showing this renderer's composition.
    ///
    /// - `.composition`: replaces the item with a new one, restoring the same *source* moment (snapped forward if
    ///   it was cut) and the play rate.
    /// - otherwise: reassigns `videoComposition` / `audioMix` on the current item; when paused, seeks to the
    ///   current time with zero tolerance so the visible frame re-renders with the new state.
    public func apply(_ kind: UpdateKind, to player: AVPlayer) {
        guard !kind.isEmpty else { return }
        if kind.contains(.composition) || player.currentItem == nil {
            let edited = player.currentItem?.currentTime().seconds ?? 0
            let rate = player.rate
            var target = edited.isFinite ? edited : 0
            if let old = timelineBeforeRecompose {
                target = built.timeline.editedTimeSnapping(forSource: old.sourceTime(forEdited: target))
            }
            timelineBeforeRecompose = nil
            player.replaceCurrentItem(with: makePlayerItem())
            player.seek(
                to: CompositionBuilder.time(min(max(target, 0), built.timeline.duration)), toleranceBefore: .zero,
                toleranceAfter: .zero)
            if rate != 0 { player.rate = rate }
        } else if let item = player.currentItem {
            if kind.contains(.videoComposition) { item.videoComposition = built.videoComposition }
            if kind.contains(.audioMix) { item.audioMix = built.audioMix }
            if kind.contains(.videoComposition), player.rate == 0 { Self.refreshCurrentFrame(of: player) }
        }
    }

    /// The timeline the player was showing before the first unapplied composition change.
    private var timelineBeforeRecompose: EditTimeline?

    /// Re-renders the frame on screen while paused (zero-tolerance seek to the current time).
    public static func refreshCurrentFrame(of player: AVPlayer) {
        guard let item = player.currentItem else { return }
        player.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Queries for the editor UI

    /// Source (session) seconds for an edited-timeline time.
    public func sourceTime(forEdited t: Double) -> Double { built.timeline.sourceTime(forEdited: t) }

    /// The zoom applied at a source time, relative to the layout's crop (for mapping preview clicks through it).
    public func zoomState(atSource t: Double) -> ZoomState { built.snapshot.zoom.state(at: t) }

    /// The displayed cursor position at a source time (normalised), if the cursor overlay is on.
    public func cursorPosition(atSource t: Double) -> NormPoint? { built.snapshot.cursorTrack?.position(at: t) }
}
