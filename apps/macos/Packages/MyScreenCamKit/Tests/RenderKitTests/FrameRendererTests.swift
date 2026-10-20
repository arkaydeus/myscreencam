import AVFoundation
import CoreImage
import Foundation
import ImageIO
import ProjectKit
import Testing
import UniformTypeIdentifiers

@testable import RenderKit

/// Preview and export share one renderer: a preview-sized frame must equal the export frame scaled down.
struct PreviewMatchesExportTests {
    @Test(
        arguments: [nil, WebcamBackground.Effect.blur, .remove],
        [nil, NormRect(x: 0.5, y: 0, w: 0.5, h: 1)])
    func previewEqualsDownscaledExport(webcamEffect: WebcamBackground.Effect?, crop: NormRect?) async throws {
        var edit = try await TestMedia.plainEdit()
        edit.crop = crop
        if let webcamEffect {
            edit.webcam.enabled = true
            edit.webcam.background = WebcamBackground(effect: webcamEffect)
        }
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
        let a = try await FrameGrabber.frame(export, at: 1.5)
        let b = try await FrameGrabber.frame(preview, at: 1.5)

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
    private func render(
        _ edit: EditConfig, webcam: CIImage?, personMask: CIImage? = nil,
        project suppliedProject: RenderProject? = nil, scale: Double = 1, screen suppliedScreen: CIImage? = nil
    ) async throws -> Bitmap {
        let project: RenderProject
        if let suppliedProject { project = suppliedProject } else { project = try await TestMedia.project(edit: edit) }
        let layout = CanvasLayout.make(
            sourceSize: CGSize(width: 640, height: 360), crop: edit.crop, background: edit.background,
            sizing: .scale(scale))
        let resources = ProjectResources(project: project)
        if let webcam, let personMask {
            // Seed a deterministic segmentation result, then use the real buffer cache, scaling, placement and blend.
            #expect(webcam.pixelBuffer != nil)
            _ = resources.personMasks.mask(for: webcam) { _ in personMask }
        }
        let snapshot = RenderSnapshot(
            edit: edit, timeline: EditTimeline(segments: edit.segments), layout: layout,
            trackIDs: CompositionTrackIDs(screen: 1, webcam: 2), resources: resources)
        let screen =
            suppliedScreen
            ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(
                to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let image = FrameRenderer.compose(
            screen: screen, webcam: webcam, snapshot: snapshot, sourceTime: 0, canvasSize: layout.canvasSize)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, Int(layout.canvasSize.width), Int(layout.canvasSize.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
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

    private func bufferedCamera() throws -> CIImage {
        CIImage(
            cvPixelBuffer: try TestMedia.makeBGRA(width: 160, height: 90) { x, _ in
                x < 80 ? (255, 0, 0) : (0, 255, 0)
            })
    }

    /// A low-resolution asymmetric foreground, like Vision's mask. Its nonzero origin exercises normalisation.
    private func foregroundMask(x: Double = 2, value: Double = 1) -> CIImage {
        let base = CIImage(color: .black).cropped(to: CGRect(x: 7, y: 3, width: 16, height: 9))
        let person = CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(
            to: CGRect(x: 7 + x, y: 5, width: 4, height: 5))
        return person.composited(over: base)
    }

    private func webcamEdit() async throws -> EditConfig {
        var edit = try await TestMedia.plainEdit()
        edit.webcam = WebcamSettings(
            enabled: true, origin: NormPoint(x: 0.5, y: 0.5), width: 0.25, cornerRadius: 0, shadow: false,
            background: WebcamBackground(effect: .remove, edgeSoftness: 0, removalStyle: .framed))
        return edit
    }

    private func saveImage(_ image: CIImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cg = try #require(RenderContext.shared.createCGImage(image, from: image.extent))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func cropKeepsOnlyTheChosenAreaAndZoomsInsideIt() async throws {
        // 640×360 screen in quarters (Core Image space, y up): top-left red, top-right green, bottom-left blue,
        // bottom-right white.
        func quarter(_ x: Double, _ y: Double, _ color: CIColor) -> CIImage {
            CIImage(color: color).cropped(to: CGRect(x: x, y: y, width: 320, height: 180))
        }
        let screen = quarter(0, 180, CIColor(red: 1, green: 0, blue: 0))
            .composited(over: quarter(320, 180, CIColor(red: 0, green: 1, blue: 0)))
            .composited(over: quarter(0, 0, CIColor(red: 0, green: 0, blue: 1)))
            .composited(over: quarter(320, 0, CIColor(red: 1, green: 1, blue: 1)))
        var edit = try await TestMedia.plainEdit()
        edit.crop = NormRect(x: 0.5, y: 0, w: 0.5, h: 1)  // the right half
        let cropped = try await render(edit, webcam: nil, screen: screen)
        #expect(cropped.width == 320 && cropped.height == 360)
        #expect(close(cropped.pixel(10, 10), (0, 255, 0)))
        #expect(close(cropped.pixel(310, 350), (255, 255, 255)))

        // A 2× zoom on the crop's bottom-right corner shows only the white quarter.
        edit.zoom.keyframes = [
            ZoomKeyframe(time: 0, scale: 2, target: NormPoint(x: 1, y: 1), hold: 10, instant: true)
        ]
        let zoomed = try await render(edit, webcam: nil, screen: screen)
        #expect(close(zoomed.pixel(10, 10), (255, 255, 255)))
        #expect(close(zoomed.pixel(310, 350), (255, 255, 255)))
    }

    @Test(arguments: [OutputAspect.square, .landscape16x9, .portrait9x16])
    func croppedContentFitsBackgroundWithPadding(aspect: OutputAspect) async throws {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(
            to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(
            to: CGRect(x: 320, y: 0, width: 320, height: 360))
        var edit = try await TestMedia.plainEdit()
        edit.crop = NormRect(x: 0.5, y: 0, w: 0.5, h: 1)
        edit.background = BackgroundSettings(
            enabled: true, aspect: aspect, padding: 0.1, cornerRadius: 0, shadow: 0,
            fill: .solid(RGBAColor(r: 0, g: 0, b: 1)))
        let layout = CanvasLayout.make(
            sourceSize: CGSize(width: 640, height: 360), crop: edit.crop, background: edit.background, sizing: .scale(1)
        )
        let image = try await render(edit, webcam: nil, screen: green.composited(over: red))
        #expect(image.width == Int(layout.canvasSize.width) && image.height == Int(layout.canvasSize.height))
        #expect(
            layout.contentRect.width < layout.canvasSize.width && layout.contentRect.height < layout.canvasSize.height)
        #expect(abs(layout.contentRect.width / layout.contentRect.height - 320.0 / 360) < 0.01)
        #expect(close(image.pixel(2, 2), (0, 0, 255)))
        for x in [layout.contentRect.minX + 3, layout.contentRect.midX, layout.contentRect.maxX - 3] {
            for y in [layout.contentRect.minY + 3, layout.contentRect.midY, layout.contentRect.maxY - 3] {
                #expect(close(image.pixel(Int(x), Int(y)), (0, 255, 0)))
            }
        }
    }

    @Test func framedGradientAndRasterizedImageFillStayAtTheOverlayOrigin() async throws {
        let camera = try bufferedCamera()
        let emptyMask = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9))
        var edit = try await webcamEdit()
        edit.webcam.background.fill = .linearGradient(
            from: RGBAColor(r: 1, g: 0, b: 0), to: RGBAColor(r: 0, g: 0, b: 1), angle: 0)
        let horizontal = try await render(edit, webcam: camera, personMask: emptyMask)
        #expect(horizontal.pixel(330, 225).r > 220 && horizontal.pixel(330, 225).b < 40)
        #expect(horizontal.pixel(470, 225).b > 220 && horizontal.pixel(470, 225).r < 40)
        edit.webcam.background.fill = .linearGradient(
            from: RGBAColor(r: 1, g: 0, b: 0), to: RGBAColor(r: 0, g: 0, b: 1), angle: 90)
        let vertical = try await render(edit, webcam: camera, personMask: emptyMask)
        #expect(vertical.pixel(400, 185).r > 220)
        #expect(vertical.pixel(400, 265).b > 220)

        let root = FileManager.default.temporaryDirectory.appending(path: "webcam-fill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try RecordingPackage.create(in: root)
        let path = "backgrounds/fill.png"
        // Four colours detect both translation and vertical orientation after the fill is rasterised.
        let top = self.camera.cropped(to: CGRect(x: 0, y: 45, width: 160, height: 45))
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(
            to: CGRect(x: 0, y: 0, width: 80, height: 45))
        let yellow = CIImage(color: CIColor(red: 1, green: 1, blue: 0)).cropped(
            to: CGRect(x: 80, y: 0, width: 80, height: 45))
        try saveImage(top.composited(over: bottom.composited(over: yellow)), to: package.url(path))
        edit.webcam.cornerRadius = 0.3
        edit.webcam.background.fill = .image(path: path)
        let meta = try await TestMedia.project().meta
        let project = RenderProject(package: package, meta: meta, edit: edit, events: [], cursorIndex: CursorIndex())
        let filled = try await render(edit, webcam: camera, personMask: emptyMask, project: project)
        #expect(close(filled.pixel(350, 205), (255, 0, 0)))
        #expect(close(filled.pixel(450, 205), (0, 255, 0)))
        #expect(close(filled.pixel(350, 245), (0, 0, 255)))
        #expect(close(filled.pixel(450, 245), (255, 255, 0)))
        #expect(close(filled.pixel(321, 181), (filled.pixel(10, 10).r, filled.pixel(10, 10).g, filled.pixel(10, 10).b)))

        // A preset saved in A applies in B as a see-through frame, rather than a missing-image black rectangle.
        let store = PresetStore(directory: root.appending(path: "presets"))
        try await store.save(EditPreset(name: "Webcam image", from: edit))
        let loaded = try #require(try await store.list().first)
        let target = try RecordingPackage.create(in: root)
        let applied = loaded.applied(to: edit)
        let targetProject = RenderProject(
            package: target, meta: meta, edit: applied, events: [], cursorIndex: CursorIndex())
        let portable = try await render(applied, webcam: camera, personMask: emptyMask, project: targetProject)
        #expect(applied.webcam.background.fill == nil)
        #expect(
            close(
                portable.pixel(350, 205),
                (portable.pixel(10, 10).r, portable.pixel(10, 10).g, portable.pixel(10, 10).b), tolerance: 2))
    }

    @Test func foregroundSurvivesBlurAndRemovalWithMirroredCroppedMaskAlignment() async throws {
        let camera = try bufferedCamera()
        let mask = foregroundMask()
        var edit = try await webcamEdit()
        edit.webcam.background.fill = .solid(RGBAColor(r: 0, g: 0, b: 1))
        let framed = try await render(edit, webcam: camera, personMask: mask)
        #expect(close(framed.pixel(360, 225), (255, 0, 0)))
        #expect(close(framed.pixel(440, 225), (0, 0, 255)))
        #expect(close(framed.pixel(360, 185), (0, 0, 255)))

        edit.webcam.background.effect = .blur
        edit.webcam.background.blurAmount = 1
        let blurred = try await render(edit, webcam: camera, personMask: mask)
        #expect(close(blurred.pixel(360, 225), (255, 0, 0)))
        #expect(blurred.pixel(398, 225).g > 40)

        edit.webcam.background.effect = .remove
        edit.webcam.aspect = .square
        let square = try await render(edit, webcam: camera, personMask: mask)
        #expect(close(square.pixel(340, 260), (255, 0, 0)))
        #expect(close(square.pixel(460, 260), (0, 0, 255)))
        edit.webcam.mirrored = true
        let mirrored = try await render(edit, webcam: camera, personMask: mask)
        #expect(close(mirrored.pixel(460, 260), (255, 0, 0)))
        #expect(close(mirrored.pixel(340, 260), (0, 0, 255)))
    }

    @Test func maskChokeAndFeatherKeepSoftEdgesInsideTheForeground() async throws {
        let camera = try bufferedCamera()
        var edit = try await webcamEdit()
        edit.webcam.background.fill = .solid(RGBAColor(r: 0, g: 0, b: 1))
        let rejected = try await render(edit, webcam: camera, personMask: foregroundMask(value: 0.4))
        #expect(close(rejected.pixel(360, 225), (0, 0, 255)))
        let partial = try await render(edit, webcam: camera, personMask: foregroundMask(value: 0.75))
        let mixed = partial.pixel(360, 225)
        #expect(mixed.r > 90 && mixed.r < 210)
        #expect(mixed.b > 90 && mixed.b < 210)

        let sharp = try await render(edit, webcam: camera, personMask: foregroundMask())
        edit.webcam.background.edgeSoftness = 1
        let feathered = try await render(edit, webcam: camera, personMask: foregroundMask())
        #expect(close(feathered.pixel(360, 225), (255, 0, 0)))
        #expect(feathered.pixel(343, 225).r < sharp.pixel(343, 225).r - 15)
        #expect(feathered.pixel(343, 225).b > sharp.pixel(343, 225).b + 15)
        #expect(close(feathered.pixel(334, 225), (0, 0, 255)))
    }

    @Test(arguments: [WebcamBackground.RemovalStyle.cutout, .framed])
    func seeThroughShadowFollowsThePerson(style: WebcamBackground.RemovalStyle) async throws {
        let camera = try bufferedCamera()
        var edit = try await webcamEdit()
        edit.webcam.background.removalStyle = style
        let noShadow = try await render(edit, webcam: camera, personMask: foregroundMask())
        edit.webcam.shadow = true
        let left = try await render(edit, webcam: camera, personMask: foregroundMask())
        let right = try await render(edit, webcam: camera, personMask: foregroundMask(x: 10))
        // Below the left foreground, well inside the overlay rectangle: only a person shadow reaches here.
        #expect(left.pixel(360, 251).r < noShadow.pixel(360, 251).r - 3)
        #expect(
            close(
                right.pixel(360, 251),
                (noShadow.pixel(360, 251).r, noShadow.pixel(360, 251).g, noShadow.pixel(360, 251).b), tolerance: 2))
        #expect(right.pixel(440, 251).r < left.pixel(440, 251).r - 3)
        #expect(
            close(
                left.pixel(475, 275),
                (noShadow.pixel(475, 275).r, noShadow.pixel(475, 275).g, noShadow.pixel(475, 275).b), tolerance: 2))
    }

