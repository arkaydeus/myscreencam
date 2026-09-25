import CoreGraphics
import Foundation
import ProjectKit

/// How big the rendered output is.
public enum RenderSizing: Sendable, Equatable {
    /// Scale the natural canvas (source pixels, plus the background frame) by this factor, e.g. 0.5 for 50%.
    case scale(Double)
    /// Fit the natural canvas inside this box (never upscales), e.g. the preview view's backing size.
    case fit(width: Double, height: Double)
}

/// Rounds output dimensions to even pixel counts (video encoders need even sizes for 4:2:0).
public enum EvenPixels {
    /// Nearest even integer ≥ 2.
    public static func round(_ value: Double) -> Int {
        guard value.isFinite else { return 2 }
        return max(2, Int((value / 2).rounded()) * 2)
    }
}

/// Where the recording sits on the output canvas. All rects are in canvas pixels, origin top-left, y down.
public struct CanvasLayout: Sendable, Equatable {
    /// Source (screen) pixel size.
    public let sourceSize: CGSize
    /// Output size; both dimensions even.
    public let canvasSize: CGSize
    /// Where the (zoomed) screen content is drawn. Equal to the whole canvas when the background is off.
    public let contentRect: CGRect

    public init(sourceSize: CGSize, canvasSize: CGSize, contentRect: CGRect) {
        self.sourceSize = sourceSize
        self.canvasSize = canvasSize
        self.contentRect = contentRect
    }

    /// Canvas pixels per source pixel at 1× zoom.
    public var contentScale: Double { contentRect.width / max(sourceSize.width, 1) }

    /// A resolution-independent unit for output-space effects (shadows): 1 at a 1080-pixel shorter side.
    public var outputUnit: Double { min(canvasSize.width, canvasSize.height) / 1080 }

    /// Lays out a `sourceSize` recording.
    ///
    /// - Background off: the canvas is the source scaled by the sizing.
    /// - Background on: the canvas takes the requested aspect ratio around the source (keeping the source's
    ///   pixel density), then `padding × shorter side` is inset and the source is aspect-fitted and centred.
    public static func make(sourceSize: CGSize, background: BackgroundSettings, sizing: RenderSizing) -> CanvasLayout {
        let sw = max(sourceSize.width, 1)
        let sh = max(sourceSize.height, 1)
        var natural = CGSize(width: sw, height: sh)
        if background.enabled, let ratio = background.aspect.ratio {
            if ratio >= sw / sh {
                natural = CGSize(width: sh * ratio, height: sh)
            } else {
                natural = CGSize(width: sw, height: sw / ratio)
            }
        }
        let factor: Double
        switch sizing {
        case .scale(let s):
            factor = s > 0 ? s : 1
        case .fit(let w, let h):
            factor = min(1, min(max(w, 2) / natural.width, max(h, 2) / natural.height))
        }
        let canvas = CGSize(
            width: Double(EvenPixels.round(natural.width * factor)),
            height: Double(EvenPixels.round(natural.height * factor)))

        guard background.enabled else {
            return CanvasLayout(
                sourceSize: sourceSize, canvasSize: canvas, contentRect: CGRect(origin: .zero, size: canvas))
        }
        let padding = min(max(background.padding, 0), 0.45) * min(canvas.width, canvas.height)
        let inner = CGRect(origin: .zero, size: canvas).insetBy(dx: padding, dy: padding)
        let fit = min(inner.width / sw, inner.height / sh)
        let w = (sw * fit).rounded()
        let h = (sh * fit).rounded()
        let content = CGRect(
            x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded(), width: w, height: h)
        return CanvasLayout(sourceSize: sourceSize, canvasSize: canvas, contentRect: content)
    }

    /// Content corner radius in canvas pixels for `background.cornerRadius` (a fraction of the shorter side).
    public func contentCornerRadius(_ background: BackgroundSettings) -> Double {
        guard background.enabled else { return 0 }
        return min(max(background.cornerRadius, 0), 0.5) * min(contentRect.width, contentRect.height)
    }
}

/// Webcam overlay geometry.
public enum WebcamLayout {
    /// The overlay rect in canvas pixels (y down). `origin` and `width` are fractions of the canvas; the height
    /// follows the camera's aspect (`.wide`) or equals the width (`.square`).
    public static func frame(for settings: WebcamSettings, cameraSize: CGSize, canvasSize: CGSize) -> CGRect {
        let w = max(settings.width, 0) * canvasSize.width
        let aspect: Double
        switch settings.aspect {
        case .wide: aspect = cameraSize.height > 0 ? cameraSize.width / cameraSize.height : 16.0 / 9.0
        case .square: aspect = 1
        }
        return CGRect(
            x: settings.origin.x * canvasSize.width, y: settings.origin.y * canvasSize.height, width: w,
            height: w / aspect)
    }

    /// The part of the camera image shown (camera pixels, y down): all of it, or a centred square.
    public static func cropRect(for aspect: WebcamSettings.Aspect, cameraSize: CGSize) -> CGRect {
        switch aspect {
        case .wide:
            return CGRect(origin: .zero, size: cameraSize)
        case .square:
            let side = min(cameraSize.width, cameraSize.height)
            return CGRect(
                x: (cameraSize.width - side) / 2, y: (cameraSize.height - side) / 2, width: side, height: side)
        }
    }

    /// Corner radius in canvas pixels: `cornerRadius × shorter side` (0.5 = circle or pill).
    public static func cornerRadius(for settings: WebcamSettings, frame: CGRect) -> Double {
        min(max(settings.cornerRadius, 0), 0.5) * min(frame.width, frame.height)
    }

    /// Normalised origin that places an overlay's top-left corner at `canvasPoint` (for dragging on the preview).
    public static func origin(forTopLeft canvasPoint: CGPoint, canvasSize: CGSize) -> NormPoint {
        NormPoint(x: canvasPoint.x / max(canvasSize.width, 1), y: canvasPoint.y / max(canvasSize.height, 1))
    }
}

/// Blur mask geometry.
public enum BlurLayout {
    /// The mask rect in source pixels (y down), clipped to the frame.
    public static func sourceRect(for mask: BlurMask, sourceSize: CGSize) -> CGRect {
        mask.rect.denormalized(in: sourceSize).intersection(CGRect(origin: .zero, size: sourceSize))
    }

    /// Masks active at source time `t` (`start ≤ t ≤ end`).
    public static func active(_ masks: [BlurMask], at t: Double) -> [BlurMask] {
        masks.filter { t >= $0.start && t <= $0.end && $0.rect.w > 0 && $0.rect.h > 0 }
    }
}
