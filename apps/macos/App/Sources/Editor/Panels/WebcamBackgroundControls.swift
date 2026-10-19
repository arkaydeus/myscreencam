import ProjectKit
import SwiftUI

/// Where the webcam background controls read and write: the open recording (undoable edits) or the defaults for new
/// recordings.
@MainActor
protocol WebcamBackgroundSource: AnyObject {
    var webcamBackground: WebcamBackground { get }
    func webcamBackgroundBinding<V: Equatable>(
        _ keyPath: WritableKeyPath<WebcamBackground, V>, _ action: String
    ) -> Binding<V>
    /// A slider drag started or ended.
    func editingChanged(_ editing: Bool)
    /// The open recording, which can take an image fill; nil for the defaults (images belong to one recording).
    var recording: EditorModel? { get }
}

extension EditorModel: WebcamBackgroundSource {
    var webcamBackground: WebcamBackground { edit.webcam.background }
    var recording: EditorModel? { self }

    private static let webcamBackgroundPath: WritableKeyPath<EditConfig, WebcamBackground> = \.webcam.background

    func webcamBackgroundBinding<V: Equatable>(
        _ keyPath: WritableKeyPath<WebcamBackground, V>, _ action: String
    ) -> Binding<V> {
        binding(Self.webcamBackgroundPath.appending(path: keyPath), action)
    }
}

/// Background blur or removal behind the person in the webcam.
struct WebcamBackgroundControls<Source: WebcamBackgroundSource>: View {
    let source: Source

    enum FillKind: String, CaseIterable, Identifiable {
        case clear, solid, gradient, image
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    private var background: WebcamBackground { source.webcamBackground }
    private var percent: (Double) -> String { { String(format: "%.0f%%", $0 * 100) } }

    var body: some View {
        Picker("Effect", selection: source.webcamBackgroundBinding(\.effect, "Webcam Background")) {
            Text("None").tag(WebcamBackground.Effect.none)
            Text("Blur").tag(WebcamBackground.Effect.blur)
            Text("Remove").tag(WebcamBackground.Effect.remove)
        }
        .pickerStyle(.segmented)

        switch background.effect {
        case .none:
            EmptyView()
        case .blur:
            ValueSlider(
                title: "Blur", value: source.webcamBackgroundBinding(\.blurAmount, "Webcam Background Blur"),
                range: EditLimits.webcamBackgroundBlur, step: 0.01, format: percent,
                onEditingChanged: source.editingChanged)
        case .remove:
            Picker("Style", selection: source.webcamBackgroundBinding(\.removalStyle, "Webcam Removal Style")) {
                Text("Cut-out").tag(WebcamBackground.RemovalStyle.cutout)
                Text("In frame").tag(WebcamBackground.RemovalStyle.framed)
            }
            .pickerStyle(.segmented)
            .help(
                "Cut-out draws just you over the recording. In frame keeps the webcam's shape, with a fill behind you.")
            if background.removalStyle == .framed {
                Picker("Fill", selection: fillKind) {
                    ForEach(fillKinds) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let fill = background.fill {
                    FillControls(
                        fill: Binding(
                            get: { fill },
                            set: { source.webcamBackgroundBinding(\.fill, "Webcam Background Fill").wrappedValue = $0 }
                        ), model: source.recording, chooseImage: chooseImage)
                }
            }
        }

        if background.effect != .none {
            ValueSlider(
                title: "Edge softness", value: source.webcamBackgroundBinding(\.edgeSoftness, "Webcam Edge Softness"),
                range: EditLimits.webcamEdgeSoftness, step: 0.01, format: percent,
                onEditingChanged: source.editingChanged)
            Text("You're found in every frame by on-device person segmentation, so the effect follows you as you move.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var fillKinds: [FillKind] {
        source.recording == nil ? [.clear, .solid, .gradient] : FillKind.allCases
    }

    var fillKind: Binding<FillKind> {
        let fill = source.webcamBackgroundBinding(\.fill, "Webcam Background Fill")
        return Binding(
            get: {
                switch background.fill {
                case nil: .clear
                case .solid: .solid
                case .linearGradient: .gradient
                case .image: .image
                }
            },
            set: { kind in
                switch kind {
                case .clear: fill.wrappedValue = nil
                case .solid: fill.wrappedValue = .solid(RGBAColor(hex: "#1F2937")!)
                case .gradient: fill.wrappedValue = BackgroundSettings().fill
                case .image: chooseImage()
                }
            })
    }

    private func chooseImage() {
        guard let model = source.recording,
            let path = model.chooseFillImage(message: "Choose an image to show behind you")
        else { return }
        model.update("Webcam Background Image") { $0.webcam.background.fill = .image(path: path) }
    }
}
