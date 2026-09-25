import ProjectKit
import SwiftUI

/// Time, skip/play, cut/delete/reset, and timeline zoom.
struct TransportBar: View {
    let model: EditorModel

    static let zoomSteps: [Double] = stride(from: 0.5, through: 4, by: 0.25).map { $0 }

    var body: some View {
        HStack(spacing: 14) {
            TimeLabel(clock: model.clock, duration: model.timeline.duration)

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
            .buttonStyle(.borderless)
            .font(.title3)

            Divider().frame(height: 18)

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
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
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

/// The only view that reads the ~10 Hz clock.
private struct TimeLabel: View {
    let clock: PlaybackClock
    let duration: Double

    var body: some View {
        HStack(spacing: 0) {
            Text(TimeFormat.clock(clock.time))
            Text(" / " + TimeFormat.clock(duration)).foregroundStyle(.secondary)
        }
        .font(.system(.callout, design: .monospaced))
        .frame(minWidth: 150, alignment: .leading)
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
                .frame(width: 22)
        }
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
