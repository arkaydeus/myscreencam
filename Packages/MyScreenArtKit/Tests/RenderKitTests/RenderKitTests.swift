import CoreGraphics
import Foundation
import ProjectKit
import Testing

@testable import RenderKit

struct EasingTests {
    @Test(arguments: [(0.0, 0.0), (1.0, 1.0), (0.5, 0.5), (0.25, 0.0625), (0.75, 0.9375), (-1.0, 0.0), (2.0, 1.0)])
    func easeInOutCubic(p: Double, expected: Double) {
        #expect(abs(Easing.easeInOutCubic(p) - expected) < 1e-12)
    }

    @Test func symmetricAndMonotonic() {
        var previous = -1.0
        for i in 0...100 {
            let p = Double(i) / 100
            let e = Easing.easeInOutCubic(p)
            #expect(e >= previous)
            #expect(abs(e + Easing.easeInOutCubic(1 - p) - 1) < 1e-12)
            previous = e
        }
    }
}

struct ZoomTests {
    let size = CGSize(width: 1000, height: 500)

    @Test func cropFormula() {
        #expect(
            ZoomState(scale: 2, pivot: NormPoint(x: 0, y: 0)).cropRect(in: size)
                == CGRect(x: 0, y: 0, width: 500, height: 250))
        #expect(
            ZoomState(scale: 2, pivot: NormPoint(x: 1, y: 1)).cropRect(in: size)
                == CGRect(x: 500, y: 250, width: 500, height: 250))
        #expect(
            ZoomState(scale: 4, pivot: NormPoint(x: 0.5, y: 0.25)).cropRect(in: size)
                == CGRect(x: 375, y: 93.75, width: 250, height: 125))
        // Pivots outside 0…1 are clamped, so the crop always stays in bounds.
        let crop = ZoomState(scale: 3, pivot: NormPoint(x: 1.4, y: -0.2)).cropRect(in: size)
        #expect(crop.maxX <= size.width + 1e-9 && crop.minY >= 0)
        #expect(ZoomState.identity.cropRect(in: size) == CGRect(origin: .zero, size: size))
    }

    @Test func pivotPointStaysFixed() {
        // Scaling about the pivot keeps the pivot's source point at the same place in the view.
        let zoom = ZoomState(scale: 2.5, pivot: NormPoint(x: 0.3, y: 0.7))
        let visible = zoom.visiblePoint(fromSource: NormPoint(x: 0.3, y: 0.7))
        #expect(abs(visible.x - 0.3) < 1e-12 && abs(visible.y - 0.7) < 1e-12)
        let back = zoom.sourcePoint(fromVisible: visible)
        #expect(abs(back.x - 0.3) < 1e-12 && abs(back.y - 0.7) < 1e-12)
    }

    let keyframe = ZoomKeyframe(
        time: 1, scale: 2, target: NormPoint(x: 0.2, y: 0.8), easeIn: 0.2, hold: 1, easeOut: 0.2)

    @Test(arguments: [(0.5, 1.0), (1.0, 1.0), (1.1, 1.5), (1.2, 2.0), (1.5, 2.0), (2.3, 1.5), (2.4, 1.0), (3.0, 1.0)])
    func phases(t: Double, scale: Double) {
        let evaluator = ZoomEvaluator(settings: ZoomSettings(keyframes: [keyframe]))
        #expect(abs(evaluator.state(at: t).scale - scale) < 1e-9)
    }

    @Test func easedNotLinear() {
        // A quarter of the way through the ease-in, easeInOutCubic gives 1 + 0.0625, not 1.25.
        let evaluator = ZoomEvaluator(settings: ZoomSettings(keyframes: [keyframe]))
        #expect(abs(evaluator.state(at: 1.05).scale - 1.0625) < 1e-9)
    }

    @Test func instantIsAStep() {
        var k = keyframe
        k.instant = true
        let evaluator = ZoomEvaluator(settings: ZoomSettings(keyframes: [k]))
        #expect(evaluator.state(at: 0.9999).scale == 1)
        #expect(evaluator.state(at: 1).scale == 2)
        #expect(evaluator.state(at: 1.9999).scale == 2)
        #expect(evaluator.state(at: 2).scale == 1)
        #expect(k.end == 2)
    }

    @Test func earliestOverlappingWins() {
        let later = ZoomKeyframe(time: 1.5, scale: 3, target: NormPoint(x: 0.9, y: 0.1), easeIn: 0, hold: 3, easeOut: 0)
        let evaluator = ZoomEvaluator(settings: ZoomSettings(keyframes: [later, keyframe]))
        let during = evaluator.state(at: 1.6)
        #expect(during.scale == 2 && during.pivot == NormPoint(x: 0.2, y: 0.8))
        // After the earlier one ends, the later one shows.
        #expect(evaluator.state(at: 3).scale == 3)
    }

    @Test func disabledKeyframesAndZoomOff() {
        var k = keyframe
        k.enabled = false
        #expect(ZoomEvaluator(settings: ZoomSettings(keyframes: [k])).state(at: 1.5) == .identity)
        #expect(
            ZoomEvaluator(settings: ZoomSettings(enabled: false, keyframes: [keyframe])).state(at: 1.5) == .identity)
    }

    @Test func pivotCenteredOnClamps() {
        #expect(ZoomState.pivot(centeredOn: .center, scale: 2) == NormPoint(x: 0.5, y: 0.5))
        #expect(ZoomState.pivot(centeredOn: NormPoint(x: 0, y: 1), scale: 2) == NormPoint(x: 0, y: 1))
        // Centre 0.3 at 2×: visible 0.5 wide → origin 0.05 → pivot 0.05 / 0.5 = 0.1.
        let p = ZoomState.pivot(centeredOn: NormPoint(x: 0.3, y: 0.3), scale: 2)
        #expect(abs(p.x - 0.1) < 1e-12)
        let crop = ZoomState(scale: 2, pivot: p).cropRect(in: CGSize(width: 1, height: 1))
        #expect(abs(crop.midX - 0.3) < 1e-12)
    }

    @Test func followMouseTracksCursorAndStaysInBounds() {
        // Cursor sits near the top-right corner.
        let events = [
            InputEvent(t: 0, kind: .move, x: 0.97, y: 0.03), InputEvent(t: 5, kind: .move, x: 0.97, y: 0.03),
        ]
        let cursor = CursorTrack(events: events, smoothing: .medium)
        let follow = FollowCameraTrack(cursor: cursor)
        let k = ZoomKeyframe(time: 0, scale: 2, mode: .followMouse, easeIn: 0, hold: 5, easeOut: 0)
        let evaluator = ZoomEvaluator(settings: ZoomSettings(keyframes: [k]), follow: follow)
        let state = evaluator.state(at: 2)
        let crop = state.cropRect(in: CGSize(width: 1, height: 1))
        #expect(crop.maxX <= 1 + 1e-9 && crop.minY >= -1e-9)
        #expect(state.pivot.x > 0.99 && state.pivot.y < 0.01)
    }

    @Test func followCameraIgnoresJitterInsideDeadZone() {
        var events: [InputEvent] = []
        for i in 0..<200 {
            let jitter = (i % 2 == 0 ? 1.0 : -1.0) * 0.03
            events.append(InputEvent(t: Double(i) * 0.02, kind: .move, x: 0.5 + jitter, y: 0.5 - jitter))
        }
        let follow = FollowCameraTrack(cursor: CursorTrack(events: events, smoothing: .none))
        // The camera starts on the first position and never moves: ±0.03 jitter is inside the dead zone.
        for t in stride(from: 0.0, through: 4.0, by: 0.1) {
            let c = follow.center(at: t)!
            #expect(abs(c.x - 0.53) < 1e-6 && abs(c.y - 0.47) < 1e-6)
        }
        // A real move drags the camera along (lagging by at most the dead zone once settled).
        let moved = FollowCameraTrack(
            cursor: CursorTrack(
                events: [InputEvent(t: 0, kind: .move, x: 0.2, y: 0.5), InputEvent(t: 1, kind: .move, x: 0.8, y: 0.5)],
                smoothing: .none))
        let settled = moved.center(at: 4)!
        #expect(abs(settled.x - 0.8) <= moved.deadZone + 1e-3)
    }
}

