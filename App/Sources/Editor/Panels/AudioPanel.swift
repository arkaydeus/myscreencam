import AppKit
import ProjectKit
import QuartzCore
import RenderKit
import SwiftUI

struct AudioPanel: View {
    let model: EditorModel

    var body: some View {
        Form {
            track(
                "System audio", stream: .systemAudio, meter: .systemAudio, keyPath: \.audio.system,
                missing: "System audio wasn't recorded.")
            track(
                "Microphone", stream: .microphone, meter: .microphone, keyPath: \.audio.microphone,
                missing: "No microphone was recorded.")
        }
    }

    @ViewBuilder
    private func track(
        _ title: String, stream: StreamKind, meter: AudioTrackKind, keyPath: WritableKeyPath<EditConfig, TrackAudio>,
        missing: String
    ) -> some View {
        let recorded = model.recordedStreams.contains(stream)
        Section(title) {
            if !recorded { NotRecordedNote(text: missing) }
            Group {
                Toggle("Enabled", isOn: model.binding(keyPath.appending(path: \.enabled), "Toggle \(title)"))
                Toggle("Mute", isOn: model.binding(keyPath.appending(path: \.muted), "Mute \(title)"))
                ValueSlider(
                    title: "Gain", value: model.binding(keyPath.appending(path: \.gainDB), "\(title) Gain"),
                    range: EditLimits.gainDB, step: 0.5, format: { String(format: "%+.1f dB", $0) }, model: model)
                HStack {
                    Text("Level")
                    LevelMeter(model: model, kind: meter, isPlaying: model.clock.isPlaying)
                        .frame(height: 8)
                }
            }
            .disabled(!recorded)
        }
    }
}

/// A live level meter drawn with CALayers from `AudioLevels` (display link only while playing).
struct LevelMeter: NSViewRepresentable {
    let model: EditorModel
    let kind: AudioTrackKind
    let isPlaying: Bool

    func makeNSView(context: Context) -> LevelMeterView {
        LevelMeterView(levels: model.renderer.audioLevels, kind: kind)
    }

    func updateNSView(_ view: LevelMeterView, context: Context) {
        view.setActive(isPlaying)
    }

    static func dismantleNSView(_ view: LevelMeterView, coordinator: ()) {
        view.teardown()
    }
}

final class LevelMeterView: NSView {
    private let levels: AudioLevels
    private let kind: AudioTrackKind
    private var ballistics = MeterBallistics()
    private let track = CALayer()
    private let bar = CALayer()
    private let peak = CALayer()
    private let gradient = CAGradientLayer()
    private var link: CADisplayLink?
    private var active = false

    init(levels: AudioLevels, kind: AudioTrackKind) {
        self.levels = levels
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        track.cornerRadius = 3
        track.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [
            NSColor.systemGreen.cgColor, NSColor.systemGreen.cgColor, NSColor.systemYellow.cgColor,
            NSColor.systemRed.cgColor,
        ]
        gradient.locations = [0, 0.6, 0.85, 1]
        gradient.mask = bar
        bar.backgroundColor = NSColor.black.cgColor
        bar.anchorPoint = .zero
        peak.backgroundColor = NSColor.labelColor.cgColor
        layer?.addSublayer(track)
        track.addSublayer(gradient)
        track.addSublayer(peak)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func teardown() {
        link?.invalidate()
        link = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        gradient.frame = track.bounds
        CATransaction.commit()
        draw(level: 0, peakHold: 0, clipping: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        // Meter data is published at about 30 Hz; drawing faster wastes power.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        link.isPaused = !active
        self.link = link
    }

    func setActive(_ playing: Bool) {
        guard playing != active else { return }
        active = playing
        link?.isPaused = !playing
        if !playing {
            ballistics = MeterBallistics()
            draw(level: 0, peakHold: 0, clipping: false)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let reading = ballistics.update(levels.level(for: kind), now: CACurrentMediaTime())
        draw(level: CGFloat(reading.level), peakHold: CGFloat(reading.peakHold), clipping: reading.isClipping)
    }

    private func draw(level: CGFloat, peakHold: CGFloat, clipping: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = track.bounds.width
        bar.frame = CGRect(x: 0, y: 0, width: w * min(max(level, 0), 1), height: track.bounds.height)
        peak.isHidden = peakHold <= 0.001
        peak.frame = CGRect(x: max(0, w * min(peakHold, 1) - 2), y: 0, width: 2, height: track.bounds.height)
        peak.backgroundColor = (clipping ? NSColor.systemRed : NSColor.labelColor).cgColor
        CATransaction.commit()
    }
}
