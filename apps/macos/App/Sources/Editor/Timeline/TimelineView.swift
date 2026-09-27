import AppKit
import ProjectKit
import QuartzCore
import SwiftUI

/// Hosts ``TimelineNSView``. The container reads the observable state the timeline draws, so SwiftUI calls
/// `updateNSView` only when an edit, the selection, the zoom, waveforms or play state change — never per frame.
struct TimelineContainer: View {
    let model: EditorModel

    var body: some View {
        TimelineRepresentable(
            model: model, data: TimelineData(model: model), zoom: model.timelineZoom,
            isPlaying: model.clock.isPlaying, waveformCount: model.waveforms.count)
    }
}

/// The edit state the timeline draws.
struct TimelineData: Equatable {
    var segments: [Segment]
    var keyframes: [ZoomKeyframe]
    var zoomEnabled: Bool
    var blur: [BlurMask]
    var cues: [SubtitleCue]
    var webcamEnabled: Bool
    var syncOffset: Double
    var selection: EditorSelection?

    @MainActor
    init(model: EditorModel) {
        segments = model.edit.segments
        keyframes = model.edit.zoom.keyframes
        zoomEnabled = model.edit.zoom.enabled
        blur = model.edit.blur
        cues = model.edit.subtitles.cues
        webcamEnabled = model.edit.webcam.enabled
        syncOffset = model.edit.webcam.syncOffset
        selection = model.selection
    }
}

/// Cue gestures start on the edited ruler and cross cuts in that same coordinate space.
enum CueDragTime {
    static func sourceTime(editedStart: Double, editedDelta: Double, timeline: EditTimeline) -> Double {
        timeline.sourceTime(forEdited: editedStart + editedDelta)
    }
}

/// A plain click on a selected zoom keeps the group until the gesture's outcome is known.
enum KeyframeClick {
    @MainActor
    static func begin(_ id: ZoomKeyframe.ID, modifier: SelectionModifier, model: EditorModel) -> Bool {
        let keepGroup =
            modifier == .replace && model.selectedKeyframeIDs.count > 1
            && model.selectedKeyframeIDs.contains(id)
        if !keepGroup { model.selectKeyframe(id, modifier) }
        return keepGroup
    }

    @MainActor
    static func end(_ id: ZoomKeyframe.ID?, moving: Bool, model: EditorModel) {
        if !moving, let id { model.selectKeyframe(id) }
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    let model: EditorModel
    let data: TimelineData
    let zoom: Double
    let isPlaying: Bool
    let waveformCount: Int

    func makeNSView(context: Context) -> TimelineNSView {
        TimelineNSView(model: model)
    }

    func updateNSView(_ view: TimelineNSView, context: Context) {
        view.update(data: data, zoom: zoom, isPlaying: isPlaying, waveformCount: waveformCount)
    }

    static func dismantleNSView(_ view: TimelineNSView, coordinator: ()) {
        view.teardown()
    }
}

/// A layer-backed timeline in **edited** time. Items stored in source time (keyframes, blur, subtitles, clicks, pauses) are
/// mapped with `EditTimeline.editedTime(forSource:)` and hidden when cut. Layers are laid out only when data, zoom,
/// scroll or size change; while playing, a display link moves just the playhead layer.
final class TimelineNSView: NSView {
    typealias Row = TimelineMetrics.Row

    private weak var model: EditorModel?
    private var data: TimelineData?
    private var zoom: Double = 1
    private var scrollX: CGFloat = 0
    private var isPlaying = false
    private var waveformCount = 0
    private var displayLink: CADisplayLink?
    /// Points per second frozen during trim drags (the edited duration changes under the pointer).
    private var frozenPPS: Double?
    private var trackingArea: NSTrackingArea?

    // Layers.
    private let rulerBackground = CALayer()
    private let rulerTicks = CAShapeLayer()
    private let rulerRule = CALayer()
    private var tickLabels: [CATextLayer] = []
    private var rowBackgrounds: [Row: CALayer] = [:]
    private var rowLabels: [Row: CATextLayer] = [:]
    private let content = CALayer()
    private var segmentLayers: [CALayer] = []
    private let trimHandles = [CALayer(), CALayer()]
    private var webcamLayers: [CALayer] = []
    private let webcamLabel = CATextLayer()
    private var waveformLayers: [Row: CAShapeLayer] = [:]
    private var blurLayers: [CALayer] = []
    private var cueLayers: [CATextLayer] = []
    private var keyframeLayers: [CAShapeLayer] = []
    private let clickDots = CAShapeLayer()
    private let pauseMarkers = CAShapeLayer()
    private let playhead = CALayer()
    private let playheadKnob = CAShapeLayer()

