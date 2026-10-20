import AppKit
import ProjectKit
import RenderKit
import SwiftUI

struct ZoomPanel: View {
    let model: EditorModel

    var body: some View {
        Form {
            CropSection(model: model)

            Section {
                Toggle("Zoom", isOn: model.binding(\.zoom.enabled, "Toggle Zoom"))
            }

            Section("New zooms in this recording") {
                ValueSlider(
                    title: "Scale", value: model.binding(\.zoom.defaults.scale, "Zoom Scale"), range: 1.1...4,
                    step: 0.05, format: { String(format: "%.2f×", $0) }, model: model)
                ValueSlider(
                    title: "Ease in", value: model.binding(\.zoom.defaults.easeIn, "Zoom Ease In"), range: 0.05...1,
                    format: TimeFormat.seconds, model: model)
                ValueSlider(
                    title: "Hold", value: model.binding(\.zoom.defaults.hold, "Zoom Hold"), range: 0.1...2,
                    format: TimeFormat.seconds, model: model)
                ValueSlider(
                    title: "Ease out", value: model.binding(\.zoom.defaults.easeOut, "Zoom Ease Out"),
                    range: 0.05...1, format: TimeFormat.seconds, model: model)
                Text("Defaults for new recordings, including zooms from clicks, are in Settings › Defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.edit.zoom.keyframes.isEmpty {
                    Text("No zooms yet. Add one at the playhead.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.edit.zoom.keyframes) { keyframe in
                    KeyframeRow(model: model, keyframe: keyframe)
                }
            } header: {
                HStack {
                    Text("Zooms (\(model.edit.zoom.keyframes.count))")
                    Spacer()
                    Button {
                        model.addKeyframeAtPlayhead()
                    } label: {
                        Label("Add at Playhead", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            if let keyframe = model.selectedKeyframe {
                SelectedKeyframeSection(model: model, keyframe: keyframe, selected: model.selectedKeyframes)
            }
        }
    }
}

/// The crop tool: choose the part of the screen recording kept in the output.
private struct CropSection: View {
    let model: EditorModel

    /// The kept area in recording pixels.
    private var size: String {
        guard model.edit.crop != nil else { return "Full frame" }
        let rect = CanvasLayout.sourceCrop(model.edit.crop, sourceSize: model.renderer.layout.sourceSize)
        return "\(Int(rect.width)) × \(Int(rect.height))"
    }

    var body: some View {
        Section("Crop") {
            HStack {
                Button {
                    model.toggleCropEditing()
                } label: {
                    Label(model.isEditingCrop ? "Done" : "Crop on Preview", systemImage: "crop")
                }
                Spacer()
                Text(size)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if model.isEditingCrop {
                Text("Drag on the preview to choose the area to keep, or drag the red box and its handles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.edit.crop != nil {
                Button("Reset to Full Frame") { model.setCrop(nil, "Reset Crop") }
            }
        }
    }
}

private struct KeyframeRow: View {
    let model: EditorModel
    let keyframe: ZoomKeyframe

    var body: some View {
        let selected = model.selectedKeyframeIDs.contains(keyframe.id)
        let edited = model.timeline.editedTime(forSource: keyframe.time)
        HStack {
            Image(systemName: keyframe.mode == .followMouse ? "cursorarrow.motionlines" : "plus.magnifyingglass")
                .foregroundStyle(keyframe.enabled ? Color.themeZoom : Color.secondary)
            Text(edited.map(TimeFormat.clock) ?? "cut")
                .monospacedDigit()
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(edited == nil ? Color.secondary : (selected ? Color.themeAccent : Color.primary))
            Text(String(format: "%.2f×", keyframe.scale))
                .foregroundStyle(.secondary)
            Spacer()
            if !keyframe.enabled {
                Text("Off").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(selected ? Color.themeAccent.opacity(0.16) : nil)
        .onTapGesture {
            model.selectKeyframe(keyframe.id, SelectionModifier(NSEvent.modifierFlags))
            if let edited, model.selectedKeyframeIDs.contains(keyframe.id) { model.seek(to: edited) }
        }
    }
}

/// Edits the selected zooms. Controls show `keyframe`'s values; a change applies to every selected zoom.
private struct SelectedKeyframeSection: View {
    let model: EditorModel
    let keyframe: ZoomKeyframe
    let selected: [ZoomKeyframe]

    private func binding<V: Equatable>(_ keyPath: WritableKeyPath<ZoomKeyframe, V>, _ action: String) -> Binding<V> {
        let id = keyframe.id
        let ids = Set(selected.map(\.id))
        return Binding(
            get: { model.edit.zoom.keyframes.first { $0.id == id }?[keyPath: keyPath] ?? keyframe[keyPath: keyPath] },
            set: { value in
                model.updateKeyframes(ids, action, coalesce: AnyHashable([AnyHashable(ids), AnyHashable(keyPath)])) {
                    $0[keyPath: keyPath] = value
                }
            })
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(selected.count > 1 ? "\(selected.count) selected zooms" : "Selected zoom")
        } footer: {
            if selected.count > 1 {
                Text("Changes apply to every selected zoom.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        Toggle("Enabled", isOn: binding(\.enabled, "Toggle Zoom"))
        Toggle("Instant (no easing)", isOn: binding(\.instant, "Instant Zoom"))
        Picker("Mode", selection: binding(\.mode, "Zoom Mode")) {
            Text("Manual").tag(ZoomMode.manual)
            Text("Click").tag(ZoomMode.click)
            Text("Follow mouse").tag(ZoomMode.followMouse)
        }
        ValueSlider(
            title: "Scale", value: binding(\.scale, "Zoom Scale"), range: EditLimits.zoomScale, step: 0.05,
            format: { String(format: "%.2f×", $0) }, model: model)
        if selected.contains(where: { $0.mode != .followMouse }) {
            if model.edit.crop != nil {
                Text("Target coordinates are relative to the crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ValueSlider(
                title: "Target X", value: model.zoomTargetBinding(\.x, keyframe: keyframe), range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) }, model: model)
            ValueSlider(
                title: "Target Y", value: model.zoomTargetBinding(\.y, keyframe: keyframe), range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) }, model: model)
            Button {
                model.pause()
                model.isPickingZoomTarget.toggle()
            } label: {
                Label(
                    model.isPickingZoomTarget ? "Click the Preview…" : "Set Target on Preview",
                    systemImage: "scope")
            }
        }
        if selected.contains(where: { !$0.instant }) {
            ValueSlider(
                title: "Ease in", value: binding(\.easeIn, "Zoom Ease In"), range: 0.05...1,
                format: TimeFormat.seconds, model: model)
            ValueSlider(
                title: "Ease out", value: binding(\.easeOut, "Zoom Ease Out"), range: 0.05...1,
                format: TimeFormat.seconds, model: model)
        }
        ValueSlider(
            title: "Hold", value: binding(\.hold, "Zoom Hold"), range: 0.1...10, format: TimeFormat.seconds,
            model: model)
        HStack {
            if selected.count == 1 {
                Button("Duplicate") { model.duplicateKeyframe(keyframe.id) }
            }
            Spacer()
            Button(selected.count > 1 ? "Delete \(selected.count) Zooms" : "Delete", role: .destructive) {
                model.deleteKeyframes(Set(selected.map(\.id)))
            }
        }
    }
}