struct CursorTrackTests {
    @Test func linearWithoutSmoothing() {
        let track = CursorTrack(
            events: [InputEvent(t: 1, kind: .move, x: 0, y: 0), InputEvent(t: 2, kind: .move, x: 1, y: 0.5)],
            smoothing: .none)
        #expect(track.position(at: 0.99) == nil)
        #expect(track.position(at: 1.25) == NormPoint(x: 0.25, y: 0.125))
        #expect(track.position(at: 5) == NormPoint(x: 1, y: 0.5))
    }

    /// A step from 0.2 to 0.8 at t = 1.
    let step = [
        InputEvent(t: 0, kind: .move, x: 0.2, y: 0.2), InputEvent(t: 1, kind: .move, x: 0.2, y: 0.2),
        InputEvent(t: 1.0001, kind: .move, x: 0.8, y: 0.8),
    ]

    @Test(arguments: [CursorSmoothing.rapid, .medium, .slow])
    func smoothingConvergesWithoutOvershoot(smoothing: CursorSmoothing) {
        let track = CursorTrack(events: step, smoothing: smoothing)
        var previous = 0.0
        var maxX = 0.0
        for i in 0...600 {
            let x = track.position(at: 1 + Double(i) / 240)!.x
            #expect(x >= previous - 1e-6)  // monotonic approach
            previous = x
            maxX = max(maxX, x)
        }
        #expect(maxX <= 0.8 + 1e-5)
        #expect(abs(track.position(at: 3.5)!.x - 0.8) < 0.005)
        // It lags right after the step.
        #expect(track.position(at: 1.02)!.x < 0.75)
    }

