import CoreImage
import Foundation
import ProjectKit

/// Builds the Core Image recipe for one output frame. Pure: the same inputs always give the same image, which is
/// what makes preview and export identical.
///
/// Effect order (docs/legacy-inventory.md §4): screen → blur masks → cursor (source space, so it zooms with the
/// content) → zoom crop/scale → background canvas → webcam overlay (not zoomed) → subtitles (canvas space).
///
/// Work happens in a *working space*: the source scaled by `k = min(1, contentWidth·zoom / sourceWidth)`, so a 4K
/// recording previewed in a small window is shrunk once up front instead of being blurred and composited at 4K.
/// Every source-pixel quantity (blur radius, cursor size, highlight radius) is multiplied by `k`, so the result
/// matches rendering at full resolution.
enum FrameRenderer {
    /// Click pulse: the cursor scales 1 → 1.3 → 1 over this many seconds after a mouse-down.
    static let pulseDuration = 0.3
    static let pulseAmount = 0.3
    /// Seconds between drag-trail ghosts.
    static let trailSpacing = 1.0 / 60.0

    /// Cursor pulse scale `t` seconds after a click (1 outside the pulse).
    static func pulseScale(sinceClick dt: Double) -> Double {
        guard dt >= 0, dt < pulseDuration else { return 1 }
        return 1 + pulseAmount * sin(.pi * dt / pulseDuration)
    }

    /// Click highlight at progress `p` = (t − t0) / duration: radius `R·p`, opacity `0.5·(1 − p)`.
    static func highlight(radius: Double, progress p: Double) -> (radius: Double, opacity: Double)? {
        guard p >= 0, p < 1 else { return nil }
        return (radius * p, 0.5 * (1 - p))
    }

    /// Composes the frame at `sourceTime` into a `canvasSize` image (Core Image space, origin at zero).
    /// - Parameters:
    ///   - screen: the screen frame, or nil when the screen track has no media here (renders black).
    ///   - webcam: the webcam frame, or nil when the webcam isn't covering this moment.
    ///
    /// Video frames are scaled with plain affine transforms, never Lanczos: Core Image samples them straight from the
    /// decoded surface inside the frame's one render pass (with its own multi-pass downsampling for reductions
    /// below 50%). Lanczos needs full-resolution half-float intermediates per frame, and every new zoom scale needs
    /// a new set, so it cost ~1.5 ms of CPU per frame and ~700 MB of cached IOSurfaces during exports.
    static func compose(
        screen: CIImage?, webcam: CIImage?, snapshot: RenderSnapshot, sourceTime t: Double, canvasSize: CGSize
    ) -> CIImage {
        let layout = snapshot.layout
        let edit = snapshot.edit
        let canvasRect = CGRect(origin: .zero, size: layout.canvasSize)
        let content = layout.contentRect
        let sourceW = max(layout.sourceSize.width, 1)
        let sourceH = max(layout.sourceSize.height, 1)

        let zoom = snapshot.zoom.state(at: t)
        let z = max(zoom.scale, 1)
        let k = min(1, max(content.width * z / sourceW, 1e-3))
        let work = CGSize(width: sourceW * k, height: sourceH * k)
        let workRect = CGRect(origin: .zero, size: work)

        // 1. Screen, normalised to the working space.
        var image: CIImage
        if let screen, screen.extent.width > 0, screen.extent.height > 0 {
            let e = screen.extent
            image = screen.transformed(
                by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                    .concatenating(CGAffineTransform(scaleX: work.width / e.width, y: work.height / e.height)))
        } else {
            image = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: workRect)
        }

