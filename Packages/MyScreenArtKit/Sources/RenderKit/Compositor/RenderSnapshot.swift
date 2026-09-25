import AVFoundation
import CoreImage
import Foundation
import ProjectKit

/// Track IDs inside a built `AVComposition`.
public struct CompositionTrackIDs: Sendable, Equatable {
    public var screen: CMPersistentTrackID
    public var webcam: CMPersistentTrackID?
    public var systemAudio: CMPersistentTrackID?
    public var microphone: CMPersistentTrackID?

    public init(
        screen: CMPersistentTrackID, webcam: CMPersistentTrackID? = nil, systemAudio: CMPersistentTrackID? = nil,
        microphone: CMPersistentTrackID? = nil
    ) {
        self.screen = screen
        self.webcam = webcam
        self.systemAudio = systemAudio
        self.microphone = microphone
    }

    /// Video tracks the compositor reads.
    public var videoTrackIDs: [CMPersistentTrackID] { [screen] + (webcam.map { [$0] } ?? []) }
}

/// Derived data that depends only on the recording and the cursor smoothing, reused across snapshots.
final class ProjectResources: Sendable {
    let package: RecordingPackage
    let meta: RecordingMeta
    let events: [InputEvent]
    let cursorImages: CursorImageCache
    private let tracks = LockedDictionary<CursorSmoothing, CursorTrack>()
    private let followTracks = LockedDictionary<CursorSmoothing, FollowCameraTrack>()
    private let fills = LockedDictionary<String, CIImage>()

    init(project: RenderProject) {
        package = project.package
        meta = project.meta
        events = project.events
        cursorImages = CursorImageCache(package: project.package, index: project.cursorIndex)
    }

    func cursorTrack(smoothing: CursorSmoothing) -> CursorTrack {
        if let track = tracks[smoothing] { return track }
        let track = CursorTrack(events: events, smoothing: smoothing)
        tracks[smoothing] = track
        return track
    }

    /// The follow-mouse camera tracks the smoothed cursor (at least `.medium` smoothing so it's calm).
    func followTrack(smoothing: CursorSmoothing) -> FollowCameraTrack {
        let s: CursorSmoothing = smoothing == .none || smoothing == .rapid ? .medium : smoothing
        if let track = followTracks[s] { return track }
        let track = FollowCameraTrack(cursor: cursorTrack(smoothing: s))
        followTracks[s] = track
        return track
    }

    /// Background image files, decoded once per path.
    func imageFill(path: String) -> CIImage? {
        if let image = fills[path] { return image }
        guard let image = CIImage(contentsOf: URL(filePath: path)) else { return nil }
        let cached = image.insertingIntermediate(cache: true)
        fills[path] = cached
        return cached
    }
}

/// An immutable description of how to render every frame for one `EditConfig`.
///
/// The editor makes a new snapshot for each edit and hands it to AVFoundation inside a new video composition,
/// so the compositor (running on AVFoundation's queues) never sees mutable state.
final class RenderSnapshot: Sendable {
    let edit: EditConfig
    let timeline: EditTimeline
    let layout: CanvasLayout
    let trackIDs: CompositionTrackIDs
    let zoom: ZoomEvaluator
    /// Present when the cursor overlay is enabled and there are events.
    let cursorTrack: CursorTrack?
    let resources: ProjectResources
    /// Static background (fill + content shadow), in canvas pixels (Core Image, y up), or nil when disabled.
    /// Built on first use (on the compositor's queue), so snapshots made during slider drags that are never drawn
    /// don't render their shadows.
    var backgroundLayer: CIImage? { background.value { backgroundRenderer.backgroundLayer() } }
    private let backgroundRenderer: BackgroundRenderer
    private let background = LockedLazy<CIImage?>()
    /// Rounded-rect alpha mask for the content, or nil when corners are square.
    let contentMask: CIImage?

    init(
        edit: EditConfig, timeline: EditTimeline, layout: CanvasLayout, trackIDs: CompositionTrackIDs,
        resources: ProjectResources
    ) {
        self.edit = edit
        self.timeline = timeline
        self.layout = layout
        self.trackIDs = trackIDs
        self.resources = resources
        let track: CursorTrack? =
            edit.cursor.enabled && !resources.events.isEmpty
            ? resources.cursorTrack(smoothing: edit.cursor.smoothing) : nil
        cursorTrack = track
        let follow =
            ZoomEvaluator.needsFollowTrack(edit.zoom) && !resources.events.isEmpty
            ? resources.followTrack(smoothing: edit.cursor.smoothing) : nil
        zoom = ZoomEvaluator(settings: edit.zoom, follow: follow)
        backgroundRenderer = BackgroundRenderer(layout: layout, settings: edit.background, resources: resources)
        contentMask = backgroundRenderer.contentMask()
    }

    /// Webcam overlay mask and shadow for one camera size (static for a snapshot).
    struct WebcamOverlay: Sendable {
        let frame: CGRect
        let frameCI: CGRect
        /// Rounded-rect alpha mask (analytic), or nil for square corners.
        let mask: CIImage?
        /// The drop shadow, rendered once into a texture.
        let shadow: CIImage?
    }

    private struct CameraSizeKey: Hashable, Sendable {
        let width: Int
        let height: Int
    }

    private let webcamOverlays = LockedDictionary<CameraSizeKey, WebcamOverlay>()

    /// The webcam geometry, mask and shadow for `cameraSize`, built once.
    func webcamOverlay(cameraSize: CGSize) -> WebcamOverlay {
        let key = CameraSizeKey(width: Int(cameraSize.width), height: Int(cameraSize.height))
        if let cached = webcamOverlays[key] { return cached }
        let settings = edit.webcam
        let frame = WebcamLayout.frame(for: settings, cameraSize: cameraSize, canvasSize: layout.canvasSize)
        let frameCI = CIHelpers.flip(frame, height: layout.canvasSize.height)
        let radius = WebcamLayout.cornerRadius(for: settings, frame: frame)
        let shape = CIHelpers.roundedRect(frameCI, radius: radius, color: CIColor(red: 1, green: 1, blue: 1))
        // CSS-like `0 4px 12px rgba(0,0,0,.3)` in 1080p units.
        let unit = layout.outputUnit
        let shadow =
            settings.shadow
            ? RenderContext.rasterize(CIHelpers.shadow(of: shape, sigma: 6 * unit, offsetDown: 4 * unit, opacity: 0.3))
            : nil
        let overlay = WebcamOverlay(frame: frame, frameCI: frameCI, mask: radius >= 0.5 ? shape : nil, shadow: shadow)
        webcamOverlays[key] = overlay
        return overlay
    }

    var sourceSize: CGSize { layout.sourceSize }
    /// Screen pixels per point (cursor artwork and highlight radii are in points).
    var screenScale: Double { max(resources.meta.screen.scale, 0.1) }

    /// Source (session) seconds for an edited-timeline time.
    func sourceTime(forEdited t: Double) -> Double { timeline.sourceTime(forEdited: t) }
}
