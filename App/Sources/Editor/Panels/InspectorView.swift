import ProjectKit
import SwiftUI

/// The right-hand panel: a tab strip and the selected tab's controls.
struct InspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases) { tab in
                    Button {
                        model.inspectorTab = tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 14))
                                .frame(height: 16)
                            Text(tab.title)
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .foregroundStyle(model.inspectorTab == tab ? Color.accentColor : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(model.inspectorTab == tab ? Color.accentColor.opacity(0.14) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            .padding(6)
            Divider()
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
            .controlSize(.small)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step) { model.editingChanged($0) }
            } else {
                Slider(value: $value, in: range) { model.editingChanged($0) }
            }
        }
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