    @Test func slowerSmoothingLagsMore() {
        let rapid = CursorTrack(events: step, smoothing: .rapid).position(at: 1.1)!.x
        let medium = CursorTrack(events: step, smoothing: .medium).position(at: 1.1)!.x
        let slow = CursorTrack(events: step, smoothing: .slow).position(at: 1.1)!.x
        #expect(rapid > medium && medium > slow)
    }

    @Test func hiddenBeforeFirstEventAndIdleFade() {
        let track = CursorTrack(
            events: [InputEvent(t: 1, kind: .move, x: 0.5, y: 0.5), InputEvent(t: 2, kind: .move, x: 0.6, y: 0.5)],
            smoothing: .none)
        #expect(track.opacity(at: 0.5, hideWhenIdle: false, idleDelay: 2) == 0)
        #expect(track.opacity(at: 10, hideWhenIdle: false, idleDelay: 2) == 1)
        #expect(track.opacity(at: 3.9, hideWhenIdle: true, idleDelay: 2) == 1)
        #expect(
            abs(track.opacity(at: 4 + CursorTrack.idleFadeDuration / 2, hideWhenIdle: true, idleDelay: 2) - 0.5) < 1e-9)
        #expect(track.opacity(at: 5, hideWhenIdle: true, idleDelay: 2) == 0)
        #expect(track.opacity(at: 1.05, hideWhenIdle: true, idleDelay: 0.1) == 1)
    }

    @Test func cursorIDsClicksAndDrags() {
        let events = [
            InputEvent(t: 0, kind: .move, x: 0.1, y: 0.1, cursor: 3),
            InputEvent(t: 1, kind: .down, x: 0.2, y: 0.2, button: 0, cursor: 3),
            InputEvent(t: 1.5, kind: .move, x: 0.4, y: 0.2, button: 0, cursor: 5),
            InputEvent(t: 2, kind: .up, x: 0.5, y: 0.2, button: 0),
            InputEvent(t: 3, kind: .down, x: 0.6, y: 0.6, button: 1),
            InputEvent(t: 3.1, kind: .up, x: 0.6, y: 0.6, button: 1),
        ]
        let track = CursorTrack(events: events, smoothing: .none)
        #expect(track.cursorID(at: 0.5) == 3)
        #expect(track.cursorID(at: 1.6) == 5)
        #expect(track.cursorID(at: 2.5) == 5)
        #expect(track.clicks.map(\.time) == [1, 3])
        #expect(track.recentClicks(at: 1.2, within: 0.3).map(\.time) == [1])
        #expect(track.recentClicks(at: 1.4, within: 0.3).isEmpty)
        #expect(track.recentClicks(at: 3.05, within: 5).map(\.time) == [1, 3])
        #expect(track.drag(at: 1.5) == CursorTrack.Drag(start: 1, end: 2))
        #expect(track.drag(at: 2.5) == nil)
        let trail = track.trail(at: 1.5, length: 5, spacing: 0.05)
        #expect(trail.count == 5)
        #expect(trail.first!.position.x > trail.last!.position.x)
        #expect(track.trail(at: 1.1, length: 5, spacing: 0.05).count == 2)
        #expect(track.trail(at: 2.5, length: 5, spacing: 0.05).isEmpty)
    }

    @Test func clickEffects() {
        let h = FrameRenderer.highlight(radius: 30, progress: 0.5)!
        #expect(h.radius == 15 && h.opacity == 0.25)
        let start = FrameRenderer.highlight(radius: 30, progress: 0)!
        #expect(start.radius == 0 && start.opacity == 0.5)
        #expect(FrameRenderer.highlight(radius: 30, progress: 1) == nil)
        #expect(FrameRenderer.pulseScale(sinceClick: 0) == 1)
        #expect(abs(FrameRenderer.pulseScale(sinceClick: 0.15) - 1.3) < 1e-12)
        #expect(FrameRenderer.pulseScale(sinceClick: 0.3) == 1)
        #expect(FrameRenderer.pulseScale(sinceClick: -0.1) == 1)
    }
}