        // 2. Blur masks (Gaussian, radius in source pixels).
        for mask in BlurLayout.active(edit.blur, at: t) {
            let rect = BlurLayout.sourceRect(for: mask, sourceSize: layout.sourceSize)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            let scaled = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
            let region = CIHelpers.flip(scaled, height: work.height)
            let sigma = min(max(mask.intensity, 0), 200) * k
            guard sigma > 0.01 else { continue }
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: region)
            image = blurred.composited(over: image)
        }

        // 3. Cursor, in source (working) space.
        if let track = snapshot.cursorTrack {
            image = drawCursor(on: image, track: track, snapshot: snapshot, t: t, k: k, work: work)
        }
        image = image.cropped(to: workRect)

        // 4. Zoom: crop the visible part and scale it into the content rect.
        let crop = zoom.cropRect(in: work)
        let cropCI = CIHelpers.flip(crop, height: work.height)
        let contentCI = CIHelpers.flip(content, height: layout.canvasSize.height)
        var placed = image.cropped(to: cropCI)
            .transformed(by: CGAffineTransform(translationX: -cropCI.minX, y: -cropCI.minY))
            .transformed(
                by: CGAffineTransform(scaleX: contentCI.width / cropCI.width, y: contentCI.height / cropCI.height)
            )
            .transformed(by: CGAffineTransform(translationX: contentCI.minX, y: contentCI.minY))
            .cropped(to: contentCI)

        // 5. Background canvas.
        var output: CIImage
        if let background = snapshot.backgroundLayer {
            if let mask = snapshot.contentMask { placed = CIHelpers.masked(placed, by: mask) }
            output = placed.composited(over: background)
        } else {
            output = placed
        }

        // 6. Webcam overlay (not zoomed).
        if edit.webcam.enabled, let webcam, webcam.extent.width > 0, webcam.extent.height > 0 {
            output = drawWebcam(webcam, over: output, snapshot: snapshot)
        }

        // 7. Subtitles, in canvas space (never zoomed).
        if edit.subtitles.enabled, !edit.subtitles.cues.isEmpty {
            output = SubtitleRenderer.draw(over: output, snapshot: snapshot, t: t)
        }

        output = output.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvasRect))
            .cropped(to: canvasRect)
        if canvasSize != layout.canvasSize, layout.canvasSize.width > 0, layout.canvasSize.height > 0 {
            output = output.transformed(
                by: CGAffineTransform(
                    scaleX: canvasSize.width / layout.canvasSize.width, y: canvasSize.height / layout.canvasSize.height)
            ).cropped(to: CGRect(origin: .zero, size: canvasSize))
        }
        return output
    }

    // MARK: cursor

    private static func drawCursor(
        on image: CIImage, track: CursorTrack, snapshot: RenderSnapshot, t: Double, k: Double, work: CGSize
    ) -> CIImage {
        let settings = snapshot.edit.cursor
        let opacity = track.opacity(at: t, hideWhenIdle: settings.hideWhenIdle, idleDelay: settings.idleDelay)
        guard opacity > 0.001, let position = track.position(at: t) else { return image }
        var image = image
        let pointsToWork = snapshot.screenScale * k

        func workPoint(_ p: NormPoint) -> CGPoint {
            CGPoint(x: p.x * work.width, y: work.height - p.y * work.height)
        }

        // Click highlight circles (under the cursor, at the click position).
        let highlight = settings.clickHighlight
        if highlight.enabled, highlight.duration > 0 {
            for click in track.recentClicks(at: t, within: highlight.duration) {
                let p = (t - click.time) / highlight.duration
                guard let h = Self.highlight(radius: highlight.radius * pointsToWork, progress: p), h.radius > 0.5
                else { continue }
                image = circle(
                    at: workPoint(click.position), radius: h.radius, color: highlight.color, opacity: h.opacity
                )
                .composited(over: image)
            }
        }

        let art = snapshot.resources.cursorImages.artKey(style: settings.style, cursorID: track.cursorID(at: t))
        let density = pointsToWork * settings.size.multiplier
        guard let sprite = snapshot.resources.cursorImages.sprite(for: art, pixelsPerPoint: density) else {
            return image
        }

        // Drag trail: fading ghosts at earlier positions while a button is held (oldest first).
        let trail = settings.dragTrail
        if trail.enabled {
            let ghosts = track.trail(at: t, length: min(max(trail.length, 0), 30), spacing: trailSpacing)
            for ghost in ghosts.reversed() {
                let alpha = trail.opacity * (1 - ghost.age) * opacity
                image = place(sprite, at: workPoint(ghost.position), scale: 1, opacity: alpha).composited(over: image)
            }
        }

        var scale = 1.0
        if settings.clickPulse, let last = track.recentClicks(at: t, within: pulseDuration).last {
            scale = pulseScale(sinceClick: t - last.time)
        }
        return place(sprite, at: workPoint(position), scale: scale, opacity: opacity).composited(over: image)
    }

    /// Positions `sprite` so its hotspot lands on `point` (Core Image space), scaled about the hotspot.
    private static func place(_ sprite: CursorSprite, at point: CGPoint, scale: Double, opacity: Double) -> CIImage {
        let hotspot = CGPoint(x: sprite.hotspot.x, y: sprite.size.height - sprite.hotspot.y)
        let transform = CGAffineTransform(translationX: -hotspot.x, y: -hotspot.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
        return CIHelpers.fade(sprite.image.transformed(by: transform), opacity: opacity)
    }

    /// An anti-aliased filled circle.
    private static func circle(at center: CGPoint, radius: Double, color: RGBAColor, opacity: Double) -> CIImage {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        return CIHelpers.roundedRect(rect, radius: radius, color: CIHelpers.color(color, opacity: opacity))
    }

    // MARK: webcam

    private static func drawWebcam(_ webcam: CIImage, over output: CIImage, snapshot: RenderSnapshot) -> CIImage {
        let settings = snapshot.edit.webcam
        let e = webcam.extent
        let cameraSize = e.size
        let crop = WebcamLayout.cropRect(for: settings.aspect, cameraSize: cameraSize)
        let overlay = snapshot.webcamOverlay(cameraSize: cameraSize)
        let frame = overlay.frame
        let frameCI = overlay.frameCI
        guard frame.width >= 1, frame.height >= 1, crop.width >= 1, crop.height >= 1 else { return output }
        let cropCI = CGRect(
            x: e.minX + crop.minX, y: e.minY + (cameraSize.height - crop.maxY), width: crop.width, height: crop.height)

        var camera = webcam.cropped(to: cropCI)
            .transformed(by: CGAffineTransform(translationX: -cropCI.minX, y: -cropCI.minY))
        if settings.mirrored {
            camera = camera.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -crop.width, y: 0))
        }
        camera = camera.transformed(
            by: CGAffineTransform(scaleX: frame.width / crop.width, y: frame.height / crop.height)
                .concatenating(CGAffineTransform(translationX: frameCI.minX, y: frameCI.minY))
        )
        .cropped(to: frameCI)

        if let mask = overlay.mask { camera = CIHelpers.masked(camera, by: mask) }
        let result = overlay.shadow.map { $0.composited(over: output) } ?? output
        return camera.composited(over: result)
    }
}