    @Test(arguments: [WebcamBackground.Effect.blur, .remove])
    func webcamEffectsPreviewMatchesDownscaledExport(effect: WebcamBackground.Effect) async throws {
        let camera = try bufferedCamera()
        var edit = try await webcamEdit()
        edit.webcam.width = 0.4
        edit.webcam.aspect = .square
        edit.webcam.mirrored = true
        edit.webcam.shadow = true
        edit.webcam.background.effect = effect
        edit.webcam.background.edgeSoftness = 0.6
        let full = try await render(edit, webcam: camera, personMask: foregroundMask())
        let preview = try await render(edit, webcam: camera, personMask: foregroundMask(), scale: 0.5)
        var total = 0.0
        var worst = 0.0
        var blocks = 0
        for y in stride(from: 0, to: 180, by: 6) {
            for x in stride(from: 0, to: 320, by: 8) {
                let small = preview.mean(x0: x, y0: y, x1: x + 8, y1: y + 6)
                let big = full.mean(x0: x * 2, y0: y * 2, x1: x * 2 + 16, y1: y * 2 + 12)
                let diff = zip(small, big).map { abs($0 - $1) }.max()!
                total += diff
                worst = max(worst, diff)
                blocks += 1
            }
        }
        #expect(total / Double(blocks) < 1)
        #expect(worst < 15)
        // This comparison must include the retained foreground, not just an empty segmentation result.
        #expect(preview.pixel(265, 145).r > 200)
    }

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