struct LayoutTests {
    @Test(arguments: [(2056.0, 1329.0), (641, 361), (1, 1), (1920, 1080)])
    func oddSourcesGiveEvenOutput(w: Double, h: Double) {
        for scale in [1.0, 0.75, 0.5] {
            for enabled in [false, true] {
                let background = BackgroundSettings(enabled: enabled, aspect: .landscape16x9)
                let layout = CanvasLayout.make(
                    sourceSize: CGSize(width: w, height: h), background: background, sizing: .scale(scale))
                #expect(Int(layout.canvasSize.width) % 2 == 0 && Int(layout.canvasSize.height) % 2 == 0)
                #expect(layout.canvasSize.width >= 2 && layout.canvasSize.height >= 2)
            }
        }
    }

    @Test func backgroundOffUsesSourceSize() {
        let layout = CanvasLayout.make(
            sourceSize: CGSize(width: 2056, height: 1329), background: BackgroundSettings(), sizing: .scale(1))
        #expect(layout.canvasSize == CGSize(width: 2056, height: 1330))
        #expect(layout.contentRect == CGRect(origin: .zero, size: layout.canvasSize))
    }

    @Test func paddingAndAspect() {
        let background = BackgroundSettings(enabled: true, aspect: .landscape16x9, padding: 0.06)
        let layout = CanvasLayout.make(
            sourceSize: CGSize(width: 1000, height: 1000), background: background, sizing: .scale(1))
        #expect(layout.canvasSize == CGSize(width: 1778, height: 1000))
        // 6% of the 1000-px shorter side = 60 px inset; square content fits the 880-px inner height.
        #expect(layout.contentRect == CGRect(x: 449, y: 60, width: 880, height: 880))
    }

