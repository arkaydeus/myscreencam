import AppKit
import MyScreenArtCore
import SwiftUI

/// Settings window (⌘,): General, Subtitles and Updates.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettingsView() }
            Tab("Subtitles", systemImage: "captions.bubble") { SubtitleSettingsView() }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath") { UpdateSettingsView() }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppShell.self) private var shell
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var settings = shell.settings
        Form {
            Section {
                Toggle("Hide Dock icon when idle", isOn: $settings.hideDockIconWhenIdle)
                Toggle(
                    "Launch at login",
                    isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                if let message = settings.launchAtLoginMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Recordings") {
                LabeledContent("Folder") {
                    switch environment.recordingsRoot {
                    case .success(let url):
                        HStack {
                            Text(url.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(.red)
                    }
                }
            }

            Section {
                Toggle("Global keyboard shortcuts", isOn: $settings.globalHotkeysEnabled)
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("⌥⌘↩ opens a new recording and ⌥⇧⌘R finishes the current one, from any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLogin()
        }
    }
}

private struct UpdateSettingsView: View {
    @Environment(AppShell.self) private var shell

    var body: some View {
        @Bindable var updates = shell.updates
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                    .disabled(!updates.isConfigured)
                LabeledContent("Last checked") {
                    Text(updates.lastUpdateCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                }
                HStack {
                    Spacer()
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            } footer: {
                if !updates.isConfigured {
                    Text("Updates are unavailable in this build (no update signing key).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}
