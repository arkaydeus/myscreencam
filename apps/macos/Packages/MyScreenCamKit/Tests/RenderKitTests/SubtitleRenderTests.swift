import CoreImage
import CoreText
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

    @Test func aNarrowerCueWrapsSoonerWithoutChangingOthers() {
        let text = "wrap these words onto more lines when the box is narrower"
        var settings = SubtitleSettings(cues: [
            SubtitleCue(start: 0, end: 1, text: text), SubtitleCue(start: 0, end: 1, text: text),
        ])
        settings.cues[0].maxWidth = 0.35
        let narrow = SubtitleLayout.frame(for: settings.cues[0], settings: settings, canvasSize: canvas)
        let normal = SubtitleLayout.frame(for: settings.cues[1], settings: settings, canvasSize: canvas)
        #expect(narrow.width < normal.width)
        #expect(narrow.height > normal.height)
        #expect(abs(narrow.midX - normal.midX) < 0.5)
    }

    @Test func boxWidthMapsBackToTheWidthThatMakesIt() {
        let style = SubtitleStyle(outlineWidth: 0.1)
        let outline = style.outlineWidth * SubtitleLayout.fontSize(style, canvasSize: canvas)
        let width = SubtitleLayout.maxWidth(forBoxWidth: 0.5 * 1920 + 2 * outline, style: style, canvasSize: canvas)
        #expect(abs(width - 0.5) < 1e-9)
        #expect(SubtitleLayout.maxWidth(forBoxWidth: 5, style: style, canvasSize: canvas) == 0.1)
        #expect(SubtitleLayout.maxWidth(forBoxWidth: 5000, style: style, canvasSize: canvas) == 1)
        // A box at that width holds no line wider than it.
        var wide = style
        wide.maxWidth = width
        let measured = SubtitleLayout.measure(
            String(repeating: "fill the line ", count: 12), style: wide, canvasSize: canvas)
        #expect(measured.boxSize.width <= 0.5 * 1920 + 2 * outline + 1)
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

    @Test func shadowRoomDoesNotMoveTheBox() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.subtitles.style = SubtitleStyle(
            size: 0.08, textColor: .white, outlineWidth: 0, background: true,
            backgroundColor: RGBAColor(r: 1, g: 0, b: 0), backgroundOpacity: 1,
            shadow: SubtitleShadow(enabled: true, distance: 0.3, blur: 0.2))
        edit.subtitles.cues = [SubtitleCue(start: 1, end: 2, text: "Hi", position: NormPoint(x: 0.3, y: 0.3))]
        let frame = SubtitleLayout.frame(
            for: edit.subtitles.cues[0], settings: edit.subtitles, canvasSize: CGSize(width: 640, height: 360))
        let shown = try await render(edit, at: 1.5)
        #expect(close(shown.pixel(Int(frame.minX) + 3, Int(frame.midY)), (255, 0, 0), tolerance: 20))
        #expect(close(shown.pixel(Int(frame.minX) - 3, Int(frame.midY)), (128, 128, 128), tolerance: 12))
        #expect(close(shown.pixel(Int(frame.midX), Int(frame.minY) - 3), (128, 128, 128), tolerance: 12))
    }

    @Test func rasterCacheReusesImagesAcrossSnapshots() async throws {
        let cache = SubtitleRasterCache()
        let a = cache.raster(text: "Same", style: SubtitleStyle(), canvasSize: CGSize(width: 640, height: 360))
        let b = cache.raster(text: "Same", style: SubtitleStyle(), canvasSize: CGSize(width: 640, height: 360))
        #expect(a != nil)
        #expect(a?.image === b?.image)
    }

    @Test func compositorHighlightsUppercaseMixedScriptRuns() async throws {
        var edit = try await TestMedia.plainEdit()
        var style = SubtitleStyle(size: 0.12, textColor: .white, outlineWidth: 0, background: false)
        style.highlightWords = true
        style.highlightColor = RGBAColor(r: 0, g: 1, b: 0)
        style.highlightGrow = 0.2
        style.uppercase = true
        edit.subtitles.style = style
        edit.subtitles.cues = [
            SubtitleCue(
                start: 0, end: 2, text: "hi 界 😀",
                words: [
                    SubtitleWord(text: "hi", start: 0.1, end: 0.4),
                    SubtitleWord(text: "界", start: 0.5, end: 0.9),
                    SubtitleWord(text: "😀", start: 1, end: 1.4),
                ])
        ]
        func greenPixels(_ image: Bitmap) -> Int {
            var count = 0
            for y in 0..<360 {
                for x in 0..<640 {
                    let pixel = image.pixel(x, y)
                    if pixel.g > 180 && pixel.r < 100 && pixel.b < 100 { count += 1 }
                }
            }
            return count
        }
        let before = greenPixels(try await render(edit, at: 0.05))
        #expect(greenPixels(try await render(edit, at: 0.2)) > before + 20)
        #expect(greenPixels(try await render(edit, at: 0.6)) > before + 20)
    }

    @Test func compositorDrawsTheWordBoxAndDimsWhatsComing() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.subtitles.style = SubtitleStyle(
            size: 0.12, textColor: .white, outlineWidth: 0, background: false, highlightWords: true,
            highlightColor: RGBAColor(r: 0, g: 1, b: 0), highlightMode: .box, highlightGrow: 0)
        edit.subtitles.cues = [
            SubtitleCue(
                start: 0, end: 2, text: "one two",
                words: [SubtitleWord(text: "one", start: 0.1, end: 0.4), SubtitleWord(text: "two", start: 0.5, end: 1)])
        ]
        func count(_ image: Bitmap, _ match: ((r: Int, g: Int, b: Int)) -> Bool) -> Int {
            var count = 0
            for y in 0..<360 {
                for x in 0..<640 where match(image.pixel(x, y)) { count += 1 }
            }
            return count
        }
        let green = { (p: (r: Int, g: Int, b: Int)) in p.g > 180 && p.r < 100 && p.b < 100 }
        let white = { (p: (r: Int, g: Int, b: Int)) in p.r > 235 && p.g > 235 && p.b > 235 }
        #expect(count(try await render(edit, at: 0.05), green) == 0)
        let lit = try await render(edit, at: 0.2)
        #expect(count(lit, green) > 500)
        let allWhite = count(lit, white)

        edit.subtitles.style.highlightWords = false
        edit.subtitles.style.dimUpcoming = true
        // Nothing spoken yet, then "one" spoken.
        #expect(count(try await render(edit, at: 0.05), white) == 0)
        let half = count(try await render(edit, at: 0.2), white)
        #expect(half > 20 && half < allWhite)
    }
}

