import SpeechCore
import SwiftUI

/// Settings › Subtitles: choose a speech engine (downloading its models only after confirmation), follow the
/// download, remove models, and set the language and automatic transcription.
struct SubtitleSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming: SpeechEngine?

    private var transcription: TranscriptionCenter { app.transcription }
    private var models: SpeechModels { transcription.models }

    var body: some View {
        @Bindable var settings = transcription.settings
        Form {
            Section {
                EngineRow(engine: nil, selected: settings.engine == nil) { settings.engine = nil }
                ForEach(SpeechEngine.allCases) { engine in
                    EngineRow(engine: engine, selected: settings.engine == engine) { choose(engine) }
                }
            } header: {
                Text("Speech engine")
            } footer: {
                Text(
                    "Transcription runs entirely on this Mac. Models are downloaded from Hugging Face only when you "
                        + "choose an engine, and are stored in Application Support."
                )
                .font(.caption)
                .foregroundStyle(Color.themeSecondaryText)
            }

            if let engine = settings.engine {
                Section("Options") {
                    Picker("Language", selection: $settings.language) {
                        Text("Automatic").tag(String?.none)
                        Divider()
                        ForEach(LanguageCapabilities.languages(for: engine).sorted { $0.displayName < $1.displayName })
                        {
                            language in
                            Text(language.displayName).tag(String?.some(language.tag))
                        }
                    }
                    if engine == .qwen, let language = settings.language,
                        !LanguageCapabilities.hasFineTiming(language, engine: .qwen)
                    {
                        Text("Word timing isn't available for this language: subtitle timing will be approximate.")
                            .font(.caption)
                            .foregroundStyle(Color.themeWarning)
                    }
                    Toggle("Transcribe new recordings automatically", isOn: $settings.autoTranscribe)
                }
            }

            if let error = models.lastError {
                Section { Text(error).foregroundStyle(Color.themeDestructive).font(.callout) }
            }

            let installed = SpeechEngine.allCases.filter { models.isInstalled($0) }
            if !installed.isEmpty {
                Section("Model licences") {
                    ForEach(installed) { engine in
                        ForEach(models.catalogue.manifests(for: engine)) { manifest in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(manifest.repository) — \(manifest.license)").font(.caption.weight(.medium))
                                Text(manifest.attribution).font(.caption).foregroundStyle(Color.themeSecondaryText)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 540)
        .alert(
            "Download \(confirming?.title ?? "")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { engine in
            Button("Download \(size(of: engine))") {
                settings.engine = engine
                models.install(engine)
            }
            Button("Cancel", role: .cancel) {}
        } message: { engine in
            Text(downloadMessage(engine))
        }
    }

    private func choose(_ engine: SpeechEngine) {
        if models.isInstalled(engine) || models.state(of: engine).isBusy {
            transcription.settings.engine = engine
        } else {
            confirming = engine
        }
    }

    private func size(of engine: SpeechEngine) -> String {
        ByteCountFormatter.string(fromByteCount: models.downloadBytes(for: engine), countStyle: .file)
    }

    private func downloadMessage(_ engine: SpeechEngine) -> String {
        let manifests = models.catalogue.manifests(for: engine)
        let parts = manifests.map {
            "\($0.repository) (\(ByteCountFormatter.string(fromByteCount: $0.totalBytes, countStyle: .file)))"
        }
        return "\(size(of: engine)) will be downloaded and stored on this Mac: \(parts.joined(separator: ", ")). "
            + "Transcription then works offline."
    }
}

/// One choice in the engine list, with its install state and actions.
private struct EngineRow: View {
    let engine: SpeechEngine?
    let selected: Bool
    let select: () -> Void
    @Environment(AppModel.self) private var app

    private var models: SpeechModels { app.transcription.models }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.themeAccent : Color.themeSecondaryText)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.body.weight(.medium))
                        Text(summary).font(.caption).foregroundStyle(Color.themeSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let engine {
                status(engine).padding(.leading, 32)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch engine {
        case nil: "Off"
        case .parakeet?: "Parakeet Ultra — Default"
        case .qwen?: "Qwen — Multilingual"
        }
    }

    private var summary: String {
        guard let engine else { return "No subtitles are generated and nothing is downloaded." }
        let size = ByteCountFormatter.string(fromByteCount: models.downloadBytes(for: engine), countStyle: .file)
        return "\(engine.summary) \(size)."
    }

    @ViewBuilder private func status(_ engine: SpeechEngine) -> some View {
        switch models.state(of: engine) {
        case .notInstalled:
            EmptyView()
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress.fraction)
                HStack {
                    Text(DownloadText.describe(progress)).font(.caption).monospacedDigit().foregroundStyle(
                        Color.themeSecondaryText)
                    Spacer()
                    Button("Cancel") { models.cancel(engine) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        case .verifying(let fraction):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: fraction)
                Text("Verifying…").font(.caption).foregroundStyle(Color.themeSecondaryText)
            }
        case .installed:
            HStack {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.themeAccent)
                Spacer()
                Button("Remove") { Task { await models.remove(engine) } }
                    .font(.caption)
                    .disabled(app.transcription.isTranscribing)
            }
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.themeWarning)
                    .lineLimit(2)
                Spacer()
                Button("Retry") { models.install(engine) }
                    .font(.caption)
            }
        case .removing:
            Text("Removing…").font(.caption).foregroundStyle(Color.themeSecondaryText)
        }
    }
}

enum DownloadText {
    /// "312 MB of 632 MB · 12.4 MB/s · about 26 s left"
    static func describe(_ progress: DownloadProgress) -> String {
        let done = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        var parts = ["\(done) of \(total)"]
        if let rate = progress.bytesPerSecond {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s")
        }
        if let remaining = progress.secondsRemaining {
            parts.append("about \(duration(remaining)) left")
        } else {
            parts.append("estimating time…")
        }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds.rounded())) ?? "\(Int(seconds)) s"
    }
}
