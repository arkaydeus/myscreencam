import AVFoundation
import CoreImage
import Foundation
import ProjectKit
import Testing

@testable import RenderKit

/// End-to-end tests: synthetic package → composition → custom compositor → pixels.
@Suite(.serialized)
struct CompositionIntegrationTests {
    let background = (r: 20, g: 40, b: 40)

    private func build(_ edit: EditConfig, events: [InputEvent] = [], options: RenderOptions = .export())
        async throws -> BuiltComposition
    {
        try await CompositionBuilder.build(
            project: try await TestMedia.project(edit: edit, events: events), options: options)
    }

    @Test func plainRenderMatchesSource() async throws {
        let built = try await build(try await TestMedia.plainEdit())
        #expect(built.renderSize == CGSize(width: 640, height: 360))
        #expect(abs(built.duration.seconds - 4) < 0.01)
        let frame = try await FrameGrabber.frame(built, at: 0.51)
        #expect(close(frame.pixel(20, 300), (TestMedia.backgroundRed(atSecond: 0), 40, 40)))
        #expect(close(frame.pixel(120, 180), (0, 200, 0)))
        let later = try await FrameGrabber.frame(built, at: 2.51)
        #expect(close(later.pixel(20, 300), (TestMedia.backgroundRed(atSecond: 2), 40, 40)))
    }