struct SubtitleHighlightRenderTests {
    private func bitmap(_ raster: SubtitleRasterCache.Raster) throws -> Bitmap {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext(options: [.workingColorSpace: space])
        return Bitmap(
            cgImage: try #require(
                context.createCGImage(raster.image, from: raster.image.extent, format: .RGBA8, colorSpace: space)))
    }

    @Test func upcomingCJKOutlinesCannotCoverSpokenFill() throws {
        var style = SubtitleStyle(
            fontFamily: "Hiragino Sans", size: 0.2, textColor: .white, outlineWidth: 0.2,
            outlineColor: RGBAColor(r: 1, g: 0, b: 0),
            background: false, dimUpcoming: true, upcomingOpacity: 0)
        let canvas = CGSize(width: 640, height: 360)
        let reference = try bitmap(
            #require(SubtitleRasterCache.render(text: "一一", style: style, canvasSize: canvas, spoken: 1)))
        style.upcomingOpacity = 0.5
        let dimmed = try bitmap(
            #require(SubtitleRasterCache.render(text: "一一", style: style, canvasSize: canvas, spoken: 1)))
        var fillPixels = 0
        var covered = 0
        for y in 0..<reference.height {
            for x in 0..<reference.width where close(reference.pixel(x, y), (255, 255, 255), tolerance: 2) {
                fillPixels += 1
                if !close(dimmed.pixel(x, y), (255, 255, 255), tolerance: 2) { covered += 1 }
            }
        }
        #expect(fillPixels > 100)
        #expect(covered == 0, "Upcoming outlines covered \(covered) spoken fill pixels")
    }

    @Test(arguments: SubtitleHighlightMode.allCases)
    func highlightingAndDimmingShareGrowthOutlineAndShadow(_ mode: SubtitleHighlightMode) throws {
        let canvas = CGSize(width: 640, height: 360)
        let text = "one two three four"
        var style = SubtitleStyle(
            size: 0.12, textColor: .white, outlineWidth: 0.08, outlineColor: RGBAColor(r: 1, g: 0, b: 0),
            background: false, maxWidth: 0.4, highlightWords: true, highlightColor: RGBAColor(r: 0, g: 1, b: 0),
            highlightMode: mode, highlightGrow: 0.3, dimUpcoming: true, upcomingOpacity: 0.5,
            shadow: SubtitleShadow(
                enabled: true, angle: 90, distance: 0.25, blur: 0, color: RGBAColor(r: 0, g: 0, b: 1), opacity: 1))
        let words = SubtitleWords.tokens(in: text).enumerated().map {
            SubtitleWord(
                text: String(decoding: Array(text.utf16)[$0.element], as: UTF16.self),
                start: Double($0.offset), end: Double($0.offset) + 0.8)
        }
        var previous: SubtitleRasterCache.Raster?
        // Include the transition onto a later line: earlier lines stay fully spoken.
        for time in [0.2, 1.2, 2.2] {
            let progress = try #require(SubtitleWords.progress(in: text, words: words, at: time))
            let raster = try #require(
                SubtitleRasterCache.render(
                    text: text, style: style, canvasSize: canvas, grow: style.highlightGrow,
                    highlight: progress.highlight, spoken: progress.spoken))
            let dimmed = try bitmap(raster)
            #expect(raster.measured.textSize.height > 1.5 * raster.measured.fontSize)
            style.upcomingOpacity = 1
            let full = try bitmap(
                #require(
                    SubtitleRasterCache.render(
                        text: text, style: style, canvasSize: canvas, grow: style.highlightGrow,
                        highlight: progress.highlight, spoken: progress.spoken)))
            style.upcomingOpacity = 0.5
            if let previous {
                #expect(raster.measured == previous.measured)
                #expect(raster.image.extent == previous.image.extent)
                #expect(raster.bleed == previous.bleed)
            }
            previous = raster
            var fadedFill = 0
            var fadedOutline = 0
            var fadedShadow = 0
            var opaqueHighlight = 0
            var opaqueFill = 0
            for y in 0..<dimmed.height {
                for x in 0..<dimmed.width {
                    let p = dimmed.pixel(x, y)
                    let alpha = Int(dimmed.bytes[(y * dimmed.width + x) * 4 + 3])
                    let q = full.pixel(x, y)
                    if (120...136).contains(alpha) {
                        if close(q, (255, 255, 255), tolerance: 2), close(p, (128, 128, 128), tolerance: 3) {
                            fadedFill += 1
                        }
                        if close(q, (255, 0, 0), tolerance: 2), close(p, (128, 0, 0), tolerance: 3) {
                            fadedOutline += 1
                        }
                        if close(q, (0, 0, 255), tolerance: 2), close(p, (0, 0, 128), tolerance: 3) {
                            fadedShadow += 1
                        }
                    }
                    if alpha == 255 {
                        if close(p, (0, 255, 0), tolerance: 2) { opaqueHighlight += 1 }
                        if close(p, (255, 255, 255), tolerance: 2) { opaqueFill += 1 }
                    }
                }
            }
            #expect(fadedFill > 50)
            #expect(fadedOutline > 20)
            #expect(fadedShadow > 20)
            #expect(opaqueHighlight > 50)
            if mode == .box || time > 1 { #expect(opaqueFill > 50) }
        }
    }

    @Test(arguments: [0.0, 0.5], [0.0, 0.2])
    func wrappedWordBoxesFitWithGrowthOutlineAndShadow(_ grow: Double, _ outline: Double) throws {
        let canvas = CGSize(width: 1280, height: 720)
        let text = "TESTING a question jumping again."
        let style = SubtitleStyle(
            size: 0.1, textColor: .white, outlineWidth: outline, outlineColor: RGBAColor(r: 1, g: 0, b: 0),
            background: false, maxWidth: 0.5, highlightWords: true,
            highlightColor: RGBAColor(r: 0, g: 1, b: 0), highlightMode: .box, highlightGrow: grow,
            dimUpcoming: true,
            shadow: SubtitleShadow(
                enabled: true, angle: 45, distance: 0.3, blur: 0.1, color: RGBAColor(r: 0, g: 0, b: 1), opacity: 1))
        let measured = SubtitleLayout.measure(text, style: style, canvasSize: canvas, grow: grow)
        let font = SubtitleLayout.font(style, size: measured.fontSize)
        let textRect = CGRect(
            x: (measured.boxSize.width - measured.textSize.width) / 2,
            y: (measured.boxSize.height - measured.textSize.height - measured.growAbove - measured.growBelow) / 2
                + measured.growBelow,
            width: measured.textSize.width, height: measured.textSize.height)
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(SubtitleLayout.attributed(text, font: font)),
            CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
        #expect(CFArrayGetCount(CTFrameGetLines(frame)) >= 2)
        let cue = SubtitleCue(start: 0, end: 10, text: text)
        let settings = SubtitleSettings(style: style)
        let position = SubtitleLayout.frame(for: cue, settings: settings, canvasSize: canvas, measured: measured)
        for token in SubtitleWords.tokens(in: text) {
            let boxes = SubtitleRasterCache.wordBoxes(
                frame, word: token, scale: 1 + grow, font: font, outline: outline * measured.fontSize)
            #expect(!boxes.isEmpty)
            for box in boxes {
                #expect(CGRect(origin: .zero, size: measured.boxSize).contains(box), "\(token): \(box)")
            }
            let raster = try #require(
                SubtitleRasterCache.render(
                    text: text, style: style, canvasSize: canvas, grow: grow, highlight: token,
                    spoken: token.upperBound))
            #expect(raster.measured == measured)
            #expect(
                SubtitleLayout.frame(for: cue, settings: settings, canvasSize: canvas, measured: raster.measured)
                    == position)
            let image = try bitmap(raster)
            // Bitmap rows use the opposite y direction to Core Image's box coordinates.
            let box = CGRect(
                x: raster.bleed, y: Double(image.height) - raster.bleed - measured.boxSize.height,
                width: measured.boxSize.width, height: measured.boxSize.height
            ).insetBy(dx: -1, dy: -1)
            var green = 0
            var shadow = 0
            var escapedInk = 0
            var clipped = 0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let p = image.pixel(x, y)
                    if close(p, (0, 255, 0), tolerance: 20) { green += 1 }
                    if p.b > 40 && p.r < 10 && p.g < 10 { shadow += 1 }
                    if p.r + p.g > 60 && !box.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                        escapedInk += 1
                    }
                    if x == 0 || y == 0 || x == image.width - 1 || y == image.height - 1 {
                        if image.bytes[(y * image.width + x) * 4 + 3] > 1 { clipped += 1 }
                    }
                }
            }
            #expect(green > 100)
            #expect(shadow > 50)
            #expect(escapedInk == 0, "\(token) spills \(escapedInk) pixels outside its subtitle box")
            #expect(clipped == 0, "\(token) reaches the raster edge")
        }
    }

    /// Pixels in the `lit` colour and white in the left and right halves of the "one two" raster.
    private struct Halves {
        var lit = (left: 0, right: 0)
        var white = (left: 0, right: 0)
    }

    private func halves(
        _ highlight: Range<Int>?, style: SubtitleStyle, lit: (Int, Int, Int) = (0, 255, 0), split: Double = 0.5,
        spoken: Int? = nil
    ) throws -> Halves {
        let raster = try #require(
            SubtitleRasterCache.render(
                text: "one two", style: style, canvasSize: CGSize(width: 640, height: 360),
                grow: style.highlightGrow, highlight: highlight, spoken: spoken))
        let extent = raster.image.extent
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, Int(extent.width), Int(extent.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let output = try #require(buffer)
        try RenderContext.render(raster.image, into: output)
        let bitmap = Bitmap(pixelBuffer: output)
        var result = Halves()
        let middle = Int(extent.width * split)
        for y in 0..<Int(extent.height) {
            for x in 0..<Int(extent.width) {
                let p = bitmap.pixel(x, y)
                let left = x < middle
                if close(p, lit, tolerance: 60) {
                    if left { result.lit.left += 1 } else { result.lit.right += 1 }
                } else if close(p, (255, 255, 255), tolerance: 60) {
                    if left { result.white.left += 1 } else { result.white.right += 1 }
                }
            }
        }
        return result
    }

    @Test func onlyTheHighlightedWordTakesTheHighlightColour() throws {
        var style = SubtitleStyle(size: 0.12, textColor: .white, outlineWidth: 0, background: false)
        style.highlightColor = RGBAColor(r: 0, g: 1, b: 0)
        style.highlightGrow = 0

        let none = try halves(nil, style: style)
        #expect(none.lit.left + none.lit.right == 0)
        #expect(none.white.left > 50 && none.white.right > 50)

        // The first word lit: the words after it stay in the text colour.
        let first = try halves(0..<3, style: style)
        #expect(first.lit.left > 50 && first.lit.right == 0)
        #expect(first.white.right > 50)

        let second = try halves(4..<7, style: style)
        #expect(second.lit.right > 50 && second.lit.left == 0)
        #expect(second.white.left > 50)
    }

    @Test func boxModeDrawsABoxBehindTheWordInTheTextColour() throws {
        var style = SubtitleStyle(size: 0.12, textColor: .white, outlineWidth: 0, background: false)
        style.highlightColor = RGBAColor(r: 0, g: 1, b: 0)
        style.highlightGrow = 0
        let text = try halves(0..<3, style: style)
        style.highlightMode = .box
        let box = try halves(0..<3, style: style)
        // The box fills far more than the word's glyphs did, and the word on it stays white.
        #expect(box.lit.left > 3 * text.lit.left)
        // Its padding may reach just past the middle, between the words.
        #expect(box.lit.right < box.lit.left / 10)
        #expect(box.white.left > 50 && box.white.right > 50)

        // A grown word's box grows with it.
        style.highlightGrow = 0.3
        let grown = try halves(0..<3, style: style, split: 0.6)
        #expect(Double(grown.lit.left) > 1.4 * Double(box.lit.left))
    }

    @Test func upcomingWordsAreDimmed() throws {
        // Over an opaque black box, a faded white word is grey.
        var style = SubtitleStyle(
            size: 0.12, textColor: .white, outlineWidth: 0.1, outlineColor: RGBAColor(r: 1, g: 0, b: 0),
            background: true, backgroundColor: .black, backgroundOpacity: 1)
        style.highlightGrow = 0
        let grey = (128, 128, 128)
        let plain = try halves(nil, style: style, lit: grey, spoken: 3)
        #expect(plain.white.left > 50 && plain.white.right > 50)
        style.dimUpcoming = true
        // "one" spoken, "two" not yet.
        let dimmed = try halves(nil, style: style, lit: grey, spoken: 3)
        #expect(abs(dimmed.white.left - plain.white.left) < plain.white.left / 10)
        #expect(dimmed.white.right == 0)
        #expect(dimmed.lit.right > plain.white.right / 2)
        #expect(dimmed.lit.left == 0)
        // Before the first word everything waits; without word timing (no offset) nothing is dimmed.
        #expect(try halves(nil, style: style, lit: grey, spoken: 0).white.left == 0)
        #expect(try halves(nil, style: style, lit: grey).white.right > 50)
    }

    @Test func highlightedWordGrowsInPlace() throws {
        var style = SubtitleStyle(size: 0.12, textColor: .white, outlineWidth: 0, background: false)
        style.highlightColor = RGBAColor(r: 0, g: 1, b: 0)
        style.highlightGrow = 0
        let normal = try halves(0..<3, style: style, split: 0.6)
        style.highlightGrow = 0.3
        // The grown first word reaches a little past the middle; "two" is pushed right to make room.
        let grown = try halves(0..<3, style: style, split: 0.6)
        // Area grows with the square of the scale (1.3² ≈ 1.7).
        #expect(Double(grown.lit.left) > 1.4 * Double(normal.lit.left))
        #expect(grown.lit.right == 0)
        // The other word moves aside at its normal size.
        #expect(abs(Double(grown.white.right) / Double(normal.white.right) - 1) < 0.1)
    }

    @Test func shadowIsDrawnInItsColour() throws {
        var style = SubtitleStyle(size: 0.12, textColor: .white, outlineWidth: 0, background: false)
        let blue = (0, 0, 255)
        let none = try halves(nil, style: style, lit: blue)
        #expect(none.lit.left + none.lit.right == 0)
        style.shadow = SubtitleShadow(
            enabled: true, angle: 90, distance: 0.15, blur: 0, color: RGBAColor(r: 0, g: 0, b: 1), opacity: 1)
        let shadowed = try halves(nil, style: style, lit: blue)
        #expect(shadowed.lit.left > 50 && shadowed.lit.right > 50)
    }

    @Test func uppercaseIsDisplayOnlyAndSizesTheBox() {
        let canvas = CGSize(width: 640, height: 360)
        var settings = SubtitleSettings(cues: [SubtitleCue(start: 0, end: 1, text: "straße")])
        let lower = SubtitleLayout.frame(for: settings.cues[0], settings: settings, canvasSize: canvas)
        settings.style.uppercase = true
        #expect(settings.style.displayText("straße") == "STRASSE")
        let upper = SubtitleLayout.frame(for: settings.cues[0], settings: settings, canvasSize: canvas)
        // The box (and so the preview's drag target) fits the capitals that are drawn.
        #expect(upper.width > lower.width)
        #expect(settings.cues[0].text == "straße")
        // Word matching ignores case, so highlighting still finds the spoken word.
        let words = [SubtitleWord(text: "hello", start: 0, end: 0.5), SubtitleWord(text: "there", start: 0.5, end: 1)]
        #expect(SubtitleWords.highlightedRange(in: "HELLO THERE", words: words, at: 0.6) == 6..<11)
    }

    @Test func highlightingNeverMovesTheBox() throws {
        let canvas = CGSize(width: 640, height: 360)
        let style = SubtitleStyle(highlightWords: true)
        let grow = style.highlightGrow
        let a = try #require(SubtitleRasterCache.render(text: "one two", style: style, canvasSize: canvas, grow: grow))
        let b = try #require(
            SubtitleRasterCache.render(text: "one two", style: style, canvasSize: canvas, grow: grow, highlight: 0..<3))
        #expect(a.measured == b.measured)
    }

    @Test func theBoxHoldsEveryWordGrownAndKeepsOneSize() throws {
        let canvas = CGSize(width: 1280, height: 720)
        let text = "TESTING A QUESTION TESTING."
        let style = SubtitleStyle(
            size: 0.1, textColor: .white, outlineWidth: 0.06, background: true,
            backgroundColor: RGBAColor(r: 0, g: 0, b: 1), backgroundOpacity: 1, maxWidth: 0.55, highlightWords: true,
            highlightColor: RGBAColor(r: 0, g: 1, b: 0), highlightGrow: 0.5)
        let plain = SubtitleLayout.measure(text, style: style, canvasSize: canvas)
        #expect(plain.textSize.height > 1.5 * plain.fontSize)  // Two lines.
        var sizes: Set<String> = []
        for highlight in [nil] + SubtitleWords.tokens(in: text) {
            let raster = try #require(
                SubtitleRasterCache.render(
                    text: text, style: style, canvasSize: canvas, grow: 0.5, highlight: highlight))
            sizes.insert("\(raster.measured.boxSize)")
            #expect(raster.measured.textSize == plain.textSize)  // Same line breaks.
            let extent = raster.image.extent
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                nil, Int(extent.width), Int(extent.height), kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            let output = try #require(buffer)
            try RenderContext.render(raster.image, into: output)
            let bitmap = Bitmap(pixelBuffer: output)
            // The box sits `bleed` in from every side; nothing bright may be drawn outside it.
            let box = CGRect(origin: CGPoint(x: raster.bleed, y: raster.bleed), size: raster.measured.boxSize)
            var outside = 0
            for y in 0..<Int(extent.height) {
                for x in 0..<Int(extent.width)
                where !box.insetBy(dx: -1, dy: -1).contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    let p = bitmap.pixel(x, y)
                    if p.r + p.g + p.b > 90 { outside += 1 }
                }
            }
            #expect(outside == 0, "word \(String(describing: highlight)) spills \(outside) px outside the box")
        }
        #expect(sizes.count == 1)
        #expect(
            plain.boxSize.width
                < SubtitleLayout.measure(text, style: style, canvasSize: canvas, grow: 0.5).boxSize.width)
    }

    @Test func theGrownWordSharesTheBaselineAndGrowsUpwards() throws {
        // No descenders, so each word's lowest ink row is its baseline.
        let style = SubtitleStyle(
            size: 0.1, textColor: .white, outlineWidth: 0, background: false, highlightWords: true,
            highlightColor: RGBAColor(r: 0, g: 1, b: 0), highlightGrow: 0.5)
        let raster = try #require(
            SubtitleRasterCache.render(
                text: "HELLO THERE", style: style, canvasSize: CGSize(width: 1280, height: 720), grow: 0.5,
                highlight: 0..<5))
        let extent = raster.image.extent
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, Int(extent.width), Int(extent.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let output = try #require(buffer)
        try RenderContext.render(raster.image, into: output)
        let bitmap = Bitmap(pixelBuffer: output)
        var green = (top: Int.max, bottom: Int.min)
        var white = (top: Int.max, bottom: Int.min)
        for y in 0..<Int(extent.height) {
            for x in 0..<Int(extent.width) {
                let p = bitmap.pixel(x, y)
                if close(p, (0, 255, 0), tolerance: 40) {
                    green = (min(green.top, y), max(green.bottom, y))
                } else if close(p, (255, 255, 255), tolerance: 40) {
                    white = (min(white.top, y), max(white.bottom, y))
                }
            }
        }
        #expect(abs(green.bottom - white.bottom) <= 2)
        // 50% bigger: about half the cap height again, all of it above.
        let cap = Double(white.bottom - white.top)
        #expect(Double(white.top - green.top) > 0.4 * cap)
    }

    @Test func cuesWithoutWordTimingGetNoRoomForGrowth() {
        let canvas = CGSize(width: 1280, height: 720)
        var settings = SubtitleSettings(style: SubtitleStyle(highlightWords: true, highlightGrow: 0.5))
        let untimed = SubtitleCue(start: 0, end: 1, text: "hello there")
        var timed = untimed
        timed.words = [SubtitleWord(text: "hello", start: 0, end: 0.5)]
        settings.cues = [untimed, timed]
        let a = SubtitleLayout.frame(for: untimed, settings: settings, canvasSize: canvas)
        let b = SubtitleLayout.frame(for: timed, settings: settings, canvasSize: canvas)
        #expect(a.width < b.width && a.height < b.height)
        settings.style.highlightWords = false
        #expect(SubtitleLayout.frame(for: timed, settings: settings, canvasSize: canvas).size == a.size)
    }
}
