import ProjectKit
import SwiftUI

struct BlurPanel: View {
    let model: EditorModel

    var body: some View {
        Form {
            Section {
                if model.edit.blur.isEmpty {
                    Text("No blur masks. Add one at the playhead, then drag it on the preview.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.edit.blur) { mask in
                    let selected = model.selection == .blur(mask.id)
                    HStack {
                        Image(systemName: "drop.halffull").foregroundStyle(.pink)
                        Text("\(TimeFormat.clock(mask.start)) – \(TimeFormat.clock(mask.end))")
                            .monospacedDigit()
                            .fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? Color.themeAccent : Color.primary)
                        Spacer()
                        Text("source").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .listRowBackground(selected ? Color.themeAccent.opacity(0.16) : nil)
                    .onTapGesture {
                        model.selection = .blur(mask.id)
                        model.pause()
                        model.seek(to: model.timeline.editedTimeSnapping(forSource: mask.start))
                    }
                }
            } header: {
                HStack {
                    Text("Masks (\(model.edit.blur.count))")
                    Spacer()
                    Button {
                        model.addBlurAtPlayhead()
                    } label: {
                        Label("Add Mask", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let mask = model.selectedBlur {
                SelectedBlurSection(model: model, mask: mask)
            }
        }
    }
}

private struct SelectedBlurSection: View {
    let model: EditorModel
    let mask: BlurMask

    private func binding(_ keyPath: WritableKeyPath<BlurMask, Double>, _ action: String) -> Binding<Double> {
        let id = mask.id
        return Binding(
            get: { model.edit.blur.first { $0.id == id }?[keyPath: keyPath] ?? mask[keyPath: keyPath] },
            set: { value in
                model.updateBlur(id, action, coalesce: AnyHashable([AnyHashable(id), AnyHashable(keyPath)])) {
                    $0[keyPath: keyPath] = value
                }
            })
    }

    private var percent: (Double) -> String { { String(format: "%.0f%%", $0 * 100) } }

    var body: some View {
        Section("Selected mask") {
            ValueSlider(
                title: "Intensity", value: binding(\.intensity, "Blur Intensity"), range: EditLimits.blurIntensity,
                step: 1, format: { String(format: "%.0f px", $0) }, model: model)
            ValueSlider(title: "X", value: binding(\.rect.x, "Move Blur"), range: 0...1, format: percent, model: model)
            ValueSlider(title: "Y", value: binding(\.rect.y, "Move Blur"), range: 0...1, format: percent, model: model)
            ValueSlider(
                title: "Width", value: binding(\.rect.w, "Resize Blur"), range: 0.01...1, format: percent, model: model)
            ValueSlider(
                title: "Height", value: binding(\.rect.h, "Resize Blur"), range: 0.01...1, format: percent,
                model: model)
            LabeledContent("Time") {
                Text("\(TimeFormat.clock(mask.start)) – \(TimeFormat.clock(mask.end))").monospacedDigit()
            }
            Text("Drag the bar in the Blur row to move it; drag its edges to change the timing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Delete Mask", role: .destructive) { model.deleteBlur(mask.id) }
        }
    }
}
