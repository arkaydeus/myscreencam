import ProjectKit
import SwiftUI

/// The right-hand panel: an icon tab switcher, the selected tab's title and its controls.
struct InspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                tabSwitcher
                HStack(alignment: .firstTextBaseline) {
                    Text(model.inspectorTab.title)
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    if let summary {
                        Text(summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.editorTertiaryText)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 2)
            Group {
                switch model.inspectorTab {
                case .zoom: ZoomPanel(model: model)
                case .webcam: WebcamPanel(model: model)
                case .audio: AudioPanel(model: model)
                case .blur: BlurPanel(model: model)
                case .cursor: CursorPanel(model: model)
                case .background: BackgroundPanel(model: model)
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
            ForEach(InspectorTab.allCases) { tab in
                let selected = model.inspectorTab == tab
                Button {
                    model.inspectorTab = tab
                } label: {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(selected ? Color.editorOnAccent : Color.editorSecondaryText)
                        .background(
                            selected ? Color.editorAccent : .clear,
                            in: RoundedRectangle(cornerRadius: EditorTheme.controlRadius - 1, style: .continuous)
                        )
                        .shadow(color: selected ? Color.editorAccent.opacity(0.35) : .clear, radius: 7, y: 3)
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
            Color.editorControlFill,
            in: RoundedRectangle(cornerRadius: EditorTheme.controlRadius + 2, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorTheme.controlRadius + 2, style: .continuous)
                .strokeBorder(Color.editorControlBorder))
    }

    /// A count shown beside the tab title, where the tab holds a list.
    private var summary: String? {
        switch model.inspectorTab {
        case .zoom:
            let count = model.edit.zoom.keyframes.count
            return count == 1 ? "1 zoom" : "\(count) zooms"
        case .blur:
            let count = model.edit.blur.count
            return count == 1 ? "1 mask" : "\(count) masks"
        default:
            return nil
        }
    }
}

/// A labelled slider with its value; the drag is one undo step.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(Color.editorSecondaryText)
            }
            Slider(value: steppedValue, in: range) { model.editingChanged($0) }
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
