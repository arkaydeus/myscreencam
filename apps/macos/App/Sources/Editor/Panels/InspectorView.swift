import ProjectKit
import SwiftUI

/// The right-hand panel: an icon tab switcher, the selected tab's title and its controls.
struct InspectorView: View {
    @Bindable var model: EditorModel
    @Environment(AppModel.self) private var app

    /// The Subtitles tab appears once an engine is enabled, or when this recording already has subtitles.
    private var tabs: [InspectorTab] {
        let subtitles =
            app.transcription.isAvailable || !model.edit.subtitles.cues.isEmpty
            || model.edit.subtitles.revisionID != nil || app.transcription.job(for: model.package.url) != nil
        return InspectorTab.allCases.filter { $0 != .subtitles || subtitles }
    }

    private var visibleTab: InspectorTab { tabs.contains(model.inspectorTab) ? model.inspectorTab : .zoom }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                tabSwitcher
                HStack(alignment: .firstTextBaseline) {
                    Text(visibleTab.title)
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    if let summary {
                        Text(summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.themeTertiaryText)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 2)
            Group {
                switch visibleTab {
                case .zoom: ZoomPanel(model: model)
                case .webcam: WebcamPanel(model: model)
                case .audio: AudioPanel(model: model)
                case .blur: BlurPanel(model: model)
                case .cursor: CursorPanel(model: model)
                case .background: BackgroundPanel(model: model)
                case .subtitles: SubtitlesPanel(model: model)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = visibleTab == tab
                Button {
                    model.inspectorTab = tab
                } label: {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(selected ? Color.themeOnAccent : Color.themeSecondaryText)
                        .background(
                            selected ? Color.themeAccent : .clear,
                            in: RoundedRectangle(cornerRadius: AppTheme.controlRadius - 1, style: .continuous)
                        )
                        .shadow(color: selected ? Color.themeAccent.opacity(0.35) : .clear, radius: 7, y: 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            Color.themeControlFill,
            in: RoundedRectangle(cornerRadius: AppTheme.controlRadius + 2, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.controlRadius + 2, style: .continuous)
                .strokeBorder(Color.themeControlBorder))
    }

    /// A count shown beside the tab title, where the tab holds a list.
    private var summary: String? {
        switch visibleTab {
        case .zoom:
            let count = model.edit.zoom.keyframes.count
            return count == 1 ? "1 zoom" : "\(count) zooms"
        case .blur:
            let count = model.edit.blur.count
            return count == 1 ? "1 mask" : "\(count) masks"
        case .subtitles:
            let count = model.edit.subtitles.cues.count
            return count == 0 ? nil : (count == 1 ? "1 subtitle" : "\(count) subtitles")
        default:
            return nil
        }
    }
}

/// A labelled slider with its value. With a `model`, the drag is one undo step.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var onEditingChanged: (Bool) -> Void = { _ in }

    init(
        title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil,
        format: @escaping (Double) -> String = { String(format: "%.2f", $0) },
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
        self.onEditingChanged = onEditingChanged
    }

    init(
        title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil,
        format: @escaping (Double) -> String = { String(format: "%.2f", $0) }, model: EditorModel
    ) {
        self.init(
            title: title, value: value, range: range, step: step, format: format,
            onEditingChanged: { model.editingChanged($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(Color.themeSecondaryText)
            }
            Slider(value: steppedValue, in: range, onEditingChanged: onEditingChanged)
        }
    }

    /// Snaps to `step` itself: `Slider(value:in:step:)` draws a tick mark per step, which fine steps pack into a dotted line.
    private var steppedValue: Binding<Double> {
        guard let step else { return $value }
        return SteppedSliderValue.binding($value, in: range, step: step)
    }
}

enum SteppedSliderValue {
    /// Keep the grid anchored to the lower bound, while allowing both slider endpoints even when the range
    /// is not an exact multiple of the step.
    static func snap(_ proposed: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        precondition(step > 0 && step.isFinite)
        if proposed <= range.lowerBound { return range.lowerBound }
        if proposed >= range.upperBound { return range.upperBound }
        let snapped = range.lowerBound + ((proposed - range.lowerBound) / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    static func binding(_ value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { proposed in
                let snapped = snap(proposed, in: range, step: step)
                if snapped != value.wrappedValue { value.wrappedValue = snapped }
            })
    }
}

extension RGBAColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent),
            a: Double(ns.alphaComponent))
    }
}

extension EditorModel {
    /// A `Color` binding onto an `RGBAColor` edit value (colour-well changes coalesce into one undo step).
    func colorBinding(_ keyPath: WritableKeyPath<EditConfig, RGBAColor>, _ action: String) -> Binding<Color> {
        Binding(
            get: { self.edit[keyPath: keyPath].color },
            set: { color in
                let value = RGBAColor(color)
                guard value.hex != self.edit[keyPath: keyPath].hex else { return }
                self.update(action, coalesce: AnyHashable(keyPath)) { $0[keyPath: keyPath] = value }
            })
    }
}

/// Shown instead of a panel's controls when the stream wasn't recorded.
struct NotRecordedNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .foregroundStyle(.secondary)
            .font(.callout)
    }
}