    /// The test camera has no person in it, so person segmentation finds only background.
    @Test func webcamBackgroundWithoutAPerson() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.webcam = WebcamSettings(
            enabled: true, origin: NormPoint(x: 0.5, y: 0.5), width: 0.25, cornerRadius: 0, shadow: false)
        // Rect x 320…480, y 180…270; the red/green boundary is at x 400.
        edit.webcam.background = WebcamBackground(effect: .blur, blurAmount: 1, edgeSoftness: 0)
        let blurred = try await render(edit, webcam: camera)
        let edge = blurred.pixel(398, 225)
        #expect(edge.r > 40 && edge.g > 40)
        #expect(close(blurred.pixel(330, 225), (255, 0, 0), tolerance: 20))

        edit.webcam.background = WebcamBackground(
            effect: .remove, removalStyle: .framed, fill: .solid(RGBAColor(r: 0, g: 0, b: 1)))
        let filled = try await render(edit, webcam: camera)
        #expect(close(filled.pixel(340, 225), (0, 0, 255), tolerance: 20))
        #expect(close(filled.pixel(460, 225), (0, 0, 255), tolerance: 20))

        edit.webcam.background.removalStyle = .cutout
        let cutout = try await render(edit, webcam: camera)
        let screen = cutout.pixel(10, 10)
        #expect(close(cutout.pixel(340, 225), (screen.r, screen.g, screen.b), tolerance: 4))
        #expect(close(cutout.pixel(460, 225), (screen.r, screen.g, screen.b), tolerance: 4))
    }

    @Test func personMaskCoversTheCameraFrame() throws {
        let frame = camera.transformed(by: CGAffineTransform(translationX: 7, y: 3))
        let mask = try #require(FrameRenderer.personMask(for: frame))
        #expect(abs(mask.extent.minX - 7) < 0.01)
        #expect(abs(mask.extent.minY - 3) < 0.01)
        #expect(abs(mask.extent.width - 160) < 0.01)
        #expect(abs(mask.extent.height - 90) < 0.01)
    }

    @Test func visionMaskFromDecodedBufferIsRasterizedBeforeScalingAndBlending() async throws {
        let camera = try bufferedCamera()
        let cache = PersonMaskCache()
        let mask = try #require(FrameRenderer.personMask(for: camera, cache: cache))
        #expect(mask.extent == camera.extent)
        // A hit must retain the actual low-resolution, rasterised Vision output, not run the producer again.
        let cached = try #require(
            cache.mask(for: camera) { _ in
                Issue.record("Vision mask should already be cached")
                return nil
            })
        #expect(cached.extent.width > 0 && cached.extent.height > 0)
        let edit = try await webcamEdit()
        let removed = try await render(edit, webcam: camera, personMask: cached)
        let base = removed.pixel(10, 10)
        #expect(close(removed.pixel(360, 225), (base.r, base.g, base.b), tolerance: 4))
        #expect(close(removed.pixel(440, 225), (base.r, base.g, base.b), tolerance: 4))
    }

    @Test func personMasksAreMadeOncePerCameraFrame() throws {
        func frame() throws -> CIImage {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                nil, 64, 36, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &buffer)
            return CIImage(cvPixelBuffer: try #require(buffer))
        }
        let cache = PersonMaskCache()
        var made = 0
        let make = { (image: CIImage) -> CIImage? in
            made += 1
            return CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: image.extent)
        }
        let a = try frame()
        let b = try frame()
        _ = cache.mask(for: a, make: make)
        _ = cache.mask(for: a, make: make)
        #expect(made == 1)
        _ = cache.mask(for: b, make: make)
        #expect(made == 2)
        // Images that aren't a decoded frame aren't cached.
        _ = cache.mask(for: camera, make: make)
        _ = cache.mask(for: camera, make: make)
        #expect(made == 4)
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

