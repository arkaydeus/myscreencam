import Foundation
import ProjectKit
import RenderKit

/// Editing commands used by the transport, keyboard, timeline, preview and inspector.
extension EditorModel {
    // MARK: Segments

    func cutAtPlayhead() {
        do {
            apply(try edit.cut(atEdited: currentTime), action: "Cut")
        } catch .tooCloseToEdge {
            flash("Too close to edge")
        } catch {
            flash("Nothing to cut")
        }
    }

    var selectedSegmentID: Segment.ID? {
        if case .segment(let id) = selection { id } else { nil }
    }

    func deleteSelectedSegment() {
        guard let id = selectedSegmentID else { return }
        do {
            apply(try edit.deleteSegment(id: id), action: "Delete Segment")
            selection = nil
        } catch .lastSegment {
            flash("Can't delete the only segment")
        } catch {
            selection = nil
        }
    }

    func resetCuts() {
        apply(edit.resetCuts(duration: meta.duration), action: "Reset Cuts")
    }

    var hasCuts: Bool {
        edit.segments.count > 1
            || (edit.segments.first.map { $0.start > 0.001 || $0.end < meta.duration - 0.001 } ?? false)
    }

    /// Moves the start of the first segment (a trim drag; wrap in a continuous change).
    func trimStart(toSource s: Double) {
        if let next = try? edit.trimStart(toSource: s) { apply(next, action: "Trim Start") }
    }

    /// Moves the end of the last segment (a trim drag; wrap in a continuous change).
    func trimEnd(toSource s: Double) {
        if let next = try? edit.trimEnd(toSource: s, duration: meta.duration) { apply(next, action: "Trim End") }
    }

    /// Delete / Backspace: the selected segment, keyframe or blur mask.
    func deleteSelection() {
        switch selection {
        case .segment: deleteSelectedSegment()
        case .keyframe(let id): deleteKeyframe(id)
        case .blur(let id): deleteBlur(id)
        case nil: break
        }
    }

    // MARK: Zoom keyframes

    var selectedKeyframe: ZoomKeyframe? {
        guard case .keyframe(let id) = selection else { return nil }
        return edit.zoom.keyframes.first { $0.id == id }
    }

    func addKeyframeAtPlayhead() {
        let d = edit.zoom.defaults
        let keyframe = ZoomKeyframe(
            time: currentSourceTime, scale: d.scale, target: .center, mode: .manual, easeIn: d.easeIn, hold: d.hold,
            easeOut: d.easeOut)
        update("Add Zoom") { $0.zoom.keyframes.append(keyframe) }
        selection = .keyframe(keyframe.id)
        inspectorTab = .zoom
    }

    func updateKeyframe(
        _ id: ZoomKeyframe.ID, _ action: String, coalesce: AnyHashable? = nil, _ change: (inout ZoomKeyframe) -> Void
    ) {
        update(action, coalesce: coalesce) { edit in
            guard let i = edit.zoom.keyframes.firstIndex(where: { $0.id == id }) else { return }
            change(&edit.zoom.keyframes[i])
        }
    }

    /// Duplicates a keyframe, placed 0.2 s after its end.
    func duplicateKeyframe(_ id: ZoomKeyframe.ID) {
        guard let original = edit.zoom.keyframes.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.time = original.end + 0.2
        guard copy.time < meta.duration else {
            flash("No room after this zoom")
            return
        }
        update("Duplicate Zoom") { $0.zoom.keyframes.append(copy) }
        selection = .keyframe(copy.id)
    }

    func deleteKeyframe(_ id: ZoomKeyframe.ID) {
        update("Delete Zoom") { $0.zoom.keyframes.removeAll { $0.id == id } }
        if selection == .keyframe(id) { selection = nil }
    }

    /// Sets the selected keyframe's target from a point on the preview (normalised source coordinates).
    func setZoomTarget(_ point: NormPoint) {
        guard let keyframe = selectedKeyframe else { return }
        updateKeyframe(keyframe.id, "Set Zoom Target") {
            $0.target = point.clamped
            if $0.mode == .click { $0.mode = .manual }
        }
        isPickingZoomTarget = false
    }

