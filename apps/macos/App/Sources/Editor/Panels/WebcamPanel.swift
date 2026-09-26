import ProjectKit
import SwiftUI

struct WebcamPanel: View {
    let model: EditorModel

    private static let sizes: [(String, Double)] = [("S", 0.15), ("M", 0.2), ("L", 0.3)]

    private enum Shape: String, CaseIterable, Identifiable {
        case square, rounded, circle
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    private var shape: Binding<Shape> {
        Binding(
            get: {
                let r = model.edit.webcam.cornerRadius
                return r <= 0.001 ? .square : (r >= 0.499 ? .circle : .rounded)
            },
            set: { shape in
                let radius: Double =
                    switch shape {
                    case .square: 0
                    case .rounded: 0.1
                    case .circle: 0.5
                    }
                model.update("Webcam Shape") { $0.webcam.cornerRadius = radius }
            })
    }

    var body: some View {
        Form {
            if !model.hasWebcam {
                Section { NotRecordedNote(text: "No webcam was recorded with this recording.") }
            }
            Group {
                Section {
                    Toggle("Show webcam", isOn: model.binding(\.webcam.enabled, "Toggle Webcam"))
                    Toggle("Mirror", isOn: model.binding(\.webcam.mirrored, "Mirror Webcam"))
                    Toggle("Shadow", isOn: model.binding(\.webcam.shadow, "Webcam Shadow"))
                }

                Section("Position") {
                    HStack {
                        ForEach(EditorModel.WebcamCorner.allCases) { corner in
                            Button {
                                model.placeWebcam(corner)
                            } label: {
                                Image(systemName: corner.systemImage)
                                    .frame(maxWidth: .infinity)
                            }
                            .help(corner.title)
                        }
                    }
                    ValueSlider(
                        title: "X", value: model.binding(\.webcam.origin.x, "Move Webcam"), range: 0...1,
                        format: percent, model: model)
                    ValueSlider(
                        title: "Y", value: model.binding(\.webcam.origin.y, "Move Webcam"), range: 0...1,
                        format: percent, model: model)
                }

                Section("Size and shape") {
                    Picker("Size", selection: sizePreset) {
                        ForEach(Self.sizes, id: \.1) { name, value in Text(name).tag(Optional(value)) }
                        if sizePreset.wrappedValue == nil { Text("Custom").tag(Double?.none) }
                    }
                    .pickerStyle(.segmented)
                    ValueSlider(
                        title: "Width", value: model.binding(\.webcam.width, "Resize Webcam"),
                        range: EditLimits.webcamWidth, format: percent, model: model)
                    Picker("Shape", selection: shape) {
                        ForEach(Shape.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ValueSlider(
                        title: "Corner radius", value: model.binding(\.webcam.cornerRadius, "Webcam Corner Radius"),
                        range: EditLimits.webcamCornerRadius, format: percent, model: model)
                    Picker("Aspect", selection: model.binding(\.webcam.aspect, "Webcam Aspect")) {
                        Text("Wide").tag(WebcamSettings.Aspect.wide)
                        Text("Square").tag(WebcamSettings.Aspect.square)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Sync") {
                    ValueSlider(
                        title: "Offset", value: model.binding(\.webcam.syncOffset, "Webcam Sync"),
                        range: EditLimits.webcamSyncOffset, step: 0.05, format: { String(format: "%+.2f s", $0) },
                        model: model)
                    HStack {
                        Text("Positive delays the webcam. You can also drag the Webcam row in the timeline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { model.update("Reset Webcam Sync") { $0.webcam.syncOffset = 0 } }
                            .disabled(model.edit.webcam.syncOffset == 0)
                    }
                }
            }
            .disabled(!model.hasWebcam)
        }
    }

    private var percent: (Double) -> String { { String(format: "%.0f%%", $0 * 100) } }

    private var sizePreset: Binding<Double?> {
        Binding(
            get: { Self.sizes.map(\.1).first { abs($0 - model.edit.webcam.width) < 0.001 } },
            set: { value in if let value { model.setWebcamWidth(value) } })
    }
}