/// Static layers (shadows, backgrounds) are rendered once into textures; composited, they must look the same as
/// the live filter chain.
struct RasterizeTests {
    private func render(_ image: CIImage) throws -> Bitmap {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 200, 120, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer)
        let output = try #require(buffer)
        try RenderContext.render(image, into: output)
        return Bitmap(pixelBuffer: output)
    }

    @Test func rasterizedShadowMatchesLiveFilters() throws {
        let shape = CIHelpers.roundedRect(
            CGRect(x: 50.3, y: 30.6, width: 90, height: 50), radius: 12, color: CIColor(red: 1, green: 1, blue: 1))
        let shadow = CIHelpers.shadow(of: shape, sigma: 8, offsetDown: 5, opacity: 0.6)
        let rasterized = RenderContext.rasterize(shadow)
        #expect(rasterized.extent == shadow.extent.integral)
        let base = CIImage(color: CIColor(red: 0.9, green: 0.6, blue: 0.2)).cropped(
            to: CGRect(x: 0, y: 0, width: 200, height: 120))
        let live = try render(shadow.composited(over: base))
        let cached = try render(rasterized.composited(over: base))
        var worst = 0
        for y in stride(from: 0, to: 120, by: 3) {
            for x in stride(from: 0, to: 200, by: 3) {
                let a = live.pixel(x, y)
                let b = cached.pixel(x, y)
                worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
        }
        #expect(worst <= 2)
        // The shadow really is there (darker under the shape than in the corner).
        #expect(live.pixel(100, 60).r < live.pixel(2, 2).r - 40)
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
