import CoreGraphics
import Foundation
import ProjectKit

/// Hit-testing helpers for the editor preview.
///
/// Three spaces are involved, all with the origin top-left and y down:
/// - **view** points: the preview view (the canvas is aspect-fitted in it, like `AVLayerVideoGravity.resizeAspect`);
/// - **canvas** pixels: the rendered frame (`CanvasLayout.canvasSize`);
/// - **normalised source**: 0…1 over the recording, the space of zoom targets, blur rects, the crop and cursor events.
///
/// The content shows the layout's crop of the source. The zoom state (relative to the crop) is needed to map through
/// the zoomed content; pass `.identity` for the unzoomed frame.
public struct PreviewGeometry: Sendable, Equatable {
    public let layout: CanvasLayout

    public init(layout: CanvasLayout) {
        self.layout = layout
    }

    /// Where the canvas is drawn inside a view of `viewSize` (aspect fit, centred).
    public func videoRect(inViewOfSize viewSize: CGSize) -> CGRect {
        let canvas = layout.canvasSize
        guard canvas.width > 0, canvas.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let s = min(viewSize.width / canvas.width, viewSize.height / canvas.height)
        let w = canvas.width * s
        let h = canvas.height * s
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// View point → canvas pixel.
    public func canvasPoint(fromView point: CGPoint, viewSize: CGSize) -> CGPoint {
        let rect = videoRect(inViewOfSize: viewSize)
        guard rect.width > 0 else { return .zero }
        let s = layout.canvasSize.width / rect.width
        return CGPoint(x: (point.x - rect.minX) * s, y: (point.y - rect.minY) * s)
    }

    /// Canvas pixel → view point.
    public func viewPoint(fromCanvas point: CGPoint, viewSize: CGSize) -> CGPoint {
        let rect = videoRect(inViewOfSize: viewSize)
        guard layout.canvasSize.width > 0 else { return .zero }
        let s = rect.width / layout.canvasSize.width
        return CGPoint(x: rect.minX + point.x * s, y: rect.minY + point.y * s)
    }

    /// Canvas rect → view rect.
    public func viewRect(fromCanvas rect: CGRect, viewSize: CGSize) -> CGRect {
        let a = viewPoint(fromCanvas: rect.origin, viewSize: viewSize)
        let b = viewPoint(fromCanvas: CGPoint(x: rect.maxX, y: rect.maxY), viewSize: viewSize)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Canvas pixel → normalised source point through the zoom and crop (not clamped; outside 0…1 when off the
    /// content). Use it for click-to-set zoom targets (pass `.identity` to pick on the unzoomed frame) and blur
    /// dragging. `zoom` is relative to the crop, as `ZoomEvaluator` gives it.
    public func sourcePoint(fromCanvas point: CGPoint, zoom: ZoomState = .identity) -> NormPoint {
        let content = layout.contentRect
        let visible = NormPoint(
            x: (point.x - content.minX) / max(content.width, 1), y: (point.y - content.minY) / max(content.height, 1))
        let local = zoom.sourcePoint(fromVisible: visible)
        let crop = layout.normalizedCrop
        return NormPoint(x: crop.x + local.x * crop.w, y: crop.y + local.y * crop.h)
    }

    /// Normalised source point → canvas pixel through the crop and zoom.
    public func canvasPoint(fromSource point: NormPoint, zoom: ZoomState = .identity) -> CGPoint {
        let crop = layout.normalizedCrop
        let local = NormPoint(x: (point.x - crop.x) / max(crop.w, 1e-9), y: (point.y - crop.y) / max(crop.h, 1e-9))
        let visible = zoom.visiblePoint(fromSource: local)
        let content = layout.contentRect
        return CGPoint(x: content.minX + visible.x * content.width, y: content.minY + visible.y * content.height)
    }

    /// Normalised source rect (e.g. a blur mask) → canvas rect through the zoom.
    public func canvasRect(fromSource rect: NormRect, zoom: ZoomState = .identity) -> CGRect {
        let a = canvasPoint(fromSource: NormPoint(x: rect.x, y: rect.y), zoom: zoom)
        let b = canvasPoint(fromSource: NormPoint(x: rect.x + rect.w, y: rect.y + rect.h), zoom: zoom)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Canvas rect → normalised source rect through the zoom (for writing back a dragged blur mask).
    public func sourceRect(fromCanvas rect: CGRect, zoom: ZoomState = .identity) -> NormRect {
        let a = sourcePoint(fromCanvas: rect.origin, zoom: zoom)
        let b = sourcePoint(fromCanvas: CGPoint(x: rect.maxX, y: rect.maxY), zoom: zoom)
        return NormRect(x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y)
    }

    /// The webcam overlay rect in canvas pixels.
    public func webcamRect(for settings: WebcamSettings, cameraSize: CGSize) -> CGRect {
        WebcamLayout.frame(for: settings, cameraSize: cameraSize, canvasSize: layout.canvasSize)
    }

    /// Canvas point → normalised canvas point (the space of `WebcamSettings.origin`/`width`).
    public func normalizedCanvasPoint(fromCanvas point: CGPoint) -> NormPoint {
        WebcamLayout.origin(forTopLeft: point, canvasSize: layout.canvasSize)
    }
}