    private enum Drag {
        case scrub
        case trimStart(source: Double, x: CGFloat)
        case trimEnd(source: Double, x: CGFloat)
        case webcamSync(offset: Double, x: CGFloat)
        case blurMove(BlurMask.ID, start: Double, end: Double, x: CGFloat)
        case blurStart(BlurMask.ID, start: Double, x: CGFloat)
        case blurEnd(BlurMask.ID, end: Double, x: CGFloat)
        case cueMove(SubtitleCue.ID, start: Double, x: CGFloat)
        case cueStart(SubtitleCue.ID, start: Double, x: CGFloat)
        case cueEnd(SubtitleCue.ID, end: Double, x: CGFloat)
        /// Moves every keyframe in `times` (their source times at mouse-down). `clickSelects`: a click without a drag
        /// selects just this keyframe (the mouse-down kept a multi-selection so it could be dragged as a group).
        case keyframes(times: [ZoomKeyframe.ID: Double], x: CGFloat, moving: Bool, clickSelects: ZoomKeyframe.ID?)
    }

    private var drag: Drag?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = true
        root.backgroundColor = AppTheme.panelBackground.cgColor
        root.addSublayer(rulerBackground)
        root.addSublayer(rulerRule)
        root.addSublayer(rulerTicks)
        for row in Row.allCases {
            let background = CALayer()
            rowBackgrounds[row] = background
            root.addSublayer(background)
            let label = makeText(size: 11, weight: .medium)
            label.string = row.title
            rowLabels[row] = label
            root.addSublayer(label)
        }
        content.masksToBounds = true
        root.addSublayer(content)
        for row in [Row.systemAudio, .microphone] {
            let shape = CAShapeLayer()
            waveformLayers[row] = shape
            content.addSublayer(shape)
        }
        webcamLabel.fontSize = 10
        content.addSublayer(webcamLabel)
        content.addSublayer(pauseMarkers)
        content.addSublayer(clickDots)
        for handle in trimHandles {
            handle.cornerRadius = 2
            handle.zPosition = 5
            content.addSublayer(handle)
        }
        playhead.zPosition = 20
        playheadKnob.zPosition = 21
        content.addSublayer(playhead)
        content.addSublayer(playheadKnob)
        pauseMarkers.lineDashPattern = [3, 3]
        pauseMarkers.lineWidth = 1.5
        pauseMarkers.fillColor = nil
        rulerTicks.lineWidth = 1
        rulerTicks.fillColor = nil
        model.playhead.observe(self) { [weak self] t in
            guard let self, !self.isPlaying else { return }
            self.movePlayhead(to: t)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func teardown() {
        model?.playhead.remove(self)
        displayLink?.invalidate()
        displayLink = nil
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Updates

    func update(data: TimelineData, zoom newZoom: Double, isPlaying playing: Bool, waveformCount count: Int) {
        var needsLayout = false
        if data != self.data || count != waveformCount {
            self.data = data
            waveformCount = count
            needsLayout = true
        }
        if abs(newZoom - zoom) > 1e-9 {
            // Zoom changed from the transport: keep the playhead (or the centre) in place.
            let visible = visibleWidth
            let t = model?.currentTime ?? 0
            let oldX = t * pps - scrollX
            let anchorX = oldX >= 0 && oldX <= visible ? oldX : visible / 2
            let anchorT = (anchorX + scrollX) / pps
            zoom = newZoom
            scrollX = anchorT * pps - anchorX
            needsLayout = true
        }
        if playing != isPlaying {
            isPlaying = playing
            updateDisplayLink()
            if !playing, let model { movePlayhead(to: model.currentTime) }
        }
        if needsLayout { relayout() }
    }

    override func layout() {
        super.layout()
        relayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        relayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            // The playhead moves well under a point per frame at 30 Hz; a faster link only costs main-thread commits.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
            updateDisplayLink()
            relayout()
        }
    }

    private func updateDisplayLink() {
        displayLink?.isPaused = !isPlaying
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let model, isPlaying else { return }
        let t = model.currentTime
        // Keep the playhead in view: page forward when it nears the right edge (or jumped out of view).
        let x = t * pps - scrollX
        if x > visibleWidth - 24 || x < 0 {
            scrollX = t * pps - visibleWidth * 0.1
            relayout()
        } else {
            movePlayhead(to: t)
        }
    }

    // MARK: Geometry

    private var duration: Double { max(model?.timeline.duration ?? 0, 0.01) }
    private var visibleWidth: CGFloat { max(1, bounds.width - TimelineMetrics.gutter - TimelineMetrics.trailingPad) }
    private var pps: Double { frozenPPS ?? (Double(visibleWidth) / duration * zoom) }
    private var maxScroll: CGFloat { max(0, duration * pps - visibleWidth) }

    /// Content-layer x for an edited time.
    private func x(_ t: Double) -> CGFloat { t * pps - scrollX }

    /// Edited time for a view x.
    private func time(atViewX vx: CGFloat) -> Double {
        min(max((vx - TimelineMetrics.gutter + scrollX) / pps, 0), duration)
    }

    private var rows: [Row] {
        model.map { TimelineMetrics.rows(for: $0.recordedStreams, subtitles: !(data?.cues.isEmpty ?? true)) } ?? []
    }

    private func rowFrames() -> [Row: CGRect] {
        var y = TimelineMetrics.rulerHeight
        var frames: [Row: CGRect] = [:]
        for row in rows {
            frames[row] = CGRect(x: 0, y: y, width: bounds.width, height: row.height)
            y += row.height + TimelineMetrics.rowGap
        }
        return frames
    }

    private func row(at y: CGFloat) -> Row? {
        rowFrames().first { $0.value.minY - 1 <= y && y <= $0.value.maxY + 1 }?.key
    }

    // MARK: Layout

    private func makeText(size: CGFloat, weight: NSFont.Weight = .regular) -> CATextLayer {
        let text = CATextLayer()
        text.font = NSFont.systemFont(ofSize: size, weight: weight)
        text.fontSize = size
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        return text
    }

    private func pool<L: CALayer>(_ layers: inout [L], count: Int, make: () -> L) {
        while layers.count < count {
            let layer = make()
            content.addSublayer(layer)
            layers.append(layer)
        }
        for (i, layer) in layers.enumerated() { layer.isHidden = i >= count }
    }

    private func relayout() {
        guard let model, let data, bounds.width > 0 else { return }
        scrollX = min(max(scrollX, 0), maxScroll)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let frames = rowFrames()
            layoutChrome(frames)
            content.frame = CGRect(
                x: TimelineMetrics.gutter, y: 0, width: bounds.width - TimelineMetrics.gutter, height: bounds.height)
            layoutRuler()
            layoutSegments(model, data, frames[.screen])
            layoutWebcam(model, data, frames[.webcam])
            layoutWaveform(model, .systemAudio, frames[.systemAudio])
            layoutWaveform(model, .microphone, frames[.microphone])
            layoutKeyframes(model, data, frames[.zoom])
            layoutBlur(model, data, frames[.blur])
            layoutCues(model, data, frames[.subtitles])
            layoutClicks(model, frames[.clicks])
            layoutPauses(model, frames)
            layoutPlayhead()
            movePlayhead(to: model.currentTime)
        }
    }