    // MARK: Blur masks

    var selectedBlur: BlurMask? {
        guard case .blur(let id) = selection else { return nil }
        return edit.blur.first { $0.id == id }
    }

    func addBlurAtPlayhead() {
        let start = currentSourceTime
        guard start < meta.duration - 0.1 else {
            flash("Move the playhead before the end")
            return
        }
        let mask = BlurMask(start: start, end: min(meta.duration, start + 5))
        update("Add Blur") { $0.blur.append(mask) }
        selection = .blur(mask.id)
        inspectorTab = .blur
    }

    func updateBlur(
        _ id: BlurMask.ID, _ action: String, coalesce: AnyHashable? = nil, _ change: (inout BlurMask) -> Void
    ) {
        update(action, coalesce: coalesce) { edit in
            guard let i = edit.blur.firstIndex(where: { $0.id == id }) else { return }
            change(&edit.blur[i])
        }
    }

    func deleteBlur(_ id: BlurMask.ID) {
        update("Delete Blur") { $0.blur.removeAll { $0.id == id } }
        if selection == .blur(id) { selection = nil }
    }

    // MARK: Webcam

    var hasWebcam: Bool { recordedStreams.contains(.webcam) }

    /// Camera pixel size (for the overlay's aspect).
    var cameraSize: CGSize {
        guard let webcam = meta.webcam else { return CGSize(width: 16, height: 9) }
        return CGSize(width: webcam.pixelWidth, height: webcam.pixelHeight)
    }

    /// The overlay height as a fraction of the canvas height, for the current layout.
    func webcamHeightFraction(for settings: WebcamSettings) -> Double {
        let canvas = renderer.layout.canvasSize
        let frame = WebcamLayout.frame(for: settings, cameraSize: cameraSize, canvasSize: canvas)
        return canvas.height > 0 ? frame.height / canvas.height : 0
    }

    enum WebcamCorner: String, CaseIterable, Identifiable {
        case topLeft, topRight, center, bottomLeft, bottomRight
        var id: Self { self }

        var title: String {
            switch self {
            case .topLeft: "Top Left"
            case .topRight: "Top Right"
            case .center: "Centre"
            case .bottomLeft: "Bottom Left"
            case .bottomRight: "Bottom Right"
            }
        }

        var systemImage: String {
            switch self {
            case .topLeft: "arrow.up.left.square"
            case .topRight: "arrow.up.right.square"
            case .center: "square.dashed"
            case .bottomLeft: "arrow.down.left.square"
            case .bottomRight: "arrow.down.right.square"
            }
        }
    }

    /// Moves the webcam to a preset position (3% margin).
    func placeWebcam(_ corner: WebcamCorner) {
        let margin = 0.03
        let w = edit.webcam.width
        let h = webcamHeightFraction(for: edit.webcam)
        let marginY = margin * renderer.layout.canvasSize.width / max(renderer.layout.canvasSize.height, 1)
        let origin: NormPoint =
            switch corner {
            case .topLeft: NormPoint(x: margin, y: marginY)
            case .topRight: NormPoint(x: 1 - w - margin, y: marginY)
            case .center: NormPoint(x: (1 - w) / 2, y: (1 - h) / 2)
            case .bottomLeft: NormPoint(x: margin, y: 1 - h - marginY)
            case .bottomRight: NormPoint(x: 1 - w - margin, y: 1 - h - marginY)
            }
        update("Move Webcam") { $0.webcam.origin = origin.clamped }
    }

    /// Resizes the webcam keeping its centre (size presets).
    func setWebcamWidth(_ width: Double) {
        var webcam = edit.webcam
        let oldH = webcamHeightFraction(for: webcam)
        let cx = webcam.origin.x + webcam.width / 2
        let cy = webcam.origin.y + oldH / 2
        webcam.width = width
        let newH = webcamHeightFraction(for: webcam)
        webcam.origin = NormPoint(
            x: min(max(cx - width / 2, 0), max(0, 1 - width)), y: min(max(cy - newH / 2, 0), max(0, 1 - newH)))
        update("Resize Webcam") { $0.webcam = webcam }
    }
}