    @Test func cutsSkipSourceFrames() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.segments = [Segment(start: 0, end: 1), Segment(start: 2, end: 4)]
        let built = try await build(edit)
        #expect(abs(built.duration.seconds - 3) < 0.01)
        let first = try await FrameGrabber.frame(built, at: 0.5)
        #expect(close(first.pixel(20, 300), (TestMedia.backgroundRed(atSecond: 0), 40, 40)))
        // Edited 1.5 s is source 2.5 s: second 1 was cut.
        let second = try await FrameGrabber.frame(built, at: 1.5)
        #expect(close(second.pixel(20, 300), (TestMedia.backgroundRed(atSecond: 2), 40, 40)))
        let third = try await FrameGrabber.frame(built, at: 2.5)
        #expect(close(third.pixel(20, 300), (TestMedia.backgroundRed(atSecond: 3), 40, 40)))
    }

    private func webcamEdit(syncOffset: Double = 0) async throws -> EditConfig {
        var edit = try await TestMedia.plainEdit()
        edit.segments = [Segment(start: 0, end: 1), Segment(start: 2, end: 4)]
        edit.webcam = WebcamSettings(
            enabled: true, origin: NormPoint(x: 0.75, y: 0.05), width: 0.2, aspect: .wide, cornerRadius: 0,
            mirrored: false, shadow: false, syncOffset: syncOffset)
        return edit
    }

    /// Webcam rect: x 480…608, y 18…90 (0.2 × 640 wide, 16:9).
    private func webcamVisible(_ frame: Bitmap) -> Bool { close(frame.pixel(544, 54), (0, 0, 255), tolerance: 30) }

    @Test func webcamRespectsStartOffsetAndCuts() async throws {
        let built = try await build(try await webcamEdit())
        #expect(built.trackIDs.webcam != nil)
        // Webcam covers session 1…3. Edited 0.5 = source 0.5 → none; edited 1.5 = source 2.5 → shown;
        // edited 2.5 = source 3.5 → none.
        #expect(!webcamVisible(try await FrameGrabber.frame(built, at: 0.5)))
        let shown = try await FrameGrabber.frame(built, at: 1.5)
        #expect(webcamVisible(shown))
        #expect(close(shown.pixel(620, 54), (TestMedia.backgroundRed(atSecond: 2), 40, 40)))  // right of the rect
        #expect(close(shown.pixel(600, 100), (TestMedia.backgroundRed(atSecond: 2), 40, 40)))  // below it
        #expect(!webcamVisible(try await FrameGrabber.frame(built, at: 2.5)))
    }

    @Test func webcamSyncOffsetShiftsIt() async throws {
        let built = try await build(try await webcamEdit(syncOffset: 1))
        // Now covers session 2…4: edited 2.5 = source 3.5 → shown; edited 0.5 → none.
        #expect(webcamVisible(try await FrameGrabber.frame(built, at: 2.5)))
        #expect(webcamVisible(try await FrameGrabber.frame(built, at: 1.1)))
        #expect(!webcamVisible(try await FrameGrabber.frame(built, at: 0.5)))
    }

    @Test func webcamCircleHasAntialiasedMaskAndMirror() async throws {
        var edit = try await webcamEdit()
        edit.webcam.aspect = .square
        edit.webcam.cornerRadius = 0.5
        edit.webcam.mirrored = true
        edit.webcam.shadow = true
        let frame = try await FrameGrabber.frame(try await build(edit), at: 1.5)
        // Square 128×128 at x 480, y 18: centre blue, corner shows the screen through the circle mask.
        #expect(close(frame.pixel(544, 82), (0, 0, 255), tolerance: 30))
        let corner = frame.pixel(482, 20)
        #expect(corner.b < 120)
    }

    @Test func blurSmoothsTheRegion() async throws {
        let plain = try await FrameGrabber.frame(try await build(try await TestMedia.plainEdit()), at: 0.5)
        let sharp = plain.stats(x0: 440, y0: 80, x1: 480, y1: 120)
        #expect(sharp.std > 80)

        var edit = try await TestMedia.plainEdit()
        edit.blur = [
            BlurMask(
                start: 0, end: 4, rect: NormRect(x: 400.0 / 640, y: 40.0 / 360, w: 160.0 / 640, h: 120.0 / 360),
                intensity: 12)
        ]
        let blurred = try await FrameGrabber.frame(try await build(edit), at: 0.5)
        let smooth = blurred.stats(x0: 440, y0: 80, x1: 480, y1: 120)
        #expect(smooth.std < 10)
        #expect(abs(smooth.mean - 127) < 30)
        // Outside the mask nothing changes.
        #expect(close(blurred.pixel(120, 180), (0, 200, 0)))
        // Masks only apply during their time range.
        edit.blur[0].start = 3
        let inactive = try await FrameGrabber.frame(try await build(edit), at: 0.5)
        #expect(inactive.stats(x0: 440, y0: 80, x1: 480, y1: 120).std > 80)
    }

    @Test func zoomEnlargesAroundTarget() async throws {
        var edit = try await TestMedia.plainEdit()
        let plain = try await FrameGrabber.frame(try await build(edit), at: 0.5)
        #expect(!close(plain.pixel(150, 180), (0, 200, 0)))

        // 2× about the green square's centre (120, 180): the square grows to x 80…160.
        edit.zoom.keyframes = [
            ZoomKeyframe(time: 0, scale: 2, target: NormPoint(x: 120.0 / 640, y: 0.5), hold: 10, instant: true)
        ]
        let zoomed = try await FrameGrabber.frame(try await build(edit), at: 0.5)
        #expect(close(zoomed.pixel(120, 180), (0, 200, 0)))
        #expect(close(zoomed.pixel(150, 180), (0, 200, 0)))
        #expect(close(zoomed.pixel(120, 215), (0, 200, 0)))
        #expect(!close(zoomed.pixel(170, 180), (0, 200, 0)))
    }

    @Test func backgroundPaddingAndEvenSize() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.background = BackgroundSettings(
            enabled: true, aspect: .source, padding: 0.1, cornerRadius: 0.05, shadow: 0.5,
            fill: .solid(RGBAColor(r: 1, g: 1, b: 0)))
        let built = try await build(edit)
        #expect(built.renderSize == CGSize(width: 640, height: 360))
        #expect(built.layout.contentRect == CGRect(x: 64, y: 36, width: 512, height: 288))
        let frame = try await FrameGrabber.frame(built, at: 0.5)
        #expect(close(frame.pixel(4, 4), (255, 255, 0)))
        #expect(close(frame.pixel(635, 355), (255, 255, 0), tolerance: 20))
        #expect(close(frame.pixel(320, 300), (TestMedia.backgroundRed(atSecond: 0), 40, 40)))
        // Rounded corner: the content's very corner pixel shows the background, not the screen.
        #expect(frame.pixel(64, 36).r > 150)

        edit.background.fill = .linearGradient(
            from: RGBAColor(r: 1, g: 0, b: 0), to: RGBAColor(r: 0, g: 0, b: 1), angle: 0)
        let gradient = try await FrameGrabber.frame(try await build(edit), at: 0.5)
        let left = gradient.pixel(2, 180)
        let right = gradient.pixel(637, 180)
        #expect(left.r > 200 && left.b < 60)
        #expect(right.b > 200 && right.r < 60)
    }

    // MARK: cursor

    private let clickEvents = [
        InputEvent(t: 0, kind: .move, x: 0.5, y: 0.5),
        InputEvent(t: 1, kind: .down, x: 0.5, y: 0.5, button: 0),
        InputEvent(t: 1.05, kind: .up, x: 0.5, y: 0.5, button: 0),
    ]

    private func cursorEdit(pulse: Bool, highlight: Bool) async throws -> EditConfig {
        var edit = try await TestMedia.plainEdit()
        edit.cursor = CursorSettings(
            enabled: true, style: .fixed(.arrow), size: .medium, smoothing: .none, clickPulse: pulse,
            clickHighlight: ClickHighlight(
                enabled: highlight, color: RGBAColor(r: 0, g: 0, b: 1), radius: 40, duration: 1))
        return edit
    }

    @Test func cursorDrawnAtHotspotAndPulsesAboutIt() async throws {
        let built = try await build(try await cursorEdit(pulse: true, highlight: false), events: clickEvents)
        let calm = try await FrameGrabber.frame(built, at: 0.5)
        let pulsed = try await FrameGrabber.frame(built, at: 1.15)
        let window = (x0: 300, y0: 160, x1: 360, y1: 220)
        let a = calm.countDiffering(
            from: background, threshold: 60, x0: window.x0, y0: window.y0, x1: window.x1, y1: window.y1)
        let b = pulsed.countDiffering(
            from: (TestMedia.backgroundRed(atSecond: 1), 40, 40), threshold: 60, x0: window.x0, y0: window.y0,
            x1: window.x1, y1: window.y1)
        #expect(a.count > 80)
        // The arrow's tip (hotspot) sits at (320, 180); the body extends right and down.
        #expect(abs(a.minX - 320) <= 2 && abs(a.minY - 180) <= 2)
        // Pulse 1.3× → ~1.69× the area, anchored at the same tip.
        #expect(Double(b.count) / Double(a.count) > 1.4)
        #expect(abs(b.minX - a.minX) <= 2 && abs(b.minY - a.minY) <= 2)
        // Inside the arrow body it is bright.
        let body = calm.pixel(323, 190)
        #expect(body.r + body.g + body.b > 450)

        let hidden = try await FrameGrabber.frame(
            try await build(try await TestMedia.plainEdit(), events: clickEvents), at: 0.5)
        #expect(close(hidden.pixel(323, 190), (TestMedia.backgroundRed(atSecond: 0), 40, 40)))
    }

    @Test func clickHighlightRadiusAndOpacity() async throws {
        let built = try await build(try await cursorEdit(pulse: false, highlight: true), events: clickEvents)
        let bg1 = (TestMedia.backgroundRed(atSecond: 1), 40, 40)
        // p = 0.5: radius 20 px, opacity 0.25, blue. Left of the tip is free of the arrow.
        let mid = try await FrameGrabber.frame(built, at: 1.5)
        let inside = mid.pixel(308, 180)
        #expect(inside.b > 70)
        #expect(close(mid.pixel(290, 180), bg1))
        // Near the end the circle is larger but fainter.
        let late = try await FrameGrabber.frame(built, at: 1.9)
        let lateInside = late.pixel(290, 180)
        #expect(lateInside.b > 43 && lateInside.b < inside.b)
        // Before the click: nothing.
        let before = try await FrameGrabber.frame(built, at: 0.9)
        #expect(close(before.pixel(308, 180), (TestMedia.backgroundRed(atSecond: 0), 40, 40)))
    }

    @Test(arguments: [CursorStyle.stylised, .system, .fixed(.crosshair), .fixed(.resizeLeftRight), .fixed(.openHand)])
    func everyCursorStyleRenders(style: CursorStyle) async throws {
        var edit = try await cursorEdit(pulse: false, highlight: false)
        edit.cursor.style = style
        let frame = try await FrameGrabber.frame(try await build(edit, events: clickEvents), at: 0.5)
        let drawn = frame.countDiffering(from: background, threshold: 60, x0: 290, y0: 150, x1: 360, y1: 220)
        #expect(drawn.count > 30)
    }

    // MARK: formats

    @Test(arguments: [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
    ])
    func tenBitReaderOutputFormats(format: OSType) async throws {
        let built = try await build(try await TestMedia.plainEdit(), options: .export(scale: 0.5, frameRate: 24))
        let buffers = try await FrameGrabber.readerFrames(built, pixelFormat: format, count: 1)
        #expect(CVPixelBufferGetPixelFormatType(try #require(buffers.first)) == format)
    }

    @Test(arguments: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    func readerOutputFormats(format: OSType) async throws {
        var edit = try await TestMedia.plainEdit()
        edit.background = BackgroundSettings(
            enabled: true, aspect: .square, padding: 0.1, cornerRadius: 0, shadow: 0,
            fill: .solid(RGBAColor(r: 1, g: 1, b: 0)))
        let built = try await build(edit, options: .export(scale: 0.5, frameRate: 24))
        #expect(built.renderSize == CGSize(width: 320, height: 320))
        let buffers = try await FrameGrabber.readerFrames(built, pixelFormat: format, count: 3)
        #expect(buffers.count == 3)
        guard let buffer = buffers.first else { return }
        #expect(CVPixelBufferGetPixelFormatType(buffer) == format)
        #expect(CVPixelBufferGetWidth(buffer) == 320 && CVPixelBufferGetHeight(buffer) == 320)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        let bitmap = Bitmap(pixelBuffer: buffer)
        #expect(close(bitmap.pixel(3, 3), (255, 255, 0), tolerance: 16))
        #expect(close(bitmap.pixel(160, 200), background, tolerance: 16))
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            // BT.709 video-range luma of R'G'B' (20, 40, 40): 16 + 219 × 0.14 ≈ 46.7.
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let y = Int(luma[200 * stride + 160])
            #expect(abs(y - 47) <= 6)
        }
    }

    // MARK: audio

    private func volume(_ mix: AVAudioMix, track: CMPersistentTrackID) -> (Float, Bool)? {
        guard let parameters = mix.inputParameters.first(where: { $0.trackID == track }) else { return nil }
        var start: Float = -1
        var end: Float = -1
        var range = CMTimeRange.zero
        _ = parameters.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
        return (start, parameters.audioTapProcessor != nil)
    }

    @Test func audioMixVolumesAndTaps() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.audio = AudioSettings(system: TrackAudio(gainDB: -6), microphone: TrackAudio(gainDB: -3))
        var built = try await build(edit)
        #expect(built.audioMix.inputParameters.count == 2)
        let system = try #require(volume(built.audioMix, track: CompositionBuilder.TrackID.systemAudio))
        #expect(abs(system.0 - Float(pow(10, -6.0 / 20))) < 1e-4 && !system.1)
        let mic = try #require(volume(built.audioMix, track: CompositionBuilder.TrackID.microphone))
        #expect(abs(mic.0 - Float(pow(10, -3.0 / 20))) < 1e-4 && !mic.1)
        #expect(built.audibleAudioTrackIDs.count == 2)

        edit.audio = AudioSettings(system: TrackAudio(muted: true), microphone: TrackAudio(gainDB: 6))
        built = try await build(edit)
        #expect(volume(built.audioMix, track: CompositionBuilder.TrackID.systemAudio)! == (0, false))
        #expect(volume(built.audioMix, track: CompositionBuilder.TrackID.microphone)! == (1, true))
        #expect(built.audibleAudioTrackIDs == [CompositionBuilder.TrackID.microphone])
        #expect(try await built.audibleAudioTracks().count == 1)

        let composition = built.composition
        #expect(try await composition.loadTracks(withMediaType: .audio).count == 2)
        #expect(try await composition.loadTracks(withMediaType: .video).count == 2)
    }

    @Test func audioTracksAreCutAndOffset() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.segments = [Segment(start: 0, end: 1), Segment(start: 2, end: 4)]
        let built = try await build(edit)
        let composition = built.composition
        let mic = try #require(
            try await composition.loadTrack(withTrackID: CompositionBuilder.TrackID.microphone))
        // mic.m4a covers session 0.5…3.5: edited 0.5…1 (from segment 1) then 1…2.5 (source 2…3.5).
        let ranges = try await mic.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping.target)
        #expect(ranges.count == 2)
        #expect(abs(ranges[0].start.seconds - 0.5) < 0.03 && abs(ranges[0].end.seconds - 1) < 0.03)
        #expect(abs(ranges[1].start.seconds - 1) < 0.03 && abs(ranges[1].end.seconds - 2.5) < 0.05)
    }

    @Test func previewTapsMeterAndGain() async throws {
        var edit = try await TestMedia.plainEdit()
        edit.audio = AudioSettings(system: TrackAudio(gainDB: 0), microphone: TrackAudio(enabled: false))
        let levels = AudioLevels()
        let built = try await CompositionBuilder.build(
            project: try await TestMedia.project(edit: edit), options: .preview(), levels: levels)
        #expect(volume(built.audioMix, track: CompositionBuilder.TrackID.systemAudio)! == (1, true))

        // Pull the mixed audio through the taps the way export does.
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: try await built.composition.loadTracks(withMediaType: .audio),
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
        output.audioMix = built.audioMix
        reader.add(output)
        #expect(reader.startReading())
        var blocks = 0
        while blocks < 20, output.copyNextSampleBuffer() != nil { blocks += 1 }
        reader.cancelReading()
        #expect(levels.updateCount(for: .systemAudio) > 0)
        let level = levels.level(for: .systemAudio)
        // 0.5-amplitude sine: RMS ≈ 0.354, peak ≈ 0.5.
        #expect(abs(level.rms - 0.354) < 0.06)
        #expect(level.peak > 0.4 && level.peak < 0.6)
        #expect(levels.updateCount(for: .microphone) > 0)
        #expect(levels.level(for: .microphone).peak == 0)  // disabled → silent
    }
}