    private func layoutChrome(_ frames: [Row: CGRect]) {
        let scale = window?.backingScaleFactor ?? 2
        rulerBackground.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineMetrics.rulerHeight)
        rulerBackground.backgroundColor = AppTheme.panelBackground.cgColor
        rulerRule.frame = CGRect(x: 0, y: TimelineMetrics.rulerHeight - 1, width: bounds.width, height: 1)
        rulerRule.backgroundColor = AppTheme.panelBorder.cgColor
        for row in Row.allCases {
            guard let background = rowBackgrounds[row], let label = rowLabels[row] else { continue }
            guard let frame = frames[row] else {
                background.isHidden = true
                label.isHidden = true
                continue
            }
            background.isHidden = false
            label.isHidden = false
            background.frame = frame
            background.backgroundColor = AppTheme.rowBackground.cgColor
            label.contentsScale = scale
            label.foregroundColor = AppTheme.secondaryText.cgColor
            label.frame = CGRect(x: 10, y: frame.midY - 7, width: TimelineMetrics.gutter - 14, height: 16)
        }
    }

    private func layoutRuler() {
        let (major, minor) = TimelineMetrics.tickSteps(pointsPerSecond: pps)
        let t0 = max(0, Double(scrollX) / pps)
        let t1 = min(duration, Double(scrollX + visibleWidth + TimelineMetrics.trailingPad) / pps)
        let path = CGMutablePath()
        let h = TimelineMetrics.rulerHeight
        var t = (t0 / minor).rounded(.down) * minor
        var labels: [(CGFloat, String)] = []
        while t <= t1 + 1e-9 {
            let isMajor = abs((t / major).rounded() * major - t) < minor * 0.01
            let xx = x(t) + TimelineMetrics.gutter
            path.move(to: CGPoint(x: xx, y: h))
            path.addLine(to: CGPoint(x: xx, y: h - (isMajor ? 9 : 4)))
            if isMajor { labels.append((xx, TimelineMetrics.tickLabel(t, major: major))) }
            t += minor
        }
        rulerTicks.frame = bounds
        rulerTicks.path = path
        rulerTicks.strokeColor = AppTheme.tertiaryText.cgColor
        // Tick labels live on the root layer, clipped to the ruler right of the gutter.
        while tickLabels.count < labels.count {
            let text = makeText(size: 10)
            layer?.addSublayer(text)
            tickLabels.append(text)
        }
        let scale = window?.backingScaleFactor ?? 2
        for (i, text) in tickLabels.enumerated() {
            guard i < labels.count, labels[i].0 >= TimelineMetrics.gutter - 1 else {
                text.isHidden = true
                continue
            }
            text.isHidden = false
            text.contentsScale = scale
            text.string = labels[i].1
            text.foregroundColor = AppTheme.secondaryText.cgColor
            text.frame = CGRect(x: labels[i].0 + 3, y: 2, width: 60, height: 13)
        }
    }

