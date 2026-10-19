import Foundation
import Testing

@testable import ProjectKit

struct ProjectDefaultsTests {
    private func click(_ t: Double) -> InputEvent { InputEvent(t: t, kind: .down, x: 0.5, y: 0.5, button: 0) }

    @Test func builtInDefaultsMatchAFreshEdit() {
        let meta = Fixtures.meta(duration: 5)
        let initial = EditConfig.makeInitial(meta: meta, events: [], defaults: ProjectDefaults())
        #expect(initial == EditConfig.initial(for: meta).with(segmentIDs: initial.segments))
    }

    @Test func initialEditTakesTheDefaults() {
        var style = SubtitleStyle()
        style.fontFamily = "Helvetica"
        style.uppercase = true
        let defaults = ProjectDefaults(
            zoomEnabled: false, autoZoom: true,
            zoomTiming: ZoomTiming(scale: 2.5, easeIn: 0.1, hold: 0.5, easeOut: 0.2),
            subtitlesEnabled: false, subtitleStyle: style,
            subtitlePlacement: SubtitlePlacement(anchor: .top, margin: 0.1))
        let edit = EditConfig.makeInitial(meta: Fixtures.meta(duration: 5), events: [click(2)], defaults: defaults)
        #expect(!edit.zoom.enabled)
        #expect(edit.zoom.defaults == defaults.zoomTiming)
        // Seeded zooms use the default timing.
        #expect(edit.zoom.keyframes.map(\.scale) == [2.5])
        #expect(edit.zoom.keyframes.map(\.hold) == [0.5])
        #expect(!edit.subtitles.enabled)
        #expect(edit.subtitles.style == style)
        #expect(edit.subtitles.placement == SubtitlePlacement(anchor: .top, margin: 0.1))
    }

    @Test func roundTripsAndFillsMissingKeys() throws {
        var defaults = ProjectDefaults(autoZoom: false)
        defaults.subtitleStyle.bold = false
        defaults.webcamBackground = WebcamBackground(
            effect: .remove, removalStyle: .framed, fill: .solid(RGBAColor(hex: "#1F2937")!))
        let data = try JSONEncoder().encode(defaults)
        #expect(try JSONDecoder().decode(ProjectDefaults.self, from: data) == defaults)

        let partial = try JSONDecoder().decode(ProjectDefaults.self, from: Data(#"{"autoZoom":false}"#.utf8))
        #expect(partial == ProjectDefaults(autoZoom: false))
    }

    @Test func initialEditTakesTheWebcamBackgroundButNotAnImage() {
        let blur = WebcamBackground(effect: .blur, blurAmount: 0.8, edgeSoftness: 0.1)
        let blurred = EditConfig.makeInitial(
            meta: Fixtures.meta(duration: 5), events: [], defaults: ProjectDefaults(webcamBackground: blur))
        #expect(blurred.webcam.background == blur)

        let withImage = WebcamBackground(
            effect: .remove, removalStyle: .framed, fill: .image(path: "backgrounds/a.png"))
        let removed = EditConfig.makeInitial(
            meta: Fixtures.meta(duration: 5), events: [], defaults: ProjectDefaults(webcamBackground: withImage))
        #expect(removed.webcam.background.effect == .remove)
        #expect(removed.webcam.background.removalStyle == .framed)
        #expect(removed.webcam.background.fill == nil)
    }

    @Test func subtitlesViewWritesBackTheLook() {
        var defaults = ProjectDefaults()
        defaults.subtitles.style.size = 0.08
        defaults.subtitles.placement.anchor = .middle
        defaults.subtitles.enabled = false
        #expect(defaults.subtitleStyle.size == 0.08)
        #expect(defaults.subtitlePlacement.anchor == .middle)
        #expect(!defaults.subtitlesEnabled)
    }
}
