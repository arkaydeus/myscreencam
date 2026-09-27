import ProjectKit
import SwiftUI

/// Settings › Defaults: the zoom and subtitle settings new recordings start with.
struct DefaultsSettingsView: View {
    @State private var store = ProjectDefaultsStore()

    var body: some View {
        Form {
            Section {
                Toggle("Zoom enabled", isOn: $store.defaults.zoomEnabled)
                Toggle("Create zooms from clicks", isOn: $store.defaults.autoZoom)
                    .help("New recordings start with a zoom on every left click")
                ValueSlider(
                    title: "Scale", value: $store.defaults.zoomTiming.scale, range: 1.1...4, step: 0.05,
                    format: { String(format: "%.2f×", $0) })
                ValueSlider(
                    title: "Ease in", value: $store.defaults.zoomTiming.easeIn, range: 0.05...1,
                    format: TimeFormat.seconds)
                ValueSlider(
                    title: "Hold", value: $store.defaults.zoomTiming.hold, range: 0.1...2, format: TimeFormat.seconds)
                ValueSlider(
                    title: "Ease out", value: $store.defaults.zoomTiming.easeOut, range: 0.05...1,
                    format: TimeFormat.seconds)
            } header: {
                Text("Zoom")
            } footer: {
                Text("Zooms created from clicks and zooms you add use this scale and timing.")
                    .font(.caption)
                    .foregroundStyle(Color.themeSecondaryText)
            }

            Section("Subtitles") {
                Toggle("Show subtitles", isOn: $store.defaults.subtitlesEnabled)
                SubtitleStyleControls(source: store)
                    .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Built-in Defaults") { store.resetToBuiltIn() }
                        .disabled(store.defaults == ProjectDefaults())
                }
            } footer: {
                Text(
                    "Recordings take these settings when they're first opened, exported or transcribed. Recordings you've already edited keep their own settings."
                )
                .font(.caption)
                .foregroundStyle(Color.themeSecondaryText)
            }
        }
        .frame(height: 600)
    }
}