    private func layoutSegments(_ model: EditorModel, _ data: TimelineData, _ frame: CGRect?) {
        guard let frame else { return }
        let pieces = model.timeline.pieces
        pool(&segmentLayers, count: pieces.count) {
            let layer = CALayer()
            layer.cornerRadius = 6
            layer.shadowColor = AppTheme.screenTrack.cgColor
            layer.shadowOffset = .zero
            layer.shadowRadius = 8
            return layer
        }
        for (i, piece) in pieces.enumerated() {
            let layer = segmentLayers[i]
            let x0 = x(piece.editedStart)
            let x1 = x(piece.editedEnd)
            layer.frame = CGRect(x: x0 + 1, y: frame.minY + 2, width: max(1, x1 - x0 - 2), height: frame.height - 4)
            let selected = data.selection == .segment(piece.segment.id)
            let track = AppTheme.screenTrack
            layer.backgroundColor = track.withAlphaComponent(selected ? 0.55 : 0.28).cgColor
            layer.borderColor = selected ? NSColor.white.cgColor : track.withAlphaComponent(0.6).cgColor
            layer.borderWidth = selected ? 2 : 1
            // The glow is only on the selected segment; an explicit path keeps the shadow cheap.
            layer.shadowOpacity = selected ? 0.45 : 0
            layer.shadowPath =
                selected ? CGPath(roundedRect: layer.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil) : nil
        }
        let edges = [x(0), x(model.timeline.duration)]
        for (i, handle) in trimHandles.enumerated() {
            handle.isHidden = pieces.isEmpty
            handle.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            handle.borderColor = AppTheme.screenTrack.cgColor
            handle.borderWidth = 1
            let hx = i == 0 ? edges[0] + 1 : edges[1] - 7
            handle.frame = CGRect(x: hx, y: frame.minY + 6, width: 6, height: frame.height - 12)
        }
    }

    private func layoutWebcam(_ model: EditorModel, _ data: TimelineData, _ frame: CGRect?) {
        guard let frame else {
            pool(&webcamLayers, count: 0) { CALayer() }
            webcamLabel.isHidden = true
            return
        }
        let pieces = model.timeline.pieces
        pool(&webcamLayers, count: pieces.count) {
            let layer = CALayer()
            layer.cornerRadius = 5
            return layer
        }
        let shift = data.syncOffset * pps
        let alpha = data.webcamEnabled ? 0.55 : 0.2
        for (i, piece) in pieces.enumerated() {
            let x0 = x(piece.editedStart) + shift
            let x1 = x(piece.editedEnd) + shift
            webcamLayers[i].frame = CGRect(
                x: x0 + 1, y: frame.minY + 3, width: max(1, x1 - x0 - 2), height: frame.height - 6)
            webcamLayers[i].backgroundColor = AppTheme.webcamTrack.withAlphaComponent(alpha).cgColor
        }
        if abs(data.syncOffset) > 0.0005 {
            webcamLabel.isHidden = false
            webcamLabel.contentsScale = window?.backingScaleFactor ?? 2
            webcamLabel.string = String(format: "sync %+.2f s", data.syncOffset)
            webcamLabel.foregroundColor = AppTheme.primaryText.cgColor
            webcamLabel.frame = CGRect(x: max(4, x(0) + shift + 6), y: frame.minY + 4, width: 90, height: 14)
            webcamLabel.zPosition = 2
        } else {
            webcamLabel.isHidden = true
        }
    }