    @Test func fitSizing() {
        let layout = CanvasLayout.make(
            sourceSize: CGSize(width: 1920, height: 1080), background: BackgroundSettings(),
            sizing: .fit(width: 800, height: 800))
        #expect(layout.canvasSize == CGSize(width: 800, height: 450))
        let noUpscale = CanvasLayout.make(
            sourceSize: CGSize(width: 640, height: 360), background: BackgroundSettings(),
            sizing: .fit(width: 4000, height: 4000))
        #expect(noUpscale.canvasSize == CGSize(width: 640, height: 360))
    }

    @Test func webcamLayout() {
        var settings = WebcamSettings(origin: NormPoint(x: 0.5, y: 0.25), width: 0.2)
        let camera = CGSize(width: 1280, height: 720)
        let canvas = CGSize(width: 1920, height: 1080)
        #expect(
            WebcamLayout.frame(for: settings, cameraSize: camera, canvasSize: canvas)
                == CGRect(x: 960, y: 270, width: 384, height: 216))
        settings.aspect = .square
        #expect(
            WebcamLayout.frame(for: settings, cameraSize: camera, canvasSize: canvas)
                == CGRect(x: 960, y: 270, width: 384, height: 384))
        #expect(
            WebcamLayout.cropRect(for: .square, cameraSize: camera) == CGRect(x: 280, y: 0, width: 720, height: 720))
        settings.cornerRadius = 0.5
        #expect(WebcamLayout.cornerRadius(for: settings, frame: CGRect(x: 0, y: 0, width: 384, height: 216)) == 108)
    }

    @Test func blurRect() {
        let mask = BlurMask(start: 1, end: 2, rect: NormRect(x: 0.9, y: 0.5, w: 0.2, h: 0.25))
        let rect = BlurLayout.sourceRect(for: mask, sourceSize: CGSize(width: 1000, height: 400))
        #expect(rect == CGRect(x: 900, y: 200, width: 100, height: 100))  // clipped to the frame
        #expect(BlurLayout.active([mask], at: 1.5).count == 1)
        #expect(BlurLayout.active([mask], at: 2.5).isEmpty)
    }
}

