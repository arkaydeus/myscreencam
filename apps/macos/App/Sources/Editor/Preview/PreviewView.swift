import AVFoundation
import AppKit
import ProjectKit
import RenderKit
import SwiftUI

/// The preview: an `AVPlayerLayer` (no controls) plus interactive overlays for dragging the webcam, moving and
/// resizing the selected blur mask, dragging the subtitle under the playhead (or its left/right edge, to set its
/// width), picking a zoom target, and drawing the crop.
struct PreviewContainer: View {
    let model: EditorModel

    var body: some View {
        PreviewRepresentable(model: model, state: PreviewOverlayState(model: model))
            .background(Color.themeStage)
            .overlay(alignment: .top) {
                if model.isPickingZoomTarget {
                    HStack(spacing: 8) {
                        Image(systemName: "scope")
                        Text("Click the preview to set the zoom target")
                        Button("Cancel") { model.isPickingZoomTarget = false }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
                } else if model.isEditingCrop {
                    HStack(spacing: 8) {
                        Image(systemName: "crop")
                        Text("Drag to choose the area to keep")
                        if model.edit.crop != nil {
                            Button("Reset") { model.setCrop(nil, "Reset Crop") }
                                .buttonStyle(.link)
                        }
                        Button("Done") { model.isEditingCrop = false }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
                }
            }
    }
}

/// Everything the overlays draw; the representable updates only when this changes.
struct PreviewOverlayState: Equatable {
    var webcam: WebcamSettings?
    var background: BackgroundSettings
    var blur: [BlurMask]
    var selectedBlur: BlurMask.ID?
    var selectedKeyframe: ZoomKeyframe?
    var zoom: ZoomSettings
    var isPicking: Bool
    var isPlaying: Bool
    var subtitles: SubtitleSettings
    var selectedCue: SubtitleCue.ID?
    var crop: NormRect?
    /// The crop tool is on; the preview then shows the whole recording, unzoomed.
    var isCropping: Bool

    @MainActor
    init(model: EditorModel) {
        webcam = model.hasWebcam && model.edit.webcam.enabled ? model.edit.webcam : nil
        background = model.edit.background
        blur = model.edit.blur
        if case .blur(let id) = model.selection { selectedBlur = id } else { selectedBlur = nil }
        selectedKeyframe = model.selectedKeyframe
        zoom = model.edit.zoom
        isPicking = model.isPickingZoomTarget
        isPlaying = model.clock.isPlaying
        subtitles = model.edit.subtitles
        if case .cue(let id) = model.selection { selectedCue = id } else { selectedCue = nil }
        crop = model.edit.crop
        isCropping = model.isEditingCrop
    }
}

struct PreviewRepresentable: NSViewRepresentable {
    let model: EditorModel
    let state: PreviewOverlayState

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView(model: model)
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.state = state
    }

    static func dismantleNSView(_ view: PreviewNSView, coordinator: ()) {
        view.teardown()
    }
}

/// Width is a wrap constraint, which may be much wider than the visible text box.
struct CueWidthDrag {
    let startX: CGFloat
    let initialWidth: Double
    let edge: CGFloat

    func width(at x: CGFloat, videoWidth: CGFloat) -> Double {
        guard videoWidth > 0 else { return initialWidth }
        return min(
            max(initialWidth + Double(edge * (x - startX) / videoWidth), EditLimits.subtitleMaxWidth.lowerBound),
            EditLimits.subtitleMaxWidth.upperBound)
    }
}

final class PreviewNSView: NSView {
    private weak var model: EditorModel?
    private let playerLayer = AVPlayerLayer()
    private let overlay = CALayer()
    private let webcamOutline = CAShapeLayer()
    private let maskOutline = CAShapeLayer()
    private let otherMasks = CAShapeLayer()
    private let handles: [CALayer] = (0..<8).map { _ in CALayer() }
    private let targetMarker = CAShapeLayer()
    private let subtitleOutline = CAShapeLayer()
    /// Darkens what the crop leaves out (even-odd: the content minus the crop).
    private let cropShade = CAShapeLayer()
    private let cropOutline = CAShapeLayer()
    private let cropHandles: [CALayer] = (0..<8).map { _ in CALayer() }
    private var trackingArea: NSTrackingArea?
    private var hoveringWebcam = false
    private var hoveringCue: SubtitleCue.ID?
    private var lastBackingSize: CGSize = .zero

    var state: PreviewOverlayState? {
        didSet { if state != oldValue { refreshOverlay() } }
    }