    private func layoutWaveform(_ model: EditorModel, _ row: Row, _ frame: CGRect?) {
        guard let shape = waveformLayers[row] else { return }
        let kind: StreamKind = row == .systemAudio ? .systemAudio : .microphone
        guard let frame, let waveform = model.waveforms[kind] else {
            shape.isHidden = true
            return
        }
        shape.isHidden = false
        let audio = row == .systemAudio ? model.edit.audio.system : model.edit.audio.microphone
        let color = row == .systemAudio ? AppTheme.systemAudioTrack : AppTheme.microphoneTrack
        shape.fillColor = color.withAlphaComponent(audio.isAudible ? 0.75 : 0.25).cgColor
        shape.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: bounds.height)
        let path = CGMutablePath()
        let mid = frame.midY
        let half = frame.height / 2 - 2
        let column: CGFloat = 2
        let visibleStart = Double(scrollX) / pps
        let visibleEnd = Double(scrollX + visibleWidth + TimelineMetrics.trailingPad) / pps
        for piece in model.timeline.pieces {
            let e0 = max(piece.editedStart, visibleStart)
            let e1 = min(piece.editedEnd, visibleEnd)
            guard e1 > e0 else { continue }
            let x0 = x(e0)
            let x1 = x(e1)
            let count = max(1, Int(((x1 - x0) / column).rounded(.up)))
            let s0 = piece.segment.start + (e0 - piece.editedStart)
            let s1 = piece.segment.start + (e1 - piece.editedStart)
            let peaks = waveform.peaks(from: s0, to: s1, count: count)
            let step = (x1 - x0) / CGFloat(count)
            for (i, peak) in peaks.enumerated() where peak > 0.004 {
                let h = max(0.5, CGFloat(peak) * half)
                path.addRect(CGRect(x: x0 + CGFloat(i) * step, y: mid - h, width: max(1, step - 0.5), height: h * 2))
            }
        }
        shape.path = path
    }

    private func keyframeShape(_ k: ZoomKeyframe, editedStart e: Double, frame: CGRect) -> CGPath {
        let x0 = x(e)
        let xIn = x(e + k.effectiveEaseIn)
        let xHold = x(e + k.effectiveEaseIn + k.hold)
        let x1 = x(e + k.effectiveEaseIn + k.hold + k.effectiveEaseOut)
        let top = frame.minY + 3
        let bottom = frame.maxY - 3
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: bottom))
        path.addLine(to: CGPoint(x: xIn, y: top))
        path.addLine(to: CGPoint(x: xHold, y: top))
        path.addLine(to: CGPoint(x: max(x1, xHold + 1), y: bottom))
        path.closeSubpath()
        return path
    }

    private func layoutKeyframes(_ model: EditorModel, _ data: TimelineData, _ frame: CGRect?) {
        guard let frame else { return }
        pool(&keyframeLayers, count: data.keyframes.count) {
            let shape = CAShapeLayer()
            shape.lineWidth = 1.5
            return shape
        }
        let selectedIDs: Set<ZoomKeyframe.ID>
        if case .keyframes(let ids) = data.selection { selectedIDs = ids } else { selectedIDs = [] }
        for (i, k) in data.keyframes.enumerated() {
            let shape = keyframeLayers[i]
            guard let e = model.timeline.editedTime(forSource: k.time) else {
                shape.isHidden = true
                continue
            }
            shape.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: bounds.height)
            shape.path = keyframeShape(k, editedStart: e, frame: frame)
            let selected = selectedIDs.contains(k.id)
            let base = k.enabled && data.zoomEnabled ? AppTheme.zoomTrack : AppTheme.tertiaryText
            shape.fillColor = base.withAlphaComponent(selected ? 0.85 : 0.5).cgColor
            shape.strokeColor = selected ? NSColor.white.cgColor : base.cgColor
            shape.zPosition = selected ? 3 : 1
        }
    }

    private func blurEditedRange(_ mask: BlurMask, _ model: EditorModel) -> (Double, Double)? {
        let e0 = model.timeline.editedTimeSnapping(forSource: mask.start)
        let e1 = model.timeline.editedTimeSnapping(forSource: mask.end)
        return e1 - e0 > 0.001 ? (e0, e1) : nil
    }

    private func layoutBlur(_ model: EditorModel, _ data: TimelineData, _ frame: CGRect?) {
        guard let frame else { return }
        pool(&blurLayers, count: data.blur.count) {
            let layer = CALayer()
            layer.cornerRadius = 5
            return layer
        }
        for (i, mask) in data.blur.enumerated() {
            let layer = blurLayers[i]
            guard let (e0, e1) = blurEditedRange(mask, model) else {
                layer.isHidden = true
                continue
            }
            let selected = data.selection == .blur(mask.id)
            layer.frame = CGRect(x: x(e0), y: frame.minY + 3, width: max(2, x(e1) - x(e0)), height: frame.height - 6)
            layer.backgroundColor = AppTheme.blurTrack.withAlphaComponent(selected ? 0.7 : 0.35).cgColor
            layer.borderColor = selected ? NSColor.white.cgColor : AppTheme.blurTrack.cgColor
            layer.borderWidth = selected ? 2 : 1
            layer.zPosition = selected ? 3 : 1
        }
    }

    private func layoutCues(_ model: EditorModel, _ data: TimelineData, _ frame: CGRect?) {
        guard let frame else {
            for layer in cueLayers { layer.isHidden = true }
            return
        }
        pool(&cueLayers, count: data.cues.count) {
            let layer = CATextLayer()
            layer.cornerRadius = 4
            layer.fontSize = 10
            layer.truncationMode = .end
            layer.isWrapped = false
            layer.alignmentMode = .left
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            return layer
        }
        for (i, cue) in data.cues.enumerated() {
            let layer = cueLayers[i]
            let e0 = model.timeline.editedTimeSnapping(forSource: cue.start)
            let e1 = model.timeline.editedTimeSnapping(forSource: cue.end)
            guard e1 - e0 > 0.001 else {
                layer.isHidden = true
                continue
            }
            let selected = data.selection == .cue(cue.id)
            layer.frame = CGRect(x: x(e0), y: frame.minY + 3, width: max(2, x(e1) - x(e0)), height: frame.height - 6)
            layer.backgroundColor = AppTheme.subtitleTrack.withAlphaComponent(selected ? 0.7 : 0.3).cgColor
            layer.borderColor = selected ? NSColor.white.cgColor : AppTheme.subtitleTrack.cgColor
            layer.borderWidth = selected ? 2 : 1
            layer.zPosition = selected ? 3 : 1
            layer.foregroundColor = AppTheme.primaryText.cgColor
            layer.string = layer.frame.width > 24 ? " " + cue.text.replacingOccurrences(of: "\n", with: " ") : ""
        }
    }

    private func layoutClicks(_ model: EditorModel, _ frame: CGRect?) {
        guard let frame else { return }
        clickDots.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: bounds.height)
        clickDots.fillColor = AppTheme.clickMarker.withAlphaComponent(0.9).cgColor
        let path = CGMutablePath()
        var lastX = -CGFloat.infinity
        for t in model.clickTimes {
            guard let e = model.timeline.editedTime(forSource: t) else { continue }
            let cx = x(e)
            guard cx > -4, cx < content.bounds.width + 4, cx - lastX >= 1 else { continue }
            lastX = cx
            path.addEllipse(in: CGRect(x: cx - 3, y: frame.midY - 3, width: 6, height: 6))
        }
        clickDots.path = path
    }

    private func layoutPauses(_ model: EditorModel, _ frames: [Row: CGRect]) {
        pauseMarkers.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: bounds.height)
        pauseMarkers.strokeColor = AppTheme.clickMarker.cgColor
        let path = CGMutablePath()
        let bottom = frames[.screen]?.maxY ?? TimelineMetrics.rulerHeight
        for pause in model.meta.pauses {
            guard let e = model.timeline.editedTime(forSource: pause.at) else { continue }
            path.move(to: CGPoint(x: x(e), y: TimelineMetrics.rulerHeight - 8))
            path.addLine(to: CGPoint(x: x(e), y: bottom))
        }
        pauseMarkers.path = path
    }

    private func layoutPlayhead() {
        playhead.backgroundColor = AppTheme.playhead.cgColor
        playhead.bounds = CGRect(x: 0, y: 0, width: 2, height: bounds.height)
        playhead.anchorPoint = CGPoint(x: 0.5, y: 0)
        playheadKnob.fillColor = AppTheme.playhead.cgColor
        let knob = CGMutablePath()
        knob.move(to: CGPoint(x: -6, y: 0))
        knob.addLine(to: CGPoint(x: 6, y: 0))
        knob.addLine(to: CGPoint(x: 6, y: 8))
        knob.addLine(to: CGPoint(x: 0, y: 14))
        knob.addLine(to: CGPoint(x: -6, y: 8))
        knob.closeSubpath()
        playheadKnob.path = knob
        playheadKnob.bounds = CGRect(x: -6, y: 0, width: 12, height: 14)
        playheadKnob.anchorPoint = CGPoint(x: 0.5, y: 0)
    }

    private func movePlayhead(to t: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let px = x(min(max(t, 0), duration))
        playhead.position = CGPoint(x: px, y: 0)
        playheadKnob.position = CGPoint(x: px, y: 0)
        CATransaction.commit()
    }

    // MARK: Hit testing

    private func keyframe(atViewX vx: CGFloat) -> ZoomKeyframe? {
        guard let model, let data else { return nil }
        let cx = vx - TimelineMetrics.gutter
        return data.keyframes.last { k in
            guard let e = model.timeline.editedTime(forSource: k.time) else { return false }
            let x0 = x(e)
            let x1 = max(x(e + k.effectiveEaseIn + k.hold + k.effectiveEaseOut), x0 + 6)
            return cx >= x0 - 2 && cx <= x1 + 2
        }
    }

    private enum BlurHit {
        case body, start, end
    }

    private func blur(atViewX vx: CGFloat) -> (BlurMask, BlurHit)? {
        guard let model, let data else { return nil }
        let cx = vx - TimelineMetrics.gutter
        // Prefer the selected mask when bars overlap.
        let ordered = data.blur.sorted { a, _ in data.selection == .blur(a.id) }
        for mask in ordered {
            guard let (e0, e1) = blurEditedRange(mask, model) else { continue }
            let x0 = x(e0)
            let x1 = x(e1)
            if abs(cx - x0) <= 5 { return (mask, .start) }
            if abs(cx - x1) <= 5 { return (mask, .end) }
            if cx > x0, cx < x1 { return (mask, .body) }
        }
        return nil
    }

    private func cue(atViewX vx: CGFloat) -> (SubtitleCue, BlurHit)? {
        guard let model, let data else { return nil }
        let cx = vx - TimelineMetrics.gutter
        let ordered = data.cues.sorted { a, _ in data.selection == .cue(a.id) }
        for cue in ordered {
            let e0 = model.timeline.editedTimeSnapping(forSource: cue.start)
            let e1 = model.timeline.editedTimeSnapping(forSource: cue.end)
            guard e1 - e0 > 0.001 else { continue }
            let x0 = x(e0)
            let x1 = x(e1)
            if abs(cx - x0) <= 4 { return (cue, .start) }
            if abs(cx - x1) <= 4 { return (cue, .end) }
            if cx > x0, cx < x1 { return (cue, .body) }
        }
        return nil
    }

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
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        guard p.x >= TimelineMetrics.gutter, let model else { return .arrow }
        let cx = p.x - TimelineMetrics.gutter
        switch row(at: p.y) {
        case .screen:
            if abs(cx - x(0)) <= 6 || abs(cx - x(model.timeline.duration)) <= 6 { return .resizeLeftRight }
        case .webcam:
            return .resizeLeftRight
        case .blur:
            if let (_, hit) = blur(atViewX: p.x) { return hit == .body ? .openHand : .resizeLeftRight }
        case .subtitles:
            if let (_, hit) = cue(atViewX: p.x) { return hit == .body ? .openHand : .resizeLeftRight }
        case .zoom:
            if keyframe(atViewX: p.x) != nil { return .openHand }
        default: break
        }
        return .arrow
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard p.x >= TimelineMetrics.gutter else { return }
        let cx = p.x - TimelineMetrics.gutter
        let t = time(atViewX: p.x)
        drag = nil

        if p.y < TimelineMetrics.rulerHeight || abs(cx - x(model.currentTime)) <= 3 {
            beginScrub(at: t)
            return
        }
        switch row(at: p.y) {
        case .screen:
            if abs(cx - x(0)) <= 6, let first = model.edit.segments.first {
                beginEdit(.trimStart(source: first.start, x: p.x))
            } else if abs(cx - x(model.timeline.duration)) <= 6, let last = model.edit.segments.last {
                beginEdit(.trimEnd(source: last.end, x: p.x))
            } else if let i = model.timeline.pieceIndex(forEdited: t) {
                model.selection = .segment(model.timeline.pieces[i].segment.id)
            }
        case .webcam:
            if event.clickCount >= 2 {
                model.update("Reset Webcam Sync") { $0.webcam.syncOffset = 0 }
            } else {
                beginEdit(.webcamSync(offset: model.edit.webcam.syncOffset, x: p.x))
            }
        case .zoom:
            if let k = keyframe(atViewX: p.x) {
                let modifier = SelectionModifier(event.modifierFlags)
                let keepGroup = KeyframeClick.begin(k.id, modifier: modifier, model: model)
                model.inspectorTab = .zoom
                if model.selectedKeyframeIDs.contains(k.id) {
                    let times = Dictionary(uniqueKeysWithValues: model.selectedKeyframes.map { ($0.id, $0.time) })
                    drag = .keyframes(times: times, x: p.x, moving: false, clickSelects: keepGroup ? k.id : nil)
                }
            } else {
                model.selection = nil
                beginScrub(at: t)
            }
        case .blur:
            if let (mask, hit) = blur(atViewX: p.x) {
                model.selection = .blur(mask.id)
                model.inspectorTab = .blur
                switch hit {
                case .body: beginEdit(.blurMove(mask.id, start: mask.start, end: mask.end, x: p.x))
                case .start: beginEdit(.blurStart(mask.id, start: mask.start, x: p.x))
                case .end: beginEdit(.blurEnd(mask.id, end: mask.end, x: p.x))
                }
            } else {
                model.selection = nil
                beginScrub(at: t)
            }
        case .subtitles:
            if let (cue, hit) = cue(atViewX: p.x) {
                model.selection = .cue(cue.id)
                model.inspectorTab = .subtitles
                switch hit {
                case .body:
                    beginEdit(.cueMove(cue.id, start: model.timeline.editedTimeSnapping(forSource: cue.start), x: p.x))
                case .start:
                    beginEdit(.cueStart(cue.id, start: model.timeline.editedTimeSnapping(forSource: cue.start), x: p.x))
                case .end:
                    beginEdit(.cueEnd(cue.id, end: model.timeline.editedTimeSnapping(forSource: cue.end), x: p.x))
                }
            } else {
                model.selection = nil
                beginScrub(at: t)
            }
        default:
            beginScrub(at: t)
        }
    }

    private func beginScrub(at t: Double) {
        drag = .scrub
        model?.seek(to: t, exact: false)
    }

    private func beginEdit(_ kind: Drag) {
        drag = kind
        switch kind {
        case .trimStart, .trimEnd: frozenPPS = pps
        default: break
        }
        model?.beginContinuousChange()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let seconds = { (from: CGFloat) in Double(p.x - from) / self.pps }
        switch drag {
        case .scrub:
            autoscroll(for: p)
            model.seek(to: time(atViewX: p.x), exact: false)
        case .trimStart(let source, let from):
            model.trimStart(toSource: source + seconds(from))
        case .trimEnd(let source, let from):
            model.trimEnd(toSource: source + seconds(from))
        case .webcamSync(let offset, let from):
            let value = min(max(offset + seconds(from), -5), 5)
            model.update("Webcam Sync") { $0.webcam.syncOffset = (value * 100).rounded() / 100 }
        case .blurMove(let id, let start, let end, let from):
            let length = end - start
            let s = min(max(start + seconds(from), 0), max(0, model.meta.duration - length))
            model.updateBlur(id, "Move Blur") {
                $0.start = s
                $0.end = s + length
            }
        case .blurStart(let id, let start, let from):
            model.updateBlur(id, "Resize Blur") { mask in
                mask.start = min(max(start + seconds(from), 0), mask.end - 0.5)
            }
        case .blurEnd(let id, let end, let from):
            model.updateBlur(id, "Resize Blur") { mask in
                mask.end = max(min(end + seconds(from), model.meta.duration), mask.start + 0.5)
            }
        case .cueMove(let id, let start, let from):
            model.moveCue(
                id,
                toStart: CueDragTime.sourceTime(
                    editedStart: start, editedDelta: seconds(from), timeline: model.timeline))
        case .cueStart(let id, let start, let from):
            model.setCueTiming(
                id,
                start: CueDragTime.sourceTime(editedStart: start, editedDelta: seconds(from), timeline: model.timeline))
        case .cueEnd(let id, let end, let from):
            model.setCueTiming(
                id, end: CueDragTime.sourceTime(editedStart: end, editedDelta: seconds(from), timeline: model.timeline))
        case .keyframes(let times, let from, let moving, _):
            if !moving {
                guard abs(p.x - from) >= 3 else { return }
                self.drag = .keyframes(times: times, x: from, moving: true, clickSelects: nil)
                model.beginContinuousChange()
            }
            model.moveKeyframes(times, by: seconds(from))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model, let drag else { return }
        self.drag = nil
        switch drag {
        case .scrub:
            model.seek(to: time(atViewX: convert(event.locationInWindow, from: nil).x), exact: true)
        case .keyframes(_, _, let moving, let clickSelects):
            if moving {
                model.endContinuousChange()
            } else {
                KeyframeClick.end(clickSelects, moving: moving, model: model)
            }
        default:
            frozenPPS = nil
            model.endContinuousChange()
            relayout()
        }
    }

    /// Scrolls while scrubbing past either edge.
    private func autoscroll(for p: CGPoint) {
        let left = TimelineMetrics.gutter + 16
        let right = bounds.width - TimelineMetrics.trailingPad - 16
        var delta: CGFloat = 0
        if p.x < left { delta = p.x - left } else if p.x > right { delta = p.x - right }
        guard delta != 0 else { return }
        let old = scrollX
        scrollX = min(max(scrollX + delta * 0.5, 0), maxScroll)
        if scrollX != old { relayout() }
    }

    // MARK: Scroll wheel: vertical zooms (0.5–4×), horizontal scrolls.

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        let p = convert(event.locationInWindow, from: nil)
        if abs(dy) > abs(dx), !event.modifierFlags.contains(.shift) {
            let factor = exp(Double(dy) * (precise ? 0.01 : 0.1))
            let newZoom = min(
                max(zoom * factor, TimelineMetrics.zoomRange.lowerBound), TimelineMetrics.zoomRange.upperBound)
            guard abs(newZoom - zoom) > 1e-6 else { return }
            let anchorX = min(max(p.x - TimelineMetrics.gutter, 0), visibleWidth)
            let anchorT = (anchorX + scrollX) / pps
            zoom = newZoom
            scrollX = anchorT * pps - anchorX
            model.timelineZoom = newZoom
            relayout()
        } else {
            let delta = abs(dx) >= abs(dy) ? dx : dy
            let old = scrollX
            scrollX = min(max(scrollX - delta * (precise ? 1 : 12), 0), maxScroll)
            if scrollX != old { relayout() }
        }
    }
}
