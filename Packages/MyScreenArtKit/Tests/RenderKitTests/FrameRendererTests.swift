import AVFoundation
import CoreImage
import Foundation
import ProjectKit
import Testing

@testable import RenderKit

/// Preview and export share one renderer: a preview-sized frame must equal the export frame scaled down.
struct PreviewMatchesExportTests {
    @Test func previewEqualsDownscaledExport() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.blur = [BlurMask(start: 0, end: 4, rect: NormRect(x: 0.62, y: 0.1, w: 0.26, h: 0.35), intensity: 10)]
        edit.zoom.keyframes = [
            ZoomKeyframe(time: 0, scale: 1.5, target: NormPoint(x: 0.3, y: 0.5), hold: 10, instant: true)
        ]
        edit.cursor = CursorSettings(enabled: true, style: .fixed(.arrow), smoothing: .none)
        edit.background = BackgroundSettings(
            enabled: true, aspect: .landscape16x9, padding: 0.05, cornerRadius: 0.03, shadow: 0.4,
            fill: .linearGradient(
                from: RGBAColor(r: 0.2, g: 0.3, b: 0.9), to: RGBAColor(r: 0.9, g: 0.2, b: 0.5), angle: 30))
        let events = [InputEvent(t: 0, kind: .move, x: 0.3, y: 0.45)]
        let project = try await TestMedia.project(edit: edit, events: events)
        let export = try await CompositionBuilder.build(project: project, options: .export())
        let preview = try await CompositionBuilder.build(
            project: project, options: .preview(maxSize: CGSize(width: 320, height: 320)))
        #expect(export.renderSize == CGSize(width: 640, height: 360))
        #expect(preview.renderSize == CGSize(width: 320, height: 180))
        let a = try await FrameGrabber.frame(export, at: 0.5)
        let b = try await FrameGrabber.frame(preview, at: 0.5)

        var total = 0.0
        var worst = 0.0
        var blocks = 0
        for by in stride(from: 0, to: 180, by: 6) {
            for bx in stride(from: 0, to: 320, by: 8) {
                let small = b.mean(x0: bx, y0: by, x1: bx + 8, y1: by + 6)
                let big = a.mean(x0: bx * 2, y0: by * 2, x1: bx * 2 + 16, y1: by * 2 + 12)
                let diff = zip(small, big).map { abs($0 - $1) }.max()!
                total += diff
                worst = max(worst, diff)
                blocks += 1
            }
        }
        #expect(total / Double(blocks) < 3)
        #expect(worst < 30)
    }
}

/// Frame recipes rendered directly (no video files) for effects that need asymmetric inputs.
struct FrameRendererTests {
    private func render(_ edit: EditConfig, webcam: CIImage?) async throws -> Bitmap {
        let project = try await TestMedia.project(edit: edit)
        let layout = CanvasLayout.make(
            sourceSize: CGSize(width: 640, height: 360), background: edit.background, sizing: .scale(1))
        let snapshot = RenderSnapshot(
            edit: edit, timeline: EditTimeline(segments: edit.segments), layout: layout,
            trackIDs: CompositionTrackIDs(screen: 1, webcam: 2), resources: ProjectResources(project: project))
        let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(
            to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let image = FrameRenderer.compose(
            screen: screen, webcam: webcam, snapshot: snapshot, sourceTime: 0, canvasSize: layout.canvasSize)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer)
        let output = try #require(buffer)
        try RenderContext.render(image, into: output)
        return Bitmap(pixelBuffer: output)
    }

    /// 160×90 camera: left half red, right half green (Core Image space, y up).
    private let camera: CIImage = {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(
            to: CGRect(x: 0, y: 0, width: 80, height: 90))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(
            to: CGRect(x: 80, y: 0, width: 80, height: 90))
        return green.composited(over: red)
    }()

    @Test func webcamMirroringAndSquareCrop() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.webcam = WebcamSettings(
            enabled: true, origin: NormPoint(x: 0.5, y: 0.5), width: 0.25, cornerRadius: 0, shadow: false)
        // Rect x 320…480, y 180…270.
        let plain = try await render(edit, webcam: camera)
        #expect(close(plain.pixel(340, 225), (255, 0, 0), tolerance: 20))
        #expect(close(plain.pixel(460, 225), (0, 255, 0), tolerance: 20))
        edit.webcam.mirrored = true
        let mirrored = try await render(edit, webcam: camera)
        #expect(close(mirrored.pixel(340, 225), (0, 255, 0), tolerance: 20))
        #expect(close(mirrored.pixel(460, 225), (255, 0, 0), tolerance: 20))
        // Square crop keeps the centre: the red/green boundary stays in the middle of a 160×160 overlay.
        edit.webcam.aspect = .square
        edit.webcam.mirrored = false
        let square = try await render(edit, webcam: camera)
        #expect(close(square.pixel(330, 300), (255, 0, 0), tolerance: 20))
        #expect(close(square.pixel(470, 300), (0, 255, 0), tolerance: 20))
    }

    @Test func webcamDisabledOrMissingDrawsNothing() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.webcam = WebcamSettings(enabled: false, origin: NormPoint(x: 0.5, y: 0.5), width: 0.25)
        let off = try await render(edit, webcam: camera)
        let offBackground = off.pixel(10, 10)
        #expect(close(off.pixel(400, 225), (offBackground.r, offBackground.g, offBackground.b), tolerance: 2))
        edit.webcam.enabled = true
        let missing = try await render(edit, webcam: nil)
        let missingBackground = missing.pixel(10, 10)
        #expect(
            close(
                missing.pixel(400, 225), (missingBackground.r, missingBackground.g, missingBackground.b), tolerance: 2))
    }
}

extension Bitmap {
    /// Mean R, G, B over a rect.
    func mean(x0: Int, y0: Int, x1: Int, y1: Int) -> [Double] {
        var sum = [0.0, 0.0, 0.0]
        var n = 0.0
        for y in y0..<min(y1, height) {
            for x in x0..<min(x1, width) {
                let p = pixel(x, y)
                sum[0] += Double(p.r)
                sum[1] += Double(p.g)
                sum[2] += Double(p.b)
                n += 1
            }
        }
        return sum.map { $0 / max(n, 1) }
    }
}
