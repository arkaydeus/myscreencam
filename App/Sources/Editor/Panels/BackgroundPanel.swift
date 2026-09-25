import AppKit
import ProjectKit
import SwiftUI
import UniformTypeIdentifiers

struct BackgroundPanel: View {
    let model: EditorModel

    private enum FillKind: String, CaseIterable, Identifiable {
        case solid, gradient, image
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    private var fillKind: Binding<FillKind> {
        Binding(
            get: {
                switch model.edit.background.fill {
                case .solid: .solid
                case .linearGradient: .gradient
                case .image: .image
                }
            },
            set: { kind in
                switch kind {
                case .solid:
                    model.update("Background Fill") { $0.background.fill = .solid(RGBAColor(hex: "#1F2937")!) }
                case .gradient:
                    model.update("Background Fill") { $0.background.fill = BackgroundSettings().fill }
                case .image:
                    chooseImage()
                }
            })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Background", isOn: model.binding(\.background.enabled, "Toggle Background"))
                Picker("Aspect", selection: model.binding(\.background.aspect, "Output Aspect")) {
                    Text("Source").tag(OutputAspect.source)
                    Text("16:9").tag(OutputAspect.landscape16x9)
                    Text("4:3").tag(OutputAspect.standard4x3)
                    Text("1:1").tag(OutputAspect.square)
                    Text("9:16").tag(OutputAspect.portrait9x16)
                }
            }
            Group {
                Section("Frame") {
                    ValueSlider(
                        title: "Padding", value: model.binding(\.background.padding, "Background Padding"),
                        range: EditLimits.backgroundPadding, format: percent, model: model)
                    ValueSlider(
                        title: "Corner radius", value: model.binding(\.background.cornerRadius, "Corner Radius"),
                        range: EditLimits.backgroundCornerRadius, format: percent, model: model)
                    ValueSlider(
                        title: "Shadow", value: model.binding(\.background.shadow, "Background Shadow"), range: 0...1,
                        format: percent, model: model)
                }
                Section("Fill") {
                    Picker("Fill", selection: fillKind) {
                        ForEach(FillKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    fillControls
                }
            }
            .disabled(!model.edit.background.enabled)
        }
    }

    private var percent: (Double) -> String { { String(format: "%.0f%%", $0 * 100) } }

    @ViewBuilder private var fillControls: some View {
        switch model.edit.background.fill {
        case .solid(let color):
            ColorPicker("Colour", selection: fillColor(color) { .solid($0) })
        case .linearGradient(let from, let to, let angle):
            ColorPicker("From", selection: fillColor(from) { .linearGradient(from: $0, to: to, angle: angle) })
            ColorPicker("To", selection: fillColor(to) { .linearGradient(from: from, to: $0, angle: angle) })
            ValueSlider(
                title: "Angle",
                value: Binding(
                    get: { angle },
                    set: { value in
                        model.update("Gradient Angle", coalesce: "gradientAngle") {
                            $0.background.fill = .linearGradient(from: from, to: to, angle: value)
                        }
                    }), range: 0...360, step: 1, format: { String(format: "%.0f°", $0) }, model: model)
        case .image(let path):
            LabeledContent("Image") {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !FileManager.default.fileExists(atPath: path) {
                Label("The image file is missing.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button("Choose Image…") { chooseImage() }
        }
    }

    private func fillColor(_ current: RGBAColor, _ make: @escaping (RGBAColor) -> BackgroundFill) -> Binding<Color> {
        Binding(
            get: { current.color },
            set: { color in
                let value = RGBAColor(color)
                guard value.hex != current.hex else { return }
                model.update("Background Colour", coalesce: "backgroundColour") { $0.background.fill = make(value) }
            })
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a background image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.update("Background Image") { $0.background.fill = .image(path: url.path) }
    }
}
