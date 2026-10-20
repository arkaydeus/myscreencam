import Foundation
import Testing

@testable import ProjectKit

struct EditNormalizationTests {
    /// A config with every kind of problem.
    func messy() -> EditConfig {
        var config = EditConfig(segments: [
            Segment(start: 8, end: 12),  // runs past the end
            Segment(start: 1, end: 3),
            Segment(start: 2, end: 4),  // overlaps the previous
            Segment(start: 5, end: 5),  // empty
            Segment(start: 4, end: 4.5),  // touches 1–4 after merging: stays separate
            Segment(start: -2, end: -1),  // before the start
            Segment(start: .nan, end: 0.5),
        ])
        config.zoom.defaults = ZoomTiming(scale: 9, easeIn: -1, hold: .nan, easeOut: 0.3)
        config.zoom.keyframes = [
            ZoomKeyframe(time: 7, scale: 0.5, target: NormPoint(x: 2, y: -1)),
            ZoomKeyframe(time: -3, scale: 5, easeIn: -0.2, hold: .infinity),
            ZoomKeyframe(time: 99, scale: .nan),
        ]
        config.webcam.width = 0.9
        config.webcam.origin = NormPoint(x: -0.5, y: 1.5)
        config.webcam.cornerRadius = 2
        config.webcam.syncOffset = -12
        config.webcam.background.blurAmount = 3
        config.webcam.background.edgeSoftness = .nan
        config.cursor.idleDelay = -3
        config.cursor.clickHighlight.radius = 500
        config.cursor.clickHighlight.duration = 0
        config.cursor.dragTrail.length = 40
        config.cursor.dragTrail.opacity = 3
        config.blur = [
            BlurMask(start: 2, end: 1),  // inverted → dropped
            BlurMask(start: 9, end: 20, rect: NormRect(x: 0.9, y: -0.1, w: 0.5, h: 2), intensity: 200),
            BlurMask(start: 15, end: 20),  // entirely past the end → dropped
            BlurMask(start: 1, end: 2, intensity: 0),
        ]
        config.audio.system.gainDB = 40
        config.audio.microphone.gainDB = -99
        config.background.padding = 1
        config.background.cornerRadius = -1
        config.background.shadow = 2
        return config
    }

    @Test func segmentsAreClampedSortedMergedAndCleaned() {
        let n = messy().normalized(duration: 10)
        #expect(n.segments.map(\.start) == [0, 1, 4, 8])
        #expect(n.segments.map(\.end) == [0.5, 4, 4.5, 10])
    }

    @Test func overlappingSegmentsMerge() {
        let config = EditConfig(segments: [
            Segment(start: 0, end: 3), Segment(start: 2, end: 5), Segment(start: 4, end: 4.5),
            Segment(start: 5, end: 6),
        ])
        let n = config.normalized(duration: 10)
        #expect(n.segments.map(\.start) == [0, 5])
        #expect(n.segments.map(\.end) == [5, 6])
        #expect(n.segments[0].id == config.segments[0].id)
    }

    @Test func fallsBackToFullRange() {
        let id = UUID()
        let config = EditConfig(segments: [Segment(id: id, start: 20, end: 30)])
        let n = config.normalized(duration: 10)
        #expect(n.segments.count == 1)
        #expect(n.segments[0].start == 0 && n.segments[0].end == 10)
        #expect(n.segments[0].id == id)

        let empty = EditConfig(segments: []).normalized(duration: 4)
        #expect(empty.segments.count == 1 && empty.segments[0].end == 4)
    }

    @Test func valuesAreClampedToDocumentedRanges() {
        let n = messy().normalized(duration: 10)
        #expect(n.zoom.defaults == ZoomTiming(scale: 4, easeIn: 0, hold: ZoomTiming().hold, easeOut: 0.3))
        #expect(n.zoom.keyframes.map(\.time) == [0, 7, 10])
        #expect(n.zoom.keyframes.map(\.scale) == [4, 1, 4])
        #expect(n.zoom.keyframes[1].target == NormPoint(x: 1, y: 0))
        #expect(n.zoom.keyframes[0].easeIn == 0)
        #expect(n.zoom.keyframes[0].hold.isFinite)

        #expect(n.webcam.width == 0.5)
        #expect(n.webcam.origin == NormPoint(x: 0, y: 1))
        #expect(n.webcam.cornerRadius == 0.5)
        #expect(n.webcam.syncOffset == -5)
        #expect(n.webcam.background.blurAmount == 1)
        #expect(n.webcam.background.edgeSoftness == WebcamBackground().edgeSoftness)

        #expect(n.cursor.idleDelay == 0)
        #expect(n.cursor.clickHighlight.radius == 100)
        #expect(n.cursor.clickHighlight.duration == 0.1)
        #expect(n.cursor.dragTrail.length == 15)
        #expect(n.cursor.dragTrail.opacity == 1)

        #expect(n.blur.count == 2)
        #expect(n.blur[0].start == 9 && n.blur[0].end == 10)
        #expect(n.blur[0].intensity == 50)
        #expect(n.blur[0].rect.x == 0.9 && n.blur[0].rect.y == 0)
        #expect(abs(n.blur[0].rect.w - 0.1) < 1e-12 && n.blur[0].rect.h == 1)
        #expect(n.blur[1].intensity == 1)

        #expect(n.audio.system.gainDB == 10)
        #expect(n.audio.microphone.gainDB == -20)
        #expect(n.background.padding == 0.3)
        #expect(n.background.cornerRadius == 0)
        #expect(n.background.shadow == 1)
    }

