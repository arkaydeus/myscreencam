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

    private func chooseImage() {
        guard let path = model.chooseFillImage(message: "Choose a background image") else { return }
        model.update("Background Image") { $0.background.fill = .image(path: path) }
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
                    FillControls(
                        fill: model.binding(\.background.fill, "Background Fill"), model: model,
                        chooseImage: chooseImage)
                }
            }
            .disabled(!model.edit.background.enabled)
        }
    }

    private var percent: (Double) -> String { { String(format: "%.0f%%", $0 * 100) } }
}

/// Colour pickers and angle for a solid or gradient fill, or the chosen image. Shared by the Background panel, the
/// fill behind the webcam and Settings › Defaults.
struct FillControls: View {
    @Binding var fill: BackgroundFill
    /// The open recording (for an image fill's file and slider undo grouping); nil for the defaults.
    var model: EditorModel?
    var chooseImage: () -> Void = {}

    var body: some View {
        switch fill {
        case .solid(let color):
            ColorPicker("Colour", selection: colorBinding(color) { .solid($0) })
        case .linearGradient(let from, let to, let angle):
            ColorPicker("From", selection: colorBinding(from) { .linearGradient(from: $0, to: to, angle: angle) })
            ColorPicker("To", selection: colorBinding(to) { .linearGradient(from: from, to: $0, angle: angle) })
            ValueSlider(
                title: "Angle",
                value: Binding(
                    get: { angle },
                    set: { fill = .linearGradient(from: from, to: to, angle: $0) }), range: 0...360, step: 1,
                format: { String(format: "%.0f°", $0) }, onEditingChanged: { model?.editingChanged($0) })
        case .image(let path):
            LabeledContent("Image") {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let model, !FileManager.default.fileExists(atPath: model.package.containedURL(path)?.path ?? "") {
                Label("The image file is missing.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button("Choose Image…") { chooseImage() }
        }
    }

    private func colorBinding(_ current: RGBAColor, _ make: @escaping (RGBAColor) -> BackgroundFill) -> Binding<Color> {
        Binding(
            get: { current.color },
            set: { color in
                let value = RGBAColor(color)
                guard value.hex != current.hex else { return }
                fill = make(value)
            })
    }
}

extension EditorModel {
    /// Asks for an image and copies it into the recording's backgrounds folder. Returns its path in the package, or
    /// nil if cancelled or the copy failed (which is reported).
    func chooseFillImage(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let relative = "\(PackageLayout.backgroundsDirectory)/\(UUID().uuidString).\(url.pathExtension)"
        do {
            let destination = package.url(relative)
            let directory = destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return relative
        } catch {
            flash("Couldn't copy the background image: \(error.localizedDescription)")
            return nil
        }
    }
}
