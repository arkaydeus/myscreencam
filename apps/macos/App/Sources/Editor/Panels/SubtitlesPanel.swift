import AppKit
import ProjectKit
import SpeechCore
import SwiftUI

/// The Subtitles tab: transcription status, style and default position at the top, then a scrolling list of timed
/// cues. Clicking a cue selects it (pausing at it) and opens it for editing.
struct SubtitlesPanel: View {
    @Bindable var model: EditorModel
    @Environment(AppModel.self) private var app
    @AppStorage("subtitles.styleExpanded") private var styleExpanded = true
    @State private var tracker = ActiveCueTracker()
    @FocusState private var searchFocused: Bool

    private var settings: SubtitleSettings { model.edit.subtitles }
    private var job: TranscriptionCenter.Job? { app.transcription.job(for: model.package.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusSection(model: model, job: job)
            if model.edit.subtitles.candidateRevisionID != nil { CandidateBanner(model: model) }
            DisclosureGroup(isExpanded: $styleExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    SubtitleStyleControls(source: model)
                    CuePositionNotes(model: model)
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    Text("Style & Position").font(.headline)
                    Spacer()
                    Toggle("Show", isOn: model.binding(\.subtitles.enabled, "Show Subtitles"))
                        .labelsHidden()
                        .help("Show subtitles in the preview and export")
                }
            }
            Divider()
            listHeader
            cueList
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { tracker.start(model) }
        .onDisappear { tracker.stop(model) }
        .sheet(item: $model.pendingMerge.optionalIdentity) { _ in ConflictSheet(model: model) }
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
    }

    // MARK: List

