import AppKit
import ProjectKit
import SwiftUI

/// Where the subtitle style controls read and write: the open recording (undoable edits) or the defaults for new
/// recordings.
@MainActor
protocol SubtitleStyleSource: AnyObject {
    var subtitleSettings: SubtitleSettings { get }
    /// Cues the style applies to (for notes about them); empty for the defaults.
    var subtitleCues: [SubtitleCue] { get }
    func subtitleBinding<V: Equatable>(_ keyPath: WritableKeyPath<SubtitleSettings, V>, _ action: String) -> Binding<V>
    func subtitleColorBinding(
        _ keyPath: WritableKeyPath<SubtitleSettings, RGBAColor>, _ action: String
    ) -> Binding<Color>
    /// A slider drag started or ended.
    func editingChanged(_ editing: Bool)
}

extension EditorModel: SubtitleStyleSource {
    var subtitleSettings: SubtitleSettings { edit.subtitles }
    var subtitleCues: [SubtitleCue] { edit.subtitles.cues }

    private static let subtitles: WritableKeyPath<EditConfig, SubtitleSettings> = \.subtitles

    func subtitleBinding<V: Equatable>(_ keyPath: WritableKeyPath<SubtitleSettings, V>, _ action: String) -> Binding<V>
    {
        binding(Self.subtitles.appending(path: keyPath), action)
    }

    func subtitleColorBinding(
        _ keyPath: WritableKeyPath<SubtitleSettings, RGBAColor>, _ action: String
    ) -> Binding<Color> {
        colorBinding(Self.subtitles.appending(path: keyPath), action)
    }
}

private let percentFormat: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
private let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

/// Drop shadow: direction, depth (distance), blur, colour and opacity.
struct SubtitleShadowControls<Source: SubtitleStyleSource>: View {
    let source: Source

    private var shadow: SubtitleShadow { source.subtitleSettings.style.shadow }

    var body: some View {
        HStack {
            Toggle("Shadow", isOn: source.subtitleBinding(\.style.shadow.enabled, "Subtitle Shadow"))
            Spacer()
            ColorPicker("", selection: source.subtitleColorBinding(\.style.shadow.color, "Shadow Colour"))
                .labelsHidden()
                .disabled(!shadow.enabled)
        }
        if shadow.enabled {
            ValueSlider(
                title: "Angle", value: source.subtitleBinding(\.style.shadow.angle, "Shadow Angle"), range: 0...360,
                step: 1, format: { String(format: "%.0f°", $0) }, onEditingChanged: source.editingChanged
            )
            .help("Direction the shadow falls (90° is straight down)")
            ValueSlider(
                title: "Depth", value: source.subtitleBinding(\.style.shadow.distance, "Shadow Depth"),
                range: EditLimits.subtitleShadowDistance, step: 0.01, format: percentFormat,
                onEditingChanged: source.editingChanged
            )
            .help("How far the shadow falls, as a share of the font size")
            ValueSlider(
                title: "Blur", value: source.subtitleBinding(\.style.shadow.blur, "Shadow Blur"),
                range: EditLimits.subtitleShadowBlur, step: 0.01, format: percentFormat,
                onEditingChanged: source.editingChanged)
            ValueSlider(
                title: "Opacity", value: source.subtitleBinding(\.style.shadow.opacity, "Shadow Opacity"),
                range: 0...1, step: 0.01, format: percentFormat, onEditingChanged: source.editingChanged)
        }
    }
}

struct SubtitleStyleControls<Source: SubtitleStyleSource>: View {
    let source: Source

