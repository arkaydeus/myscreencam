import ProjectKit
import SwiftUI

struct ZoomPanel: View {
    let model: EditorModel
    @AppStorage(EditorModel.autoZoomDefaultsKey) private var autoZoomFromClicks = true

    var body: some View {
        Form {
            Section {
                Toggle("Zoom", isOn: model.binding(\.zoom.enabled, "Toggle Zoom"))
                Toggle("Create zooms from clicks", isOn: $autoZoomFromClicks)
                    .help("New recordings start with a zoom on every left click")
            }

            Section("Defaults for new zooms") {
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
                SelectedKeyframeSection(model: model, keyframe: keyframe)
            }
        }
    }
}

private struct KeyframeRow: View {
    let model: EditorModel
    let keyframe: ZoomKeyframe

    var body: some View {
        let selected = model.selection == .keyframe(keyframe.id)
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
            model.selection = .keyframe(keyframe.id)
            if let edited { model.seek(to: edited) }
        }
    }
}

private struct SelectedKeyframeSection: View {
    let model: EditorModel
    let keyframe: ZoomKeyframe

    private func binding<V: Equatable>(_ keyPath: WritableKeyPath<ZoomKeyframe, V>, _ action: String) -> Binding<V> {
        let id = keyframe.id
        return Binding(
            get: { model.edit.zoom.keyframes.first { $0.id == id }?[keyPath: keyPath] ?? keyframe[keyPath: keyPath] },
            set: { value in
                model.updateKeyframe(id, action, coalesce: AnyHashable([AnyHashable(id), AnyHashable(keyPath)])) {
                    $0[keyPath: keyPath] = value
                }
            })
    }

    var body: some View {
        Section("Selected zoom") {
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
            if keyframe.mode != .followMouse {
                ValueSlider(
                    title: "Target X", value: binding(\.target.x, "Zoom Target"), range: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) }, model: model)
                ValueSlider(
                    title: "Target Y", value: binding(\.target.y, "Zoom Target"), range: 0...1,
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
            if !keyframe.instant {
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
                Button("Duplicate") { model.duplicateKeyframe(keyframe.id) }
                Spacer()
                Button("Delete", role: .destructive) { model.deleteKeyframe(keyframe.id) }
            }
        }
    }
}