struct PreviewGeometryTests {
    let geometry = PreviewGeometry(
        layout: CanvasLayout(
            sourceSize: CGSize(width: 1920, height: 1080), canvasSize: CGSize(width: 1920, height: 1080),
            contentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080)))

    @Test func viewCanvasRoundTrip() {
        let view = CGSize(width: 960, height: 800)
        #expect(geometry.videoRect(inViewOfSize: view) == CGRect(x: 0, y: 130, width: 960, height: 540))
        let canvas = geometry.canvasPoint(fromView: CGPoint(x: 480, y: 400), viewSize: view)
        #expect(canvas == CGPoint(x: 960, y: 540))
        #expect(geometry.viewPoint(fromCanvas: canvas, viewSize: view) == CGPoint(x: 480, y: 400))
    }

    @Test func sourceMappingThroughZoom() {
        let center = CGPoint(x: 960, y: 540)
        #expect(geometry.sourcePoint(fromCanvas: center) == NormPoint(x: 0.5, y: 0.5))
        let zoom = ZoomState(scale: 2, pivot: NormPoint(x: 0, y: 0))
        #expect(geometry.sourcePoint(fromCanvas: center, zoom: zoom) == NormPoint(x: 0.25, y: 0.25))
        let rect = NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1)
        let canvasRect = geometry.canvasRect(fromSource: rect, zoom: zoom)
        #expect(abs(canvasRect.minX - 384) < 1e-9 && abs(canvasRect.minY - 216) < 1e-9)
        #expect(abs(canvasRect.width - 768) < 1e-9 && abs(canvasRect.height - 216) < 1e-9)
        let back = geometry.sourceRect(fromCanvas: canvasRect, zoom: zoom)
        #expect(abs(back.x - 0.1) < 1e-12 && abs(back.w - 0.2) < 1e-12 && abs(back.h - 0.1) < 1e-12)
    }

    @Test func withPaddingOffContentIsOutsideZeroToOne() {
        let padded = PreviewGeometry(
            layout: CanvasLayout.make(
                sourceSize: CGSize(width: 1000, height: 1000),
                background: BackgroundSettings(enabled: true, aspect: .landscape16x9), sizing: .scale(1)))
        let p = padded.sourcePoint(fromCanvas: CGPoint(x: 10, y: 10))
        #expect(p.x < 0 && p.y < 0)
    }

    @Test func blurAndWebcamDragCoordinatesRespectLetterboxing() {
        let viewSize = CGSize(width: 960, height: 800)
        let mask = NormRect(x: 0.2, y: 0.3, w: 0.15, h: 0.2)
        let viewRect = geometry.viewRect(
            fromCanvas: geometry.canvasRect(fromSource: mask), viewSize: viewSize)
        let sourceRect = geometry.sourceRect(
            fromCanvas: CGRect(
                origin: geometry.canvasPoint(fromView: viewRect.origin, viewSize: viewSize),
                size: CGSize(width: viewRect.width * 2, height: viewRect.height * 2)))
        #expect(abs(sourceRect.x - mask.x) < 1e-9)
        #expect(abs(sourceRect.y - mask.y) < 1e-9)
        let webcam = WebcamSettings(origin: NormPoint(x: 0.6, y: 0.6), width: 0.2)
        let webcamView = geometry.viewRect(
            fromCanvas: geometry.webcamRect(for: webcam, cameraSize: CGSize(width: 640, height: 480)),
            viewSize: viewSize)
        let video = geometry.videoRect(inViewOfSize: viewSize)
        #expect(abs(webcamView.minX - video.minX - 0.6 * video.width) < 1e-9)
        #expect(abs((webcamView.minX + 0.1 * video.width - video.minX) / video.width - 0.7) < 1e-9)
    }
}

struct AudioMathTests {
    @Test func softLimiter() {
        #expect(AudioSoftLimiter.process(0.5) == 0.5)
        #expect(AudioSoftLimiter.process(-0.8) == -0.8)
        #expect(AudioSoftLimiter.process(4) <= 1 && AudioSoftLimiter.process(1.2) < 1)
        #expect(AudioSoftLimiter.process(-4) >= -1)
        var previous: Float = -2
        for i in 0...400 {
            let y = AudioSoftLimiter.process(Float(i) / 100 - 2)
            #expect(y >= previous)
            previous = y
        }
        // Continuous at the knee.
        #expect(abs(AudioSoftLimiter.process(0.8001) - 0.8001) < 1e-4)
    }

    @Test func levelsPeakResetsOnRead() {
        let levels = AudioLevels()
        levels.publish(.microphone, rms: 0.1, peak: 0.5)
        levels.publish(.microphone, rms: 0.2, peak: 0.3)
        #expect(levels.level(for: .microphone) == AudioLevel(rms: 0.2, peak: 0.5))
        #expect(levels.level(for: .microphone) == AudioLevel(rms: 0.2, peak: 0))
        #expect(levels.level(for: .systemAudio) == .silent)
        #expect(levels.updateCount(for: .microphone) == 2)
    }

    @Test func meterBallistics() {
        var meter = MeterBallistics()
        let first = meter.update(AudioLevel(rms: 0.3, peak: 0.8), now: 0)
        #expect(first.level == 0.6 && first.peakHold == 0.8 && !first.isClipping)
        #expect(meter.update(AudioLevel(rms: 0.1, peak: 0.1), now: 1.4).peakHold == 0.8)  // held
        let decayed = meter.update(AudioLevel(rms: 0.1, peak: 0.1), now: 1.7)
        #expect(decayed.peakHold < 0.8 && decayed.peakHold > 0.3)
        #expect(meter.update(AudioLevel(rms: 0.7, peak: 1), now: 2).isClipping)
    }
}
