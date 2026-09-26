import AppKit
import ProjectKit
import QuartzCore
import SwiftUI

/// Time, skip/play, cut/delete/reset, and timeline zoom.
struct TransportBar: View {
    let model: EditorModel

    static let zoomSteps: [Double] = stride(from: 0.5, through: 4, by: 0.25).map { $0 }

    var body: some View {
        HStack(spacing: 14) {
            TimeLabel(clock: model.clock, duration: model.timeline.duration)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    Color.editorControlFill,
                    in: RoundedRectangle(cornerRadius: EditorTheme.controlRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: EditorTheme.controlRadius, style: .continuous)
                        .strokeBorder(Color.editorControlBorder))

            HStack(spacing: 4) {
                Button {
                    model.skip(by: -5)
                } label: {
                    Image(systemName: "gobackward.5")
                }
                .help("Back 5 seconds")
                PlayPauseButton(model: model, clock: model.clock)
                Button {
                    model.skip(by: 5)
                } label: {
                    Image(systemName: "goforward.5")
                }
                .help("Forward 5 seconds")
            }
            .buttonStyle(.editorIcon)
            .font(.title3)

            Rectangle()
                .fill(Color.editorControlBorder)
                .frame(width: 1, height: 18)

            HStack(spacing: 6) {
                Button {
                    model.cutAtPlayhead()
                } label: {
                    Label("Cut", systemImage: "scissors")
                }
                .help("Cut at the playhead (C)")
                Button {
                    model.deleteSelectedSegment()
                } label: {
                    Label("Delete Segment", systemImage: "minus.square")
                }
                .disabled(model.selectedSegmentID == nil || model.edit.segments.count < 2)
                .help("Delete the selected segment (Delete)")
                Button {
                    model.resetCuts()
                } label: {
                    Label("Reset Cuts", systemImage: "arrow.uturn.backward.square")
                }
                .disabled(!model.hasCuts)
                .help("Restore the whole recording")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.editorIcon)

            if let message = model.transientMessage {
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            } else if let error = model.renderError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    zoom(by: -1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(model.timelineZoom <= Self.zoomSteps.first! + 0.001)
                .help("Zoom timeline out")
                Menu {
                    ForEach(Self.zoomSteps, id: \.self) { step in
                        Button("\(Int((step * 100).rounded()))%") { model.timelineZoom = step }
                    }
                } label: {
                    Text("\(Int((model.timelineZoom * 100).rounded()))%")
                        .monospacedDigit()
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Timeline zoom")
                Button {
                    zoom(by: 1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(model.timelineZoom >= Self.zoomSteps.last! - 0.001)
                .help("Zoom timeline in")
            }
            .buttonStyle(.editorIcon)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .animation(.easeInOut(duration: 0.15), value: model.transientMessage)
    }

    private func zoom(by direction: Int) {
        let current = model.timelineZoom
        if direction > 0 {
            model.timelineZoom = Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last!
        } else {
            model.timelineZoom = Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first!
        }
    }
}

/// "time / duration". The ~10 Hz time is drawn by a `CATextLayer` fed straight from the clock, so playback never
/// invalidates SwiftUI (see `PlaybackClock`).
private struct TimeLabel: View {
    let clock: PlaybackClock
    let duration: Double

    var body: some View {
        TimeLabelRepresentable(clock: clock, duration: duration)
            .frame(width: max(150, TimeLabelView.width(forDuration: duration)), height: 18, alignment: .leading)
    }
}

private struct TimeLabelRepresentable: NSViewRepresentable {
    let clock: PlaybackClock
    let duration: Double

    func makeNSView(context: Context) -> TimeLabelView {
        TimeLabelView(clock: clock)
    }

    func updateNSView(_ view: TimeLabelView, context: Context) {
        view.duration = duration
    }

    static func dismantleNSView(_ view: TimeLabelView, coordinator: ()) {
        view.teardown()
    }
}

final class TimeLabelView: NSView {
    private let clock: PlaybackClock
    private let text = CATextLayer()
    private var time: Double

    var duration: Double = 0 {
        didSet { if duration != oldValue { redraw() } }
    }

    private static var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    }

    /// Width of "m:ss.cc / m:ss.cc" for a duration (monospaced, so any digits measure the same).
    static func width(forDuration duration: Double) -> CGFloat {
        let sample = TimeFormat.clock(duration) + " / " + TimeFormat.clock(duration)
        return ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    init(clock: PlaybackClock) {
        self.clock = clock
        time = clock.time
        super.init(frame: .zero)
        wantsLayer = true
        text.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        text.truncationMode = .end
        layer?.addSublayer(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        clock.observeTime(self) { [weak self] t in
            self?.time = t
            self?.redraw()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func teardown() {
        clock.removeTimeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        text.frame = CGRect(x: 0, y: (bounds.height - lineHeight) / 2, width: bounds.width, height: lineHeight)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        text.contentsScale = window?.backingScaleFactor ?? 2
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    private func redraw() {
        let current = TimeFormat.clock(time)
        let total = " / " + TimeFormat.clock(duration)
        let string = NSMutableAttributedString()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            string.append(
                NSAttributedString(
                    string: current, attributes: [.font: Self.font, .foregroundColor: EditorTheme.primaryText.cgColor]))
            string.append(
                NSAttributedString(
                    string: total,
                    attributes: [.font: Self.font, .foregroundColor: EditorTheme.secondaryText.cgColor]))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.string = string
        CATransaction.commit()
        setAccessibilityValue(current + total)
    }
}

private struct PlayPauseButton: View {
    let model: EditorModel
    let clock: PlaybackClock

    var body: some View {
        Button {
            model.togglePlay()
        } label: {
            Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.editorOnAccent)
                .frame(width: 34, height: 34)
                .background(
                    Color.editorAccent,
                    in: RoundedRectangle(cornerRadius: EditorTheme.controlRadius, style: .continuous)
                )
                .shadow(color: Color.editorAccent.opacity(0.3), radius: 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(clock.isPlaying ? "Pause (Space)" : "Play (Space)")
    }
}

enum TimeFormat {
    /// `m:ss.cc` (or `h:mm:ss.cc`).
    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        let hundredths = Int((s * 100).rounded(.down))
        let cs = hundredths % 100
        let total = hundredths / 100
        let h = total / 3600
        let m = (total / 60) % 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, sec, cs) }
        return String(format: "%d:%02d.%02d", m, sec, cs)
    }

    /// Short seconds, e.g. `1.25 s`.
    static func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }
}