    private var listHeader: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search subtitles", text: $model.subtitleSearch)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { model.jumpToMatch(forward: !NSEvent.modifierFlags.contains(.shift)) }
                if !model.subtitleSearch.isEmpty {
                    Text("\(model.subtitleMatches.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button {
                        model.subtitleSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.themeControlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Button {
                model.addCueAtPlayhead()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a subtitle at the playhead")
        }
    }

    private var cueList: some View {
        let matches = Set(model.subtitleMatches)
        let searching = !model.subtitleSearch.trimmingCharacters(in: .whitespaces).isEmpty
        let selected = model.selectedCueIDs
        let editing = model.selectedCue?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if settings.cues.isEmpty {
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(settings.cues) { cue in
                        CueRow(
                            model: model, cue: cue, isSelected: selected.contains(cue.id), isEditing: editing == cue.id,
                            isActive: tracker.activeID == cue.id, isMatch: searching && matches.contains(cue.id),
                            isCut: model.timeline.editedTime(forSource: cue.start) == nil
                                && model.timeline.editedTime(forSource: cue.end) == nil
                        )
                        .id(cue.id)
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: tracker.activeID) { _, id in
                guard let id, model.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.selection) { _, selection in
                if case .cues(let ids) = selection, ids.count == 1, let id = ids.first {
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var emptyText: String {
        if job?.isActive == true { return "Subtitles appear here when transcription finishes." }
        return "No subtitles yet."
    }
}

// MARK: - Status

private struct StatusSection: View {
    let model: EditorModel
    let job: TranscriptionCenter.Job?
    @Environment(AppModel.self) private var app

    private var transcription: TranscriptionCenter { app.transcription }

    var body: some View {
        if let job, job.isActive {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.statusText).font(.callout)
                    Spacer()
                    Button("Cancel") { transcription.cancel(model.package.url) }
                        .buttonStyle(.link)
                }
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        } else if case .failed(let message)? = job?.phase {
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Button("Try Again") { transcription.transcribe(model.package.url) }
                    .disabled(!transcription.isAvailable)
            }
        } else if model.edit.subtitles.cues.isEmpty {
            if transcription.isAvailable {
                Button {
                    transcription.transcribe(model.package.url)
                } label: {
                    Label("Generate Subtitles", systemImage: "waveform.badge.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose a speech engine in Settings to generate subtitles on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("Open Subtitle Settings…") }
                }
            }
        } else {
            HStack(spacing: 8) {
                transcriptSummary
                Spacer()
                Menu {
                    ForEach(SpeechEngine.allCases) { engine in
                        Button("Regenerate with \(engine.title)") {
                            transcription.transcribe(model.package.url, engine: engine)
                        }
                        .disabled(!transcription.models.isInstalled(engine))
                    }
                    if model.recordedStreams.contains(.microphone) && model.recordedStreams.contains(.systemAudio) {
                        Divider()
                        Picker("Audio", selection: audioSource) {
                            Text("Microphone").tag(TranscriptAudioSource.microphone)
                            Text("System Audio").tag(TranscriptAudioSource.systemAudio)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Regenerate subtitles")
                .accessibilityLabel("Regenerate subtitles")
            }
        }
    }

    private var audioSource: Binding<TranscriptAudioSource> {
        Binding(
            get: { model.edit.subtitles.audioSource ?? .microphone },
            set: { value in model.update("Subtitle Audio Source") { $0.subtitles.audioSource = value } })
    }

    @ViewBuilder private var transcriptSummary: some View {
        let cues = model.edit.subtitles.cues
        VStack(alignment: .leading, spacing: 2) {
            Text(cues.count == 1 ? "1 subtitle" : "\(cues.count) subtitles").font(.callout)
            if let transcript = model.transcript {
                Text(engineName(transcript) + (transcript.status == .partial ? " · some parts missing" : ""))
                    .font(.caption)
                    .foregroundStyle(transcript.status == .partial ? .orange : .secondary)
            }
            if cues.contains(where: \.coarse) {
                Text("Some timing is approximate for this language.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func engineName(_ transcript: TranscriptRevision) -> String {
        SpeechEngine(rawValue: transcript.options.engine)?.title ?? transcript.options.engine
    }
}

private struct CandidateBanner: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("A new transcript is ready", systemImage: "sparkles")
                .font(.callout.weight(.semibold))
            Text("Your edits are kept where the words haven't changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Use New Transcript") { model.adoptCandidate() }
                    .disabled(model.candidateTranscript == nil)
                Button("Discard") { model.discardCandidate() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ConflictSheet: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resolve Changed Subtitles").font(.headline)
            Text("The new transcript heard something different where you edited these subtitles.")
                .font(.callout)
                .foregroundStyle(Color.themeSecondaryText)
            if let pending = model.pendingMerge {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(pending.conflicts) { conflict in
                            let keep = Binding(
                                get: { model.pendingMerge?.keep.contains(conflict.id) ?? false },
                                set: { on in
                                    if on {
                                        model.pendingMerge?.keep.insert(conflict.id)
                                    } else {
                                        model.pendingMerge?.keep.remove(conflict.id)
                                    }
                                })
                            VStack(alignment: .leading, spacing: 4) {
                                Text(TimeFormat.clock(conflict.mine.start)).font(.caption).monospacedDigit()
                                Picker("", selection: keep) {
                                    Text("Yours: \(conflict.mine.text)").tag(true)
                                    Text("New: \(conflict.newText.isEmpty ? "(nothing)" : conflict.newText)").tag(false)
                                }
                                .pickerStyle(.radioGroup)
                                .labelsHidden()
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingMerge = nil }
                    .buttonStyle(.themed)
                Button("Use New Transcript") { model.finishPendingMerge() }
                    .buttonStyle(.themedPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .themedWindow()
    }
}

// MARK: - Style

/// Under the shared style controls: per-cue positions and how to move a cue.
private struct CuePositionNotes: View {
    let model: EditorModel

    var body: some View {
        let moved = model.edit.subtitles.cues.filter { $0.position != nil }.count
        if moved > 0 {
            HStack {
                Text(moved == 1 ? "1 subtitle has its own position" : "\(moved) subtitles have their own position")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.resetAllCuePositions() }
                    .controlSize(.small)
            }
        }
        Text(
            "Drag a subtitle in the preview (while paused) to move just that one, or drag its left or right edge to change its width."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Cue rows

/// Modifier taps change selection; a plain tap focuses a cue unless its editor is already open.
enum CueRowClick {
    static func handle(_ id: SubtitleCue.ID, flags: NSEvent.ModifierFlags, isEditing: Bool, model: EditorModel) {
        let modifier = SelectionModifier(flags)
        if modifier != .replace {
            model.selectCue(id, modifier)
        } else if !isEditing {
            model.focusCue(id)
        }
    }
}

private struct CueRow: View {
    let model: EditorModel
    let cue: SubtitleCue
    let isSelected: Bool
    /// The only selected cue: its row shows the editor.
    let isEditing: Bool
    let isActive: Bool
    let isMatch: Bool
    let isCut: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? Color.themeAccent : .secondary)
                if cue.coarse {
                    Image(systemName: "clock.badge.questionmark").font(.caption).foregroundStyle(.orange)
                        .help("Approximate timing")
                }
                if cue.position != nil {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.caption2)
                        .foregroundStyle(.secondary).help("Has its own position")
                }
                if cue.maxWidth != nil {
                    Image(systemName: "arrow.left.and.right").font(.caption2)
                        .foregroundStyle(.secondary).help("Has its own width")
                }
                if cue.isTextCorrected, cue.generatedText != nil {
                    Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary).help("Edited")
                }
                Spacer()
            }
            if isEditing {
                CueEditor(model: model, cue: cue)
            } else {
                Text(cue.text.isEmpty ? "Empty subtitle" : cue.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(cue.text.isEmpty ? .tertiary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .opacity(isCut && !isSelected ? 0.45 : 1)
        .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.themeAccent : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            CueRowClick.handle(cue.id, flags: NSEvent.modifierFlags, isEditing: isEditing, model: model)
        }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [.isButton])
        .accessibilityAction { model.focusCue(cue.id) }
        .help(isCut ? "This subtitle is inside a cut" : "")
    }

    private var background: Color {
        if isSelected { return Color.themeAccent.opacity(0.12) }
        if isMatch { return Color.yellow.opacity(0.18) }
        if isActive { return Color.themeAccent.opacity(0.07) }
        return Color.themeControlFill.opacity(0.5)
    }

    private var timeText: String {
        let start =
            model.timeline.editedTime(forSource: cue.start) ?? model.timeline.editedTimeSnapping(forSource: cue.start)
        let end = model.timeline.editedTime(forSource: cue.end) ?? model.timeline.editedTimeSnapping(forSource: cue.end)
        return "\(TimeFormat.clock(start)) – \(TimeFormat.clock(end))"
    }
}

/// The selected cue: its text, timing, position and transcript actions.
private struct CueEditor: View {
    let model: EditorModel
    let cue: SubtitleCue
    @Environment(AppModel.self) private var app
    @State private var isRetiming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Subtitle text",
                text: Binding(get: { cue.text }, set: { model.setCueText(cue.id, $0) }),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)

            HStack(spacing: 8) {
                TimeField(title: "Start", seconds: model.timeline.editedTimeSnapping(forSource: cue.start)) {
                    model.setCueTiming(cue.id, start: model.timeline.sourceTime(forEdited: $0))
                }
                TimeField(title: "End", seconds: model.timeline.editedTimeSnapping(forSource: cue.end)) {
                    model.setCueTiming(cue.id, end: model.timeline.sourceTime(forEdited: $0))
                }
            }

            let words = model.words(of: cue)
            if !words.isEmpty {
                WordChips(model: model, words: words)
                HStack {
                    Button("Cut Words") { model.cutSelectedWords() }
                        .disabled(model.wordCutProblem != nil)
                        .help(model.wordCutProblem ?? "Remove these words from the video")
                    Spacer()
                }
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Button("Cut Subtitle") { model.cutCue(cue.id) }
                    .help("Remove this subtitle's time from the video")
                if cue.position != nil {
                    Menu("Position") {
                        Button("Reset Position") { model.setCuePosition(cue.id, nil) }
                        Button("Use as Default Position") { model.useCuePositionAsDefault(cue.id) }
                    }
                    .fixedSize()
                }
                if let width = cue.maxWidth {
                    Menu("Width \(Int((width * 100).rounded()))%") {
                        Button("Reset Width") { model.setCueWidth(cue.id, nil) }
                        Button("Use as Default Width") { model.useCueWidthAsDefault(cue.id) }
                    }
                    .fixedSize()
                    .help("This subtitle's own width (drag its box's edges in the preview)")
                }
                if canRetime {
                    Button(isRetiming ? "Re-timing…" : "Re-time") { retime() }
                        .disabled(isRetiming)
                        .help("Align your corrected text with the audio again")
                }
                Spacer()
                Button(role: .destructive) {
                    model.deleteCues([cue.id])
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete subtitle")
            }
            .controlSize(.small)
        }
    }

    /// Qwen transcripts in a fine-timing language, where the user changed the words.
    private var canRetime: Bool {
        guard cue.isTextCorrected, let transcript = model.transcript,
            transcript.options.engine == SpeechEngine.qwen.rawValue,
            app.transcription.models.isInstalled(.qwen)
        else { return false }
        return LanguageCapabilities.hasFineTiming(retimeLanguage, engine: .qwen)
    }

    private var retimeLanguage: String? {
        guard let transcript = model.transcript else { return nil }
        let ids = Set(cue.unitIDs)
        return transcript.segments.first { $0.units.contains { ids.contains($0.id) } }?.languageTag
            ?? transcript.options.languageHint
    }

    private func retime() {
        guard let language = retimeLanguage, let transcript = model.transcript else { return }
        isRetiming = true
        let id = cue.id
        Task {
            defer { isRetiming = false }
            do {
                if let range = try await app.transcription.retime(
                    text: cue.text, start: cue.start, end: cue.end, languageTag: language,
                    packageURL: model.package.url, audioSource: transcript.options.audioSource)
                {
                    model.updateCue(id, "Re-time Subtitle") { c in
                        c.start = range.start
                        c.end = max(range.end, range.start + EditLimits.minimumCueLength)
                        c.timingEdited = false
                    }
                } else {
                    model.flash("Couldn't align this text")
                }
            } catch {
                model.flash((error as? LocalizedError)?.errorDescription ?? "Couldn't re-time")
            }
        }
    }
}

/// Transcript words as toggleable chips; click selects one, shift-click extends the run.
private struct WordChips: View {
    let model: EditorModel
    let words: [(unit: TranscriptUnit, text: String)]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(words, id: \.unit.id) { word in
                let selected = model.selectedWordIDs.contains(word.unit.id)
                let fine = word.unit.timing?.isFine == true
                Text(word.text)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(selected ? Color.themeOnAccent : (fine ? .primary : .secondary))
                    .background(
                        selected ? Color.themeAccent : Color.themeControlFill,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                    .onTapGesture { toggle(word.unit.id) }
                    .help(fine ? "" : "No precise timing for this word")
            }
        }
    }

    private func toggle(_ id: String) {
        let ids = words.map(\.unit.id)
        if NSEvent.modifierFlags.contains(.shift), let anchor = model.selectedWordIDs.first,
            let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id)
        {
            model.selectedWordIDs = Array(ids[min(a, b)...max(a, b)])
        } else if model.selectedWordIDs == [id] {
            model.selectedWordIDs = []
        } else {
            model.selectedWordIDs = [id]
        }
    }
}

/// An edited-timeline time field (`m:ss.cc`), committing on return.
private struct TimeField: View {
    let title: String
    let seconds: Double
    let commit: (Double) -> Void
    @State private var text = ""

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: 72)
                .onSubmit {
                    if let value = TimeFormat.parse(text) { commit(value) } else { text = TimeFormat.clock(seconds) }
                }
        }
        .font(.caption)
        .onAppear { text = TimeFormat.clock(seconds) }
        .onChange(of: seconds) { _, value in text = TimeFormat.clock(value) }
    }
}

/// Wraps its children onto lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Which cue is under the playhead, updated only when it changes (not at the clock's 10 Hz), so the list
/// re-renders a few times a minute during playback instead of every tick.
@MainActor
@Observable
final class ActiveCueTracker {
    private(set) var activeID: SubtitleCue.ID?

    func start(_ model: EditorModel) {
        update(model)
        model.clock.observeTime(self) { [weak self, weak model] _ in
            guard let model else { return }
            self?.update(model)
        }
        model.playhead.observe(self) { [weak self, weak model] _ in
            guard let model else { return }
            self?.update(model)
        }
    }

    func stop(_ model: EditorModel) {
        model.clock.removeTimeObserver(self)
        model.playhead.remove(self)
    }

    private func update(_ model: EditorModel) {
        let id = model.cueAtPlayhead?.id
        if id != activeID { activeID = id }
    }
}

extension Optional where Wrapped == PendingMerge {
    /// Adapts `pendingMerge` to `.sheet(item:)`.
    fileprivate var optionalIdentity: IdentifiedMerge? {
        get { map { IdentifiedMerge(merge: $0) } }
        set { if newValue == nil { self = nil } }
    }
}

private struct IdentifiedMerge: Identifiable {
    let merge: PendingMerge
    var id: String { merge.revisionID }
}
