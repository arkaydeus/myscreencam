import AppKit
import ExportKit
import ProjectKit
import SwiftUI

/// Export options + progress sheet, presented by the editor (`ExportSheet(package:edit:)`).
///
/// The export itself runs in `ExportCenter`, so closing the editor window doesn't stop it. The sheet can't be
/// dismissed while its export is running.
struct ExportSheet: View {
    let package: RecordingPackage
    let edit: EditConfig
    /// For a direct Library export, save the first edit only after a destination is chosen.
    let prepareEdit: (() throws -> EditConfig)?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var choice = ExportOptionsStore.load()
    @State private var info: RecordingInfo?
    @State private var job: ExportCenter.Job?
    @State private var errorMessage: String?
    @State private var isChoosingDestination = false
    @AppStorage("export.saveSubtitles") private var saveSubtitles = false

    private var hasSubtitles: Bool {
        edit.subtitles.enabled && edit.subtitles.cues.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// What the sheet needs from the package, loaded off the main actor.
    private nonisolated struct RecordingInfo: Sendable {
        var name: String
        var sourceSize: CGSize
        var hasAudibleAudio: Bool
    }

    init(package: RecordingPackage, edit: EditConfig, prepareEdit: (() throws -> EditConfig)? = nil) {
        self.package = package
        self.edit = edit
        self.prepareEdit = prepareEdit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color.themePanelBorder)
                .frame(height: 1)
            Group {
                switch job?.state {
                case .queued?, .preparing?, .running?:
                    if let job { progressView(job) }
                case .succeeded(let result)?:
                    successView(result)
                default:
                    optionsView
                }
            }
            .padding(20)
        }
        .frame(width: 480)
        .toggleStyle(.switch)
        .themedWindow()
        .interactiveDismissDisabled(job?.isActive == true)
        .task { await load() }
        .onChange(of: choice) { _, newValue in ExportOptionsStore.save(newValue) }
        .onChange(of: job?.state) { _, state in
            switch state {
            case .failed(let message)?:
                errorMessage = message
            case .cancelled?:
                errorMessage = nil
            default:
                break
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.themeOnAccent)
                .frame(width: 32, height: 32)
                .background(Color.themeAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.themeAccent.opacity(0.3), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export").font(.system(size: 17, weight: .bold))
                Text(info?.name ?? package.url.deletingPathExtension().lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(Color.themeSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: options

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            presetPicker
            // A grid rather than a `.columns` Form: the form sized its label column to the longest label and pushed
            // the rows wider than the sheet. Short labels keep every row inside the sheet's padding.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                optionRow("Format") {
                    Picker("Format", selection: formatBinding) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                optionRow("Quality") {
                    Picker("Quality", selection: $choice.settings.quality) {
                        ForEach(ExportQuality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!usesQuality)
                    .help(usesQuality ? "" : "\(choice.settings.format.displayName) doesn't use a quality setting.")
                }
                optionRow("Frame rate") {
                    Picker("Frame rate", selection: $choice.settings.frameRate) {
                        ForEach(choice.frameRateChoices, id: \.self) { Text("\($0.framesPerSecond) fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                optionRow("Resolution") {
                    Picker("Resolution", selection: $choice.settings.scale) {
                        ForEach(ExportScale.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if choice.settings.format != .gif {
                    optionRow("Audio") {
                        Toggle("Include audio", isOn: $choice.settings.includesAudio)
                            .labelsHidden()
                            .disabled(info?.hasAudibleAudio == false)
                            .help(
                                info?.hasAudibleAudio == false
                                    ? "This recording has no audible audio." : "Include the audio in the export")
                    }
                }
                if hasSubtitles {
                    optionRow("Subtitles") {
                        HStack(spacing: 8) {
                            Toggle("Also save subtitles (.srt)", isOn: $saveSubtitles)
                                .labelsHidden()
                            Text("Also save an .srt file")
                                .foregroundStyle(Color.themeSecondaryText)
                        }
                        .help("Subtitles are burned into the video; this also writes them as a SubRip file beside it.")
                    }
                }
            }

            summary

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.themeDestructive)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { Task { await chooseDestinationAndExport() } }
                    .buttonStyle(.themedPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(info == nil || isChoosingDestination)
            }
        }
    }

    /// One options row: a right-aligned label and its control.
    private func optionRow(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        GridRow(alignment: .center) {
            Text(title)
                .gridColumnAlignment(.trailing)
            control()
        }
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Preset", selection: presetBinding) {
                ForEach(ExportPreset.allCases) { preset in
                    Text(preset.displayName).tag(Optional(preset))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                if let preset = choice.preset {
                    Text(choice.isUnmodifiedPreset ? preset.summary : "\(preset.summary) · adjusted")
                } else {
                    Text("Custom settings")
                }
            }
            .font(.caption)
            .foregroundStyle(Color.themeSecondaryText)
        }
    }

    private var summary: some View {
        let settings = effectiveSettings
        return VStack(alignment: .leading, spacing: 4) {
            if let sizing {
                LabeledContent("Output") {
                    Text(
                        "\(Int(sizing.renderSize.width)) × \(Int(sizing.renderSize.height)) · "
                            + "\(settings.effectiveFrameRate.framesPerSecond) fps · \(settings.format.displayName) "
                            + ".\(settings.fileExtension)"
                    )
                    .monospacedDigit()
                }
                LabeledContent("Estimated size") {
                    Text("≈ \(estimatedSizeText(sizing))").monospacedDigit()
                }
            } else {
                LabeledContent("Output") { ProgressView().controlSize(.small) }
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel(.themeStage, cornerRadius: AppTheme.controlRadius + 2)
    }

    // MARK: progress

    private func progressView(_ job: ExportCenter.Job) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(job.stageText)
                Spacer()
                Text(job.fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(Color.themeAccent)
            }
            ProgressView(value: job.fraction)
                .progressViewStyle(.linear)
            HStack {
                Text(timeRemainingText(job) ?? " ")
                    .font(.caption)
                    .foregroundStyle(Color.themeSecondaryText)
                Spacer()
                Button("Cancel") { job.cancel() }
                    .buttonStyle(.themed)
            }
            Text(abbreviatedPath(job.destination))
                .font(.caption)
                .foregroundStyle(Color.themeTertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: success

    private func successView(_ result: ExportResult) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.themeAccent)
                .shadow(color: Color.themeAccent.opacity(0.35), radius: 12)
            Text("Export Complete").font(.title3.weight(.semibold))
            Text(abbreviatedPath(result.url))
                .font(.callout)
                .foregroundStyle(Color.themeSecondaryText)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Text(
                "\(Int(result.dimensions.width)) × \(Int(result.dimensions.height)) · "
                    + ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file)
            )
            .font(.caption)
            .foregroundStyle(Color.themeTertiaryText)
            .monospacedDigit()
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                    .buttonStyle(.themed)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.themedPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: derived values

    private var usesQuality: Bool {
        switch choice.settings.format {
        case .h264, .hevc, .hevc10bit: true
        case .proRes422, .gif: false
        }
    }

    /// The settings as they will be encoded (audio off when nothing is audible).
    private var effectiveSettings: ExportSettings {
        var settings = choice.settings
        if info?.hasAudibleAudio == false { settings.includesAudio = false }
        return settings
    }

    private var sizing: ExportSizing? {
        guard let info else { return nil }
        return ExportSizing.plan(
            sourceSize: info.sourceSize, crop: edit.crop, background: edit.background, settings: effectiveSettings)
    }

    private var editedDuration: Double { EditTimeline(segments: edit.segments).duration }

    private func estimatedSizeText(_ sizing: ExportSizing) -> String {
        let settings = effectiveSettings
        let bytes = ExportPipeline.estimatedFileSize(
            settings: settings, outputSize: sizing.renderSize, duration: editedDuration,
            hasAudio: settings.includesAudio)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func timeRemainingText(_ job: ExportCenter.Job) -> String? {
        guard case .running(let progress) = job.state, let remaining = progress.estimatedTimeRemaining else {
            return nil
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = remaining >= 60 ? [.minute, .second] : [.second]
        return formatter.string(from: max(1, remaining.rounded())).map { "About \($0) left" }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private var presetBinding: Binding<ExportPreset?> {
        Binding(
            get: { choice.preset },
            set: { preset in
                if let preset { choice.apply(preset) }
            })
    }

    private var formatBinding: Binding<ExportFormat> {
        Binding(get: { choice.settings.format }, set: { choice.setFormat($0) })
    }

    // MARK: actions

    private func load() async {
        if let running = model.exports.activeJob(for: package) { job = running }
        guard info == nil else { return }
        let package = package
        let edit = edit
        let loaded = await Self.loadInfo(package: package, edit: edit)
        info = loaded
    }

    @concurrent
    private static func loadInfo(package: RecordingPackage, edit: EditConfig) async -> RecordingInfo {
        let meta = try? package.loadMeta()
        let streams = package.availableStreams()
        let audible =
            (streams.contains(.systemAudio) && edit.audio.system.isAudible)
            || (streams.contains(.microphone) && edit.audio.microphone.isAudible)
        let sourceSize: CGSize
        if let meta {
            sourceSize = await ExportPipeline.sourceSize(of: package, meta: meta)
        } else {
            sourceSize = CGSize(width: 1920, height: 1080)
        }
        return RecordingInfo(
            name: meta?.name ?? package.url.deletingPathExtension().lastPathComponent,
            sourceSize: sourceSize, hasAudibleAudio: audible)
    }

    private func chooseDestinationAndExport() async {
        guard let info, !isChoosingDestination else { return }
        isChoosingDestination = true
        defer { isChoosingDestination = false }
        let settings = effectiveSettings
        do {
            try settings.validate()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Recording"
        panel.prompt = "Export"
        panel.allowedContentTypes = [settings.container.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(Self.fileName(for: info.name)).\(settings.fileExtension)"
        panel.directoryURL =
            ExportOptionsStore.lastDirectory()
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        let exportEdit: EditConfig
        do {
            exportEdit = try prepareEdit?() ?? edit
        } catch {
            errorMessage = "Couldn't save the recording's initial edits: \(error.localizedDescription)"
            return
        }
        ExportOptionsStore.rememberDirectory(of: url)

        errorMessage = nil
        let subtitles =
            exportEdit.subtitles.enabled && saveSubtitles
                && exportEdit.subtitles.cues.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            ? SubtitleExport.srt(cues: exportEdit.subtitles.cues, timeline: EditTimeline(segments: exportEdit.segments))
            : nil
        job = model.exports.start(
            package: package, name: info.name, edit: exportEdit, settings: settings, destination: url,
            subtitleSidecar: subtitles)
    }

    /// A file name for the recording's display name: path separators and colons replaced.
    static func fileName(for name: String) -> String {
        let cleaned =
            name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Recording" : cleaned
    }
}
