import CoreImage
import Foundation
import ProjectKit
import Testing

@testable import RenderKit

struct SubtitleLayoutTests {
    let canvas = CGSize(width: 1920, height: 1080)

    @Test func fontScalesWithCanvasHeight() {
        let style = SubtitleStyle(size: 0.05)
        #expect(SubtitleLayout.fontSize(style, canvasSize: canvas) == 54)
        let small = SubtitleLayout.measure("Hello world", style: style, canvasSize: CGSize(width: 960, height: 540))
        let big = SubtitleLayout.measure("Hello world", style: style, canvasSize: canvas)
        #expect(abs(big.boxSize.width / small.boxSize.width - 2) < 0.05)
    }

    @Test func defaultPlacementAnchorsAndMargins() {
        let settings = SubtitleSettings(placement: SubtitlePlacement(anchor: .bottom, margin: 0.1))
        let cue = SubtitleCue(start: 0, end: 1, text: "Bottom")
        let frame = SubtitleLayout.frame(for: cue, settings: settings, canvasSize: canvas)
        #expect(abs(frame.maxY - 1080 * 0.9) < 0.5)
        #expect(abs(frame.midX - 960) < 0.5)
        var top = settings
        top.placement.anchor = .top
        #expect(abs(SubtitleLayout.frame(for: cue, settings: top, canvasSize: canvas).minY - 108) < 0.5)
    }

    @Test func longTextWrapsWithinMaxWidth() {
        let style = SubtitleStyle(maxWidth: 0.5)
        let measured = SubtitleLayout.measure(
            String(repeating: "wrap these words ", count: 8), style: style, canvasSize: canvas)
        #expect(measured.boxSize.width <= 0.5 * 1920 + 1)
        #expect(measured.textSize.height > 2 * SubtitleLayout.fontSize(style, canvasSize: canvas))
    }

    @Test func ownPositionIsTheCentreAndStaysOnCanvas() {
        let settings = SubtitleSettings()
        var cue = SubtitleCue(start: 0, end: 1, text: "Moved", position: NormPoint(x: 0.25, y: 0.3))
        let frame = SubtitleLayout.frame(for: cue, settings: settings, canvasSize: canvas)
        #expect(abs(frame.midX - 480) < 0.5 && abs(frame.midY - 324) < 0.5)
        cue.position = NormPoint(x: 1, y: 1)
        let clamped = SubtitleLayout.frame(for: cue, settings: settings, canvasSize: canvas)
        #expect(clamped.maxX <= 1920 && clamped.maxY <= 1080)
        let round = SubtitleLayout.position(forFrame: frame, canvasSize: canvas)
        #expect(abs(round.x - 0.25) < 1e-9 && abs(round.y - 0.3) < 1e-9)
    }
}

struct SubtitleRenderTests {
    private func render(_ edit: EditConfig, at t: Double) async throws -> Bitmap {
        let project = try await TestMedia.project(edit: edit)
        let layout = CanvasLayout.make(
            sourceSize: CGSize(width: 640, height: 360), background: edit.background, sizing: .scale(1))
        let snapshot = RenderSnapshot(
            edit: edit, timeline: EditTimeline(segments: edit.segments), layout: layout,
            trackIDs: CompositionTrackIDs(screen: 1), resources: ProjectResources(project: project))
        let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(
            to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let image = FrameRenderer.compose(
            screen: screen, webcam: nil, snapshot: snapshot, sourceTime: t, canvasSize: layout.canvasSize)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer)
        let output = try #require(buffer)
        try RenderContext.render(image, into: output)
        return Bitmap(pixelBuffer: output)
    }

    @Test func activeCueIsDrawnInItsBoxOnly() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.subtitles.style = SubtitleStyle(
            size: 0.08, textColor: .white, outlineWidth: 0, background: true,
            backgroundColor: RGBAColor(r: 1, g: 0, b: 0), backgroundOpacity: 1)
        edit.subtitles.cues = [SubtitleCue(start: 1, end: 2, text: "Hi", position: NormPoint(x: 0.3, y: 0.3))]
        let frame = SubtitleLayout.frame(
            for: edit.subtitles.cues[0], settings: edit.subtitles, canvasSize: CGSize(width: 640, height: 360))

        let shown = try await render(edit, at: 1.5)
        // Box corner area is the red background; far away is the untouched grey screen.
        #expect(close(shown.pixel(Int(frame.minX) + 4, Int(frame.midY)), (255, 0, 0), tolerance: 20))
        #expect(close(shown.pixel(600, 340), (128, 128, 128), tolerance: 12))
        // White text somewhere inside the box.
        let white = shown.countDiffering(
            from: (255, 0, 0), threshold: 200, x0: Int(frame.minX), y0: Int(frame.minY), x1: Int(frame.maxX),
            y1: Int(frame.maxY))
        #expect(white.count > 20)

        let hidden = try await render(edit, at: 2.5)
        #expect(close(hidden.pixel(Int(frame.minX) + 4, Int(frame.midY)), (128, 128, 128), tolerance: 12))

        edit.subtitles.enabled = false
        let disabled = try await render(edit, at: 1.5)
        #expect(close(disabled.pixel(Int(frame.minX) + 4, Int(frame.midY)), (128, 128, 128), tolerance: 12))
    }

    @Test func rasterCacheReusesImagesAcrossSnapshots() async throws {
        let cache = SubtitleRasterCache()
        let a = cache.raster(text: "Same", style: SubtitleStyle(), canvasSize: CGSize(width: 640, height: 360))
        let b = cache.raster(text: "Same", style: SubtitleStyle(), canvasSize: CGSize(width: 640, height: 360))
        #expect(a != nil)
        #expect(a?.image === b?.image)
    }
}