    @Test func idempotent() {
        let once = messy().normalized(duration: 10)
        #expect(once.normalized(duration: 10) == once)

        let degenerate = EditConfig(segments: [Segment(start: 0, end: 0)]).normalized(duration: 0)
        #expect(degenerate.normalized(duration: 0) == degenerate)
        #expect(EditConfig(segments: []).normalized(duration: .nan).segments.count == 1)
    }

    @Test func cropIsKeptInsideTheFrame() {
        var config = EditConfig(segments: [Segment(start: 0, end: 10)])
        config.crop = NormRect(x: 0.9, y: -0.2, w: 0.5, h: 0.01)
        let crop = config.normalized(duration: 10).crop
        #expect(crop == NormRect(x: 0.5, y: 0, w: 0.5, h: EditLimits.cropMinimumSize))
        config.crop = NormRect(x: 0, y: 0, w: 1.2, h: 1)
        #expect(config.normalized(duration: 10).crop == nil)  // the whole frame
        config.crop = NormRect(x: .nan, y: 0, w: 0.5, h: 0.5)
        #expect(config.normalized(duration: 10).crop == nil)
        config.crop = NormRect(x: 0.1, y: 0.2, w: 0.5, h: 0.6)
        #expect(config.normalized(duration: 10).crop == config.crop)
    }

    @Test func editWrittenBeforeCroppingDecodesUncropped() throws {
        var config = EditConfig.initial(for: Fixtures.meta(duration: 10))
        let data = try JSONEncoder().encode(config)
        #expect(!String(decoding: data, as: UTF8.self).contains(#""crop""#))
        #expect(try JSONDecoder().decode(EditConfig.self, from: data).crop == nil)
        config.crop = NormRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4)
        #expect(try JSONDecoder().decode(EditConfig.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func validConfigIsUnchanged() {
        var config = EditConfig.initial(for: Fixtures.meta(duration: 10))
        config.zoom.keyframes = [ZoomKeyframe(time: 1), ZoomKeyframe(time: 5, scale: 2)]
        config.blur = [BlurMask(start: 1, end: 3)]
        #expect(config.normalized(duration: 10) == config)
    }
}

struct WebcamBackgroundModelTests {
    @Test func webcamWrittenBeforeBackgroundsDecodesWithNone() throws {
        let json = #"""
            {"enabled":true,"origin":{"x":0.78,"y":0.72},"width":0.2,"aspect":"wide","cornerRadius":0.1,
             "mirrored":false,"shadow":true,"syncOffset":0}
            """#
        let webcam = try JSONDecoder().decode(WebcamSettings.self, from: Data(json.utf8))
        #expect(webcam == WebcamSettings())
        #expect(webcam.background.effect == .none)
    }

    @Test func roundTripsAndFillsMissingKeys() throws {
        var webcam = WebcamSettings()
        webcam.background = WebcamBackground(
            effect: .remove, blurAmount: 0.7, edgeSoftness: 0.2, removalStyle: .framed,
            fill: .linearGradient(from: RGBAColor(hex: "#000000")!, to: RGBAColor(hex: "#FFFFFF")!, angle: 10))
        let data = try JSONEncoder().encode(webcam)
        #expect(try JSONDecoder().decode(WebcamSettings.self, from: data) == webcam)

        let partial = try JSONDecoder().decode(WebcamBackground.self, from: Data(#"{"effect":"blur"}"#.utf8))
        #expect(partial == WebcamBackground(effect: .blur))
    }

    @Test func seeThroughAndCutout() {
        #expect(!WebcamBackground(effect: .blur).isSeeThrough)
        #expect(WebcamBackground(effect: .remove, removalStyle: .cutout).isCutout)
        #expect(WebcamBackground(effect: .remove, removalStyle: .cutout).isSeeThrough)
        #expect(WebcamBackground(effect: .remove, removalStyle: .framed).isSeeThrough)
        let filled = WebcamBackground(effect: .remove, removalStyle: .framed, fill: .solid(RGBAColor(hex: "#FF0000")!))
        #expect(!filled.isSeeThrough)
        #expect(!filled.isCutout)
    }
}