    private enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Drag {
        case subtitle(SubtitleCue.ID, frame: CGRect, from: CGPoint)
        /// Resizing a cue's box symmetrically about its centre (view x), so the centred text keeps its place.
        case subtitleWidth(SubtitleCue.ID, centerX: CGFloat, gesture: CueWidthDrag)
        case webcam(start: NormPoint, from: CGPoint)
        case maskMove(BlurMask.ID, start: NormRect, from: NormPoint)
        case maskResize(BlurMask.ID, Handle, start: NormRect)
        case cropMove(start: NormRect, from: NormPoint)
        case cropResize(Handle, start: NormRect)
        /// Drawing a new crop from a corner (view point and source point).
        case cropDraw(fromView: CGPoint, from: NormPoint)
    }

    private var drag: Drag?

    private var isDraggingWebcam: Bool {
        if case .webcam = drag { true } else { false }
    }

    private func isDraggingCue(_ id: SubtitleCue.ID) -> Bool {
        switch drag {
        case .subtitle(let dragged, _, _), .subtitleWidth(let dragged, _, _): dragged == id
        default: false
        }
    }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.stageBackground.cgColor
        playerLayer.player = model.player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        layer?.addSublayer(overlay)

        webcamOutline.fillColor = nil
        webcamOutline.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        webcamOutline.lineWidth = 1.5
        webcamOutline.lineDashPattern = [5, 4]
        otherMasks.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
        otherMasks.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        otherMasks.lineWidth = 1
        otherMasks.lineDashPattern = [3, 3]
        maskOutline.fillColor = AppTheme.accent.withAlphaComponent(0.12).cgColor
        maskOutline.strokeColor = AppTheme.accent.cgColor
        maskOutline.lineWidth = 1.5
        targetMarker.fillColor = nil
        targetMarker.strokeColor = NSColor.systemYellow.cgColor
        targetMarker.lineWidth = 2
        subtitleOutline.fillColor = nil
        subtitleOutline.strokeColor = AppTheme.accent.cgColor
        subtitleOutline.lineWidth = 1.5
        subtitleOutline.lineDashPattern = [5, 4]
        cropShade.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        cropShade.fillRule = .evenOdd
        cropOutline.fillColor = nil
        cropOutline.strokeColor = NSColor.systemRed.cgColor
        cropOutline.lineWidth = 2
        cropOutline.lineDashPattern = [6, 4]
        for layer in [otherMasks, maskOutline, webcamOutline, targetMarker, subtitleOutline, cropShade, cropOutline] {
            overlay.addSublayer(layer)
        }
        for handle in cropHandles {
            handle.backgroundColor = NSColor.white.cgColor
            handle.borderColor = NSColor.systemRed.cgColor
            handle.borderWidth = 1.5
            handle.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
            overlay.addSublayer(handle)
        }
        for handle in handles {
            handle.backgroundColor = NSColor.white.cgColor
            handle.borderColor = AppTheme.accent.cgColor
            handle.borderWidth = 1
            handle.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
            overlay.addSublayer(handle)
        }
        model.playhead.observe(self) { [weak self] _ in self?.refreshOverlay() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func teardown() {
        model?.playhead.remove(self)
        playerLayer.player = nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        overlay.frame = bounds
        CATransaction.commit()
        refreshOverlay()
        reportBackingSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportBackingSize()
    }

    private func reportBackingSize() {
        guard window != nil else { return }
        let size = convertToBacking(bounds).size
        guard size != lastBackingSize else { return }
        lastBackingSize = size
        model?.previewSizeChanged(CGSize(width: abs(size.width), height: abs(size.height)))
    }

    // MARK: Geometry

    /// Geometry for the current edit (computed here so it never lags the renderer). Uncropped while cropping.
    private var geometry: PreviewGeometry? {
        guard let model, let state else { return nil }
        let layout = CanvasLayout.make(
            sourceSize: model.renderer.layout.sourceSize, crop: state.isCropping ? nil : state.crop,
            background: state.background, sizing: model.renderer.options.sizing)
        return PreviewGeometry(layout: layout)
    }

    private var zoomState: ZoomState {
        guard let model, state?.isCropping != true else { return .identity }
        return model.renderer.zoomState(atSource: model.currentSourceTime)
    }

    /// The crop box in view points (the whole content when there's no crop), while cropping.
    private func cropViewRect(_ geometry: PreviewGeometry) -> CGRect? {
        guard let state, state.isCropping else { return nil }
        let canvas = geometry.canvasRect(fromSource: state.crop ?? .full)
        return geometry.viewRect(fromCanvas: canvas, viewSize: bounds.size).standardized
    }

    private func hitCropHandle(_ p: CGPoint) -> Handle? {
        guard let geometry, let r = cropViewRect(geometry) else { return nil }
        return Handle.allCases.first { handle in
            let c = handlePoint(handle, in: r)
            return abs(c.x - p.x) <= 7 && abs(c.y - p.y) <= 7
        }
    }

    private func webcamViewRect(_ geometry: PreviewGeometry) -> CGRect? {
        guard let model, let webcam = state?.webcam else { return nil }
        let canvas = geometry.webcamRect(for: webcam, cameraSize: model.cameraSize)
        return geometry.viewRect(fromCanvas: canvas, viewSize: bounds.size)
    }

    private func maskViewRect(_ mask: BlurMask, _ geometry: PreviewGeometry, zoom: ZoomState) -> CGRect {
        geometry.viewRect(fromCanvas: geometry.canvasRect(fromSource: mask.rect, zoom: zoom), viewSize: bounds.size)
            .standardized
    }

    private func sourcePoint(_ viewPoint: CGPoint, _ geometry: PreviewGeometry, zoom: ZoomState) -> NormPoint {
        geometry.sourcePoint(fromCanvas: geometry.canvasPoint(fromView: viewPoint, viewSize: bounds.size), zoom: zoom)
    }

    private func handlePoint(_ handle: Handle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    private var activeMasks: [BlurMask] {
        guard let model, let state else { return [] }
        return BlurLayout.active(state.blur, at: model.currentSourceTime)
    }

    /// Subtitles showing at the playhead with their boxes in view points (topmost last), while paused.
    private func activeCueRects(_ geometry: PreviewGeometry) -> [(cue: SubtitleCue, rect: CGRect)] {
        guard let model, let state, !state.isPlaying else { return [] }
        let canvas = geometry.layout.canvasSize
        return state.subtitles.activeCues(at: model.currentSourceTime).map { cue in
            let frame = SubtitleLayout.frame(for: cue, settings: state.subtitles, canvasSize: canvas)
            return (cue, geometry.viewRect(fromCanvas: frame, viewSize: bounds.size).standardized)
        }
    }

    private func hitCue(_ p: CGPoint) -> (cue: SubtitleCue, rect: CGRect)? {
        guard let geometry, state?.isPicking == false else { return nil }
        return activeCueRects(geometry).last { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }
    }

    /// A subtitle whose left or right box edge is under `p` (topmost first).
    private func hitCueEdge(_ p: CGPoint) -> (cue: SubtitleCue, rect: CGRect)? {
        guard let geometry, state?.isPicking == false else { return nil }
        return activeCueRects(geometry).last { item in
            let r = item.rect.insetBy(dx: -3, dy: -3)
            return p.y >= r.minY && p.y <= r.maxY && (abs(p.x - r.minX) <= 5 || abs(p.x - r.maxX) <= 5)
        }
    }

    /// Where the dragged cue's lines wrap (view x), while its width is being dragged.
    private func wrapGuides(_ geometry: PreviewGeometry) -> (left: CGFloat, right: CGFloat)? {
        guard case .subtitleWidth(let id, let centerX, _) = drag, let state,
            let cue = state.subtitles.cues.first(where: { $0.id == id })
        else { return nil }
        let video = geometry.videoRect(inViewOfSize: bounds.size)
        let canvas = geometry.layout.canvasSize
        guard video.width > 0, canvas.width > 0 else { return nil }
        let style = state.subtitles.style(for: cue)
        let outline = style.outlineWidth * SubtitleLayout.fontSize(style, canvasSize: canvas)
        let half = (style.maxWidth * canvas.width + 2 * outline) / 2 * video.width / canvas.width
        return (centerX - half, centerX + half)
    }

    // MARK: Overlay

    private func refreshOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let state, let geometry = geometry, bounds.width > 0 else {
            overlay.isHidden = true
            return
        }
        overlay.isHidden = false
        if refreshCrop(geometry) { return }
        let zoom = zoomState

        if let rect = webcamViewRect(geometry), hoveringWebcam || isDraggingWebcam {
            webcamOutline.path = CGPath(rect: rect.insetBy(dx: -1, dy: -1), transform: nil)
            webcamOutline.isHidden = false
        } else {
            webcamOutline.isHidden = true
        }

        let paused = !state.isPlaying
        let selectedMask = state.blur.first { $0.id == state.selectedBlur }
        if paused, let mask = selectedMask {
            let r = maskViewRect(mask, geometry, zoom: zoom)
            maskOutline.path = CGPath(rect: r, transform: nil)
            maskOutline.isHidden = false
            let active = activeMasks.contains { $0.id == mask.id }
            maskOutline.opacity = active ? 1 : 0.5
            for handle in Handle.allCases {
                handles[handle.rawValue].position = handlePoint(handle, in: r)
                handles[handle.rawValue].isHidden = false
            }
        } else {
            maskOutline.isHidden = true
            for handle in handles { handle.isHidden = true }
        }

        if paused {
            let path = CGMutablePath()
            for mask in activeMasks where mask.id != state.selectedBlur {
                path.addRect(maskViewRect(mask, geometry, zoom: zoom))
            }
            otherMasks.path = path
            otherMasks.isHidden = path.isEmpty
        } else {
            otherMasks.isHidden = true
        }

        let cueRects = activeCueRects(geometry)
        let highlighted = cueRects.filter {
            $0.cue.id == state.selectedCue || $0.cue.id == hoveringCue || isDraggingCue($0.cue.id)
        }
        if !highlighted.isEmpty {
            let path = CGMutablePath()
            for item in highlighted { path.addRect(item.rect.insetBy(dx: -3, dy: -3)) }
            if let guides = wrapGuides(geometry),
                let dragged = highlighted.first(where: { isDraggingCue($0.cue.id) })
            {
                // The width being set; the box itself fits the wrapped text inside it.
                let r = dragged.rect.insetBy(dx: 0, dy: -8)
                for x in [guides.left, guides.right] {
                    path.move(to: CGPoint(x: x, y: r.minY))
                    path.addLine(to: CGPoint(x: x, y: r.maxY))
                }
            }
            subtitleOutline.path = path
            subtitleOutline.isHidden = false
        } else {
            subtitleOutline.isHidden = true
        }

        if paused, let keyframe = state.selectedKeyframe {
            let canvas = geometry.canvasPoint(fromSource: keyframe.target, zoom: zoom)
            let p = geometry.viewPoint(fromCanvas: canvas, viewSize: bounds.size)
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            path.move(to: CGPoint(x: p.x - 15, y: p.y))
            path.addLine(to: CGPoint(x: p.x - 4, y: p.y))
            path.move(to: CGPoint(x: p.x + 4, y: p.y))
            path.addLine(to: CGPoint(x: p.x + 15, y: p.y))
            path.move(to: CGPoint(x: p.x, y: p.y - 15))
            path.addLine(to: CGPoint(x: p.x, y: p.y - 4))
            path.move(to: CGPoint(x: p.x, y: p.y + 4))
            path.addLine(to: CGPoint(x: p.x, y: p.y + 15))
            targetMarker.path = path
            targetMarker.isHidden = false
        } else {
            targetMarker.isHidden = true
        }
    }

    /// Draws the crop tool; returns true when it's on (the other overlays are hidden then).
    private func refreshCrop(_ geometry: PreviewGeometry) -> Bool {
        guard let r = cropViewRect(geometry) else {
            cropShade.isHidden = true
            cropOutline.isHidden = true
            for handle in cropHandles { handle.isHidden = true }
            return false
        }
        for layer in [webcamOutline, maskOutline, otherMasks, targetMarker, subtitleOutline] { layer.isHidden = true }
        for handle in handles { handle.isHidden = true }
        let content = geometry.viewRect(fromCanvas: geometry.layout.contentRect, viewSize: bounds.size)
        let shade = CGMutablePath()
        shade.addRect(content)
        shade.addRect(r)
        cropShade.path = shade
        cropShade.isHidden = false
        cropOutline.path = CGPath(rect: r, transform: nil)
        cropOutline.isHidden = false
        for handle in Handle.allCases {
            cropHandles[handle.rawValue].position = handlePoint(handle, in: r)
            cropHandles[handle.rawValue].isHidden = false
        }
        return true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let cue = hitCue(p)?.cue.id
        if cue != hoveringCue {
            hoveringCue = cue
            refreshOverlay()
        }
        let overWebcam = geometry.flatMap { webcamViewRect($0) }?.contains(p) ?? false
        if overWebcam != hoveringWebcam {
            hoveringWebcam = overWebcam
            refreshOverlay()
        }
        cursor(for: p).set()
    }

    override func mouseExited(with event: NSEvent) {
        if hoveringCue != nil {
            hoveringCue = nil
            refreshOverlay()
        }
        if hoveringWebcam {
            hoveringWebcam = false
            refreshOverlay()
        }
        NSCursor.arrow.set()
    }

    private func hitHandle(_ p: CGPoint) -> Handle? {
        guard let state, !state.isPlaying, let geometry,
            let mask = state.blur.first(where: { $0.id == state.selectedBlur })
        else { return nil }
        let r = maskViewRect(mask, geometry, zoom: zoomState)
        return Handle.allCases.first { handle in
            let c = handlePoint(handle, in: r)
            return abs(c.x - p.x) <= 6 && abs(c.y - p.y) <= 6
        }
    }

    private func hitMask(_ p: CGPoint) -> BlurMask? {
        guard let state, !state.isPlaying, let geometry else { return nil }
        let zoom = zoomState
        if let selected = state.blur.first(where: { $0.id == state.selectedBlur }),
            maskViewRect(selected, geometry, zoom: zoom).contains(p)
        {
            return selected
        }
        return activeMasks.last { maskViewRect($0, geometry, zoom: zoom).contains(p) }
    }

    private func cursor(for p: CGPoint) -> NSCursor {
        if state?.isPicking == true { return .crosshair }
        if state?.isCropping == true {
            switch hitCropHandle(p) {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .some: return .crosshair
            case nil:
                if let geometry, cropViewRect(geometry)?.contains(p) == true { return .openHand }
                return .crosshair
            }
        }
        if let handle = hitHandle(p) {
            switch handle {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
        if hitCueEdge(p) != nil { return .resizeLeftRight }
        if hitCue(p) != nil { return .openHand }
        if hitMask(p) != nil { return .openHand }
        if let geometry, webcamViewRect(geometry)?.contains(p) == true { return .openHand }
        return .arrow
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, let state, let geometry else { return }
        let p = convert(event.locationInWindow, from: nil)
        drag = nil
        if state.isPicking {
            let source = sourcePoint(p, geometry, zoom: zoomState)
            model.setZoomTarget(source.clamped)
            return
        }
        if state.isCropping {
            let crop = state.crop ?? .full
            model.beginContinuousChange()
            if let handle = hitCropHandle(p) {
                drag = .cropResize(handle, start: crop)
            } else if cropViewRect(geometry)?.contains(p) == true {
                drag = .cropMove(start: crop, from: sourcePoint(p, geometry, zoom: .identity))
                NSCursor.closedHand.set()
            } else {
                drag = .cropDraw(fromView: p, from: sourcePoint(p, geometry, zoom: .identity).clamped)
            }
            return
        }
        // Subtitles are drawn on top of everything, so they win the hit test; their edges set their width.
        if let hit = hitCueEdge(p) {
            model.selection = .cue(hit.cue.id)
            model.inspectorTab = .subtitles
            model.beginContinuousChange()
            let width = state.subtitles.style(for: hit.cue).maxWidth
            drag = .subtitleWidth(
                hit.cue.id, centerX: hit.rect.midX,
                gesture: CueWidthDrag(startX: p.x, initialWidth: width, edge: p.x < hit.rect.midX ? -1 : 1))
            NSCursor.resizeLeftRight.set()
            refreshOverlay()
            return
        }
        if let hit = hitCue(p) {
            model.selection = .cue(hit.cue.id)
            model.inspectorTab = .subtitles
            let frame = SubtitleLayout.frame(
                for: hit.cue, settings: state.subtitles, canvasSize: geometry.layout.canvasSize)
            model.beginContinuousChange()
            drag = .subtitle(hit.cue.id, frame: frame, from: p)
            NSCursor.closedHand.set()
            refreshOverlay()
            return
        }
        if let handle = hitHandle(p), let id = state.selectedBlur,
            let mask = state.blur.first(where: { $0.id == id })
        {
            model.beginContinuousChange()
            drag = .maskResize(id, handle, start: mask.rect)
            return
        }
        if let webcam = state.webcam, webcamViewRect(geometry)?.contains(p) == true {
            model.beginContinuousChange()
            drag = .webcam(start: webcam.origin, from: p)
            NSCursor.closedHand.set()
            refreshOverlay()
            return
        }
        if let mask = hitMask(p) {
            model.selection = .blur(mask.id)
            model.inspectorTab = .blur
            model.beginContinuousChange()
            drag = .maskMove(mask.id, start: mask.rect, from: sourcePoint(p, geometry, zoom: zoomState))
            NSCursor.closedHand.set()
            return
        }
        // Clicking empty video clears a blur selection so its handles don't get in the way.
        if case .blur = model.selection { model.selection = nil }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let drag, let geometry else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .subtitle(let id, let frame, let from):
            let video = geometry.videoRect(inViewOfSize: bounds.size)
            guard video.width > 0 else { return }
            let scale = geometry.layout.canvasSize.width / video.width
            let moved = frame.offsetBy(dx: (p.x - from.x) * scale, dy: (p.y - from.y) * scale)
            model.setCuePosition(
                id, SubtitleLayout.position(forFrame: moved, canvasSize: geometry.layout.canvasSize))
        case .subtitleWidth(let id, _, let gesture):
            let video = geometry.videoRect(inViewOfSize: bounds.size)
            guard video.width > 0 else { return }
            model.setCueWidth(id, gesture.width(at: p.x, videoWidth: video.width))
        case .webcam(let start, let from):
            let video = geometry.videoRect(inViewOfSize: bounds.size)
            guard video.width > 0, video.height > 0 else { return }
            let w = model.edit.webcam.width
            let h = model.webcamHeightFraction(for: model.edit.webcam)
            let origin = NormPoint(
                x: min(max(start.x + (p.x - from.x) / video.width, 0), max(0, 1 - w)),
                y: min(max(start.y + (p.y - from.y) / video.height, 0), max(0, 1 - h)))
            model.update("Move Webcam") { $0.webcam.origin = origin }
        case .maskMove(let id, let start, let from):
            let s = sourcePoint(p, geometry, zoom: zoomState)
            let x = min(max(start.x + s.x - from.x, 0), max(0, 1 - start.w))
            let y = min(max(start.y + s.y - from.y, 0), max(0, 1 - start.h))
            model.updateBlur(id, "Move Blur") { $0.rect = NormRect(x: x, y: y, w: start.w, h: start.h) }
        case .maskResize(let id, let handle, let start):
            let s = sourcePoint(p, geometry, zoom: zoomState).clamped
            var x0 = start.x
            var y0 = start.y
            var x1 = start.x + start.w
            var y1 = start.y + start.h
            switch handle {
            case .topLeft, .left, .bottomLeft: x0 = s.x
            case .topRight, .right, .bottomRight: x1 = s.x
            default: break
            }
            switch handle {
            case .topLeft, .top, .topRight: y0 = s.y
            case .bottomLeft, .bottom, .bottomRight: y1 = s.y
            default: break
            }
            let minSize = 0.01
            let rect = NormRect(
                x: min(x0, x1), y: min(y0, y1), w: max(abs(x1 - x0), minSize), h: max(abs(y1 - y0), minSize))
            model.updateBlur(id, "Resize Blur") { $0.rect = rect }
        case .cropMove(let start, let from):
            let s = sourcePoint(p, geometry, zoom: .identity)
            let x = min(max(start.x + s.x - from.x, 0), max(0, 1 - start.w))
            let y = min(max(start.y + s.y - from.y, 0), max(0, 1 - start.h))
            model.setCrop(NormRect(x: x, y: y, w: start.w, h: start.h), "Move Crop")
        case .cropResize(let handle, let start):
            let s = sourcePoint(p, geometry, zoom: .identity).clamped
            var x0 = start.x
            var y0 = start.y
            var x1 = start.x + start.w
            var y1 = start.y + start.h
            switch handle {
            case .topLeft, .left, .bottomLeft: x0 = s.x
            case .topRight, .right, .bottomRight: x1 = s.x
            default: break
            }
            switch handle {
            case .topLeft, .top, .topRight: y0 = s.y
            case .bottomLeft, .bottom, .bottomRight: y1 = s.y
            default: break
            }
            model.setCrop(
                NormRect(x: min(x0, x1), y: min(y0, y1), w: abs(x1 - x0), h: abs(y1 - y0)), "Resize Crop")
        case .cropDraw(let fromView, let from):
            // A click without a drag keeps the current crop.
            guard hypot(p.x - fromView.x, p.y - fromView.y) >= 4 else { return }
            let s = sourcePoint(p, geometry, zoom: .identity).clamped
            model.setCrop(
                NormRect(x: min(from.x, s.x), y: min(from.y, s.y), w: abs(s.x - from.x), h: abs(s.y - from.y)),
                "Crop")
        }
        refreshOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        model?.endContinuousChange()
        refreshOverlay()
        cursor(for: convert(event.locationInWindow, from: nil)).set()
    }
}