@MainActor
struct ProjectRendererTests {
    private func taps(_ renderer: ProjectRenderer) -> Int {
        renderer.audioMix.inputParameters.filter { $0.audioTapProcessor != nil }.count
    }

    @Test func meteringTapsOnlyWhileRequested() async throws {
        let project = try await TestMedia.project()
        let renderer = try await ProjectRenderer(project: project, options: .preview())
        #expect(!renderer.isMetering)
        #expect(taps(renderer) == 0)
        let snapshot = renderer.built.snapshot
        #expect(renderer.setMetering(true) == [.audioMix])
        #expect(taps(renderer) == 2)
        #expect(renderer.setMetering(true) == [])
        // Audio-only rebuilds keep the render snapshot (and the static layers it has rendered).
        #expect(renderer.built.snapshot === snapshot)

        var edit = project.edit
        edit.audio.microphone.gainDB = 6
        #expect(try await renderer.update(edit: edit) == [.audioMix])
        #expect(renderer.setMetering(false) == [.audioMix])
        #expect(taps(renderer) == 1)  // gain above 0 dB still needs its tap
    }

    @Test func updatesRebuildOnlyWhatChanged() async throws {
        let project = try await TestMedia.project()
        let renderer = try await ProjectRenderer(
            project: project, options: .preview(maxSize: CGSize(width: 320, height: 320)))
        #expect(renderer.layout.canvasSize == CGSize(width: 320, height: 180))
        let composition = renderer.composition

        var edit = project.edit
        edit.zoom.keyframes = [ZoomKeyframe(time: 1)]
        #expect(try await renderer.update(edit: edit) == [.videoComposition])
        #expect(renderer.composition === composition)

        edit.audio.microphone.gainDB = 3
        #expect(try await renderer.update(edit: edit) == [.audioMix])
        #expect(try await renderer.update(edit: edit) == [])

        edit.webcam.syncOffset = 0.5
        #expect(try await renderer.update(edit: edit) == [.composition, .videoComposition, .audioMix])
        #expect(renderer.composition !== composition)

        edit.segments = [Segment(start: 0, end: 2)]
        #expect(try await renderer.update(edit: edit).contains(.composition))
        #expect(abs(renderer.timeline.duration - 2) < 1e-9)

        #expect(renderer.update(options: .preview(maxSize: CGSize(width: 640, height: 640))) == [.videoComposition])
        #expect(renderer.layout.canvasSize == CGSize(width: 640, height: 360))

        edit.zoom.keyframes = [ZoomKeyframe(time: 0.5, scale: 2, target: NormPoint(x: 0, y: 0), hold: 1, instant: true)]
        try await renderer.update(edit: edit)
        #expect(renderer.zoomState(atSource: 1) == ZoomState(scale: 2, pivot: NormPoint(x: 0, y: 0)))
        #expect(renderer.sourceTime(forEdited: 1.5) == 1.5)

        let player = AVPlayer()
        renderer.apply([.composition], to: player)
        #expect(player.currentItem != nil)
        #expect(player.currentItem?.videoComposition != nil)
    }
}
