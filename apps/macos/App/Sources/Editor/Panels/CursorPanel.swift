import ProjectKit
import SwiftUI

struct CursorPanel: View {
    let model: EditorModel

    private enum StyleKind: String, CaseIterable, Identifiable {
        case system, stylised, fixed
        var id: Self { self }
        var title: String {
            switch self {
            case .system: "System"
            case .stylised: "Stylised"
            case .fixed: "Fixed"
            }
        }
    }

    private var styleKind: Binding<StyleKind> {
        Binding(
            get: {
                switch model.edit.cursor.style {
                case .system: .system
                case .stylised: .stylised
                case .fixed: .fixed
                }
            },
            set: { kind in
                let style: CursorStyle =
                    switch kind {
                    case .system: .system
                    case .stylised: .stylised
                    case .fixed: .fixed(fixedKind.wrappedValue)
                    }
                model.update("Cursor Style") { $0.cursor.style = style }
            })
    }

    private var fixedKind: Binding<CursorKind> {
        Binding(
            get: {
                if case .fixed(let kind) = model.edit.cursor.style { return kind }
                return .arrow
            },
            set: { kind in model.update("Cursor Style") { $0.cursor.style = .fixed(kind) } })
    }

    private var trailLength: Binding<Double> {
        Binding(
            get: { Double(model.edit.cursor.dragTrail.length) },
            set: { value in
                let length = Int(value.rounded())
                guard length != model.edit.cursor.dragTrail.length else { return }
                model.update("Trail Length", coalesce: "trailLength") { $0.cursor.dragTrail.length = length }
            })
    }

    var body: some View {
        Form {
            if !model.meta.systemCursorHidden {
                Section {
                    Label {
                        Text(
                            "The system cursor was recorded into the video, so it can't be restyled. Turn on "
                                + "“Custom Cursor” when recording to edit the cursor here.")
                    } icon: {
                        Image(systemName: "cursorarrow.slash")
                    }
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
            }
            Group {
                Section {
                    Toggle("Show cursor", isOn: model.binding(\.cursor.enabled, "Toggle Cursor"))
                    Picker("Style", selection: styleKind) {
                        ForEach(StyleKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if case .fixed = model.edit.cursor.style {
                        Picker("Cursor", selection: fixedKind) {
                            ForEach(CursorKind.allCases.filter { $0 != .other }, id: \.self) { kind in
                                Text(Self.name(kind)).tag(kind)
                            }
                        }
                    }
                    Picker("Size", selection: model.binding(\.cursor.size, "Cursor Size")) {
                        Text("S").tag(CursorSize.small)
                        Text("M").tag(CursorSize.medium)
                        Text("L").tag(CursorSize.large)
                    }
                    .pickerStyle(.segmented)
                    Picker("Smoothing", selection: model.binding(\.cursor.smoothing, "Cursor Smoothing")) {
                        Text("None").tag(CursorSmoothing.none)
                        Text("Rapid").tag(CursorSmoothing.rapid)
                        Text("Medium").tag(CursorSmoothing.medium)
                        Text("Slow").tag(CursorSmoothing.slow)
                    }
                }

                Section {
                    Toggle("Hide when idle", isOn: model.binding(\.cursor.hideWhenIdle, "Hide Idle Cursor"))
                    if model.edit.cursor.hideWhenIdle {
                        ValueSlider(
                            title: "After", value: model.binding(\.cursor.idleDelay, "Idle Delay"), range: 0.5...10,
                            step: 0.5, format: { String(format: "%.1f s", $0) }, model: model)
                    }
                    Toggle("Click pulse", isOn: model.binding(\.cursor.clickPulse, "Click Pulse"))
                }

                Section("Click highlight") {
                    Toggle("Highlight clicks", isOn: model.binding(\.cursor.clickHighlight.enabled, "Click Highlight"))
                    ColorPicker(
                        "Colour", selection: model.colorBinding(\.cursor.clickHighlight.color, "Highlight Colour"))
                    ValueSlider(
                        title: "Radius", value: model.binding(\.cursor.clickHighlight.radius, "Highlight Radius"),
                        range: EditLimits.clickHighlightRadius, step: 1, format: { String(format: "%.0f pt", $0) },
                        model: model)
                    ValueSlider(
                        title: "Duration",
                        value: model.binding(\.cursor.clickHighlight.duration, "Highlight Duration"),
                        range: EditLimits.clickHighlightDuration, format: TimeFormat.seconds, model: model)
                }

                Section("Drag trail") {
                    Toggle("Show trail while dragging", isOn: model.binding(\.cursor.dragTrail.enabled, "Drag Trail"))
                    ValueSlider(
                        title: "Length", value: trailLength,
                        range: Double(
                            EditLimits.dragTrailLength.lowerBound)...Double(
                                EditLimits.dragTrailLength.upperBound), step: 1, format: { String(format: "%.0f", $0) },
                        model: model)
                    ValueSlider(
                        title: "Opacity", value: model.binding(\.cursor.dragTrail.opacity, "Trail Opacity"),
                        range: 0...1, format: { String(format: "%.0f%%", $0 * 100) }, model: model)
                }
            }
            .disabled(!model.meta.systemCursorHidden)
        }
    }

    static func name(_ kind: CursorKind) -> String {
        switch kind {
        case .arrow: "Arrow"
        case .pointingHand: "Pointing hand"
        case .iBeam: "I-beam"
        case .crosshair: "Crosshair"
        case .openHand: "Open hand"
        case .closedHand: "Closed hand"
        case .resizeLeftRight: "Resize left/right"
        case .resizeUpDown: "Resize up/down"
        case .resizeDiagonal: "Resize diagonal"
        case .operationNotAllowed: "Not allowed"
        case .dragCopy: "Drag copy"
        case .contextualMenu: "Contextual menu"
        case .other: "Other"
        }
    }
}