    private var style: SubtitleStyle { source.subtitleSettings.style }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Font") {
                Picker("Font", selection: source.subtitleBinding(\.style.fontFamily, "Subtitle Font")) {
                    Text("System").tag(String?.none)
                    Divider()
                    ForEach(fontFamilies, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }
            HStack(spacing: 8) {
                Toggle(isOn: source.subtitleBinding(\.style.bold, "Bold Subtitles")) {
                    Image(systemName: "bold")
                }
                .toggleStyle(.button)
                .help("Bold")
                Toggle(isOn: source.subtitleBinding(\.style.italic, "Italic Subtitles")) {
                    Image(systemName: "italic")
                }
                .toggleStyle(.button)
                .help("Italic")
                Toggle("Uppercase", isOn: source.subtitleBinding(\.style.uppercase, "Uppercase Subtitles"))
                    .toggleStyle(.button)
                    .help("Show all subtitle text in capitals")
                Spacer()
                ColorPicker("Text", selection: source.subtitleColorBinding(\.style.textColor, "Subtitle Colour"))
            }
            HStack {
                Toggle(
                    "Highlight spoken word",
                    isOn: source.subtitleBinding(\.style.highlightWords, "Word Highlight"))
                Spacer()
                ColorPicker("", selection: source.subtitleColorBinding(\.style.highlightColor, "Highlight Colour"))
                    .labelsHidden()
                    .disabled(!style.highlightWords)
            }
            .help("Colour each word as it's spoken")
            if style.highlightWords, !source.subtitleCues.isEmpty,
                !source.subtitleCues.contains(where: { !$0.words.isEmpty })
            {
                Text("No word timing in these subtitles (approximate or typed by hand), so no words are highlighted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if style.highlightWords {
                ValueSlider(
                    title: "Grow", value: source.subtitleBinding(\.style.highlightGrow, "Highlight Grow"),
                    range: EditLimits.subtitleHighlightGrow, step: 0.01,
                    format: { $0 == 0 ? "Off" : String(format: "+%.0f%%", $0 * 100) },
                    onEditingChanged: source.editingChanged
                )
                .help("How much bigger the spoken word is drawn")
            }
            ValueSlider(
                title: "Size", value: source.subtitleBinding(\.style.size, "Subtitle Size"),
                range: EditLimits.subtitleSize, step: 0.0025, format: { String(format: "%.1f%%", $0 * 100) },
                onEditingChanged: source.editingChanged)
            ValueSlider(
                title: "Width", value: source.subtitleBinding(\.style.maxWidth, "Subtitle Width"),
                range: EditLimits.subtitleMaxWidth, step: 0.01, format: { String(format: "%.0f%%", $0 * 100) },
                onEditingChanged: source.editingChanged
            )
            .help("Widest line, as a share of the video width; longer text wraps onto the next line")
            HStack(alignment: .bottom, spacing: 10) {
                ValueSlider(
                    title: "Outline", value: source.subtitleBinding(\.style.outlineWidth, "Subtitle Outline"),
                    range: EditLimits.subtitleOutline, step: 0.01,
                    format: { $0 == 0 ? "Off" : String(format: "%.0f%%", $0 * 100) },
                    onEditingChanged: source.editingChanged)
                ColorPicker("", selection: source.subtitleColorBinding(\.style.outlineColor, "Outline Colour"))
                    .labelsHidden()
                    .disabled(style.outlineWidth == 0)
            }
            HStack {
                Toggle("Background", isOn: source.subtitleBinding(\.style.background, "Subtitle Background"))
                Spacer()
                ColorPicker("", selection: source.subtitleColorBinding(\.style.backgroundColor, "Background Colour"))
                    .labelsHidden()
                    .disabled(!style.background)
            }
            if style.background {
                ValueSlider(
                    title: "Opacity", value: source.subtitleBinding(\.style.backgroundOpacity, "Background Opacity"),
                    range: 0...1, step: 0.01, format: { String(format: "%.0f%%", $0 * 100) },
                    onEditingChanged: source.editingChanged)
            }
            SubtitleShadowControls(source: source)
            Divider()
            Picker("Position", selection: source.subtitleBinding(\.placement.anchor, "Subtitle Position")) {
                Text("Top").tag(SubtitlePlacement.Anchor.top)
                Text("Middle").tag(SubtitlePlacement.Anchor.middle)
                Text("Bottom").tag(SubtitlePlacement.Anchor.bottom)
            }
            .pickerStyle(.segmented)
            if source.subtitleSettings.placement.anchor != .middle {
                ValueSlider(
                    title: "Margin", value: source.subtitleBinding(\.placement.margin, "Subtitle Margin"),
                    range: EditLimits.subtitleMargin, step: 0.005, format: { String(format: "%.1f%%", $0 * 100) },
                    onEditingChanged: source.editingChanged)
            }
        }
    }
}
