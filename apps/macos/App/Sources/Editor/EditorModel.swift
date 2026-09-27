import AVFoundation
import MyScreenCamCore
import Observation
import ProjectKit
import RenderKit
import SwiftUI

/// What is selected in the timeline / preview. Delete removes it; Esc clears it.
enum EditorSelection: Hashable {
    case segment(Segment.ID)
    case keyframe(ZoomKeyframe.ID)
    case blur(BlurMask.ID)
    case cue(SubtitleCue.ID)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case zoom, webcam, audio, blur, cursor, background, subtitles

    var id: Self { self }

    var title: String {
        switch self {
        case .zoom: "Zoom"
        case .webcam: "Webcam"
        case .audio: "Audio"
        case .blur: "Blur"
        case .cursor: "Cursor"
        case .background: "Background"
        case .subtitles: "Subtitles"
        }
    }

    var systemImage: String {
        switch self {
        case .zoom: "plus.magnifyingglass"
        case .webcam: "web.camera"
        case .audio: "speaker.wave.2"
        case .blur: "drop.halffull"
        case .cursor: "cursorarrow"
        case .background: "rectangle.inset.filled"
        case .subtitles: "captions.bubble"
        }
    }
}

/// One open recording: the edit, undo/redo, autosave, and the preview player.
///
/// Every edit goes through ``apply(_:action:coalesce:)``, which normalises it, registers undo (coalescing continuous
/// changes), schedules the autosave and updates the renderer (`ProjectRenderer.update(edit:)` + `apply(_:to:)`).
/// Only edits, selection and ~10 Hz clock ticks invalidate SwiftUI; nothing here changes per frame.
@MainActor
@Observable
final class EditorModel {
    static let autoZoomDefaultsKey = "autoZoomFromClicks"

    let package: RecordingPackage
    private(set) var meta: RecordingMeta
    private(set) var edit: EditConfig
    /// Edited ↔ source mapping for `edit.segments` (updated synchronously with every edit).
    private(set) var timeline: EditTimeline
    @ObservationIgnored let events: [InputEvent]
    /// Source times of left mouse-downs (for the Clicks row).
    @ObservationIgnored let clickTimes: [Double]
    /// Streams recorded in the package (file present and declared in the metadata).
    let recordedStreams: Set<StreamKind>
    @ObservationIgnored let renderer: ProjectRenderer
    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored let playhead = PlayheadSignal()
    let clock = PlaybackClock()

    var selection: EditorSelection? {
        didSet { if selection != oldValue { isPickingZoomTarget = false } }
    }
    var inspectorTab: InspectorTab = .zoom
    /// Timeline zoom, 0.5…4 (1 = the whole edited duration fits).
    var timelineZoom: Double = 1
    /// The next click on the preview sets the selected keyframe's target.
    var isPickingZoomTarget = false
    /// A short message shown in the transport bar ("Too close to edge").
    private(set) var transientMessage: String?
    var showExport = false
    private(set) var presets: [EditPreset] = []
    private(set) var waveforms: [StreamKind: Waveform] = [:]
    private(set) var renderError: String?
    private(set) var saveError: String?
    /// An edit has been made that isn't on disk yet.
    private(set) var hasUnsavedChanges = false
    /// Transcript revisions read from the package (the adopted one and any candidate), by id.
    var transcripts: [String: TranscriptRevision] = [:]
    /// Subtitle list search text.
    var subtitleSearch = ""
    /// Words selected in the cue editor (unit ids, in order) for "Cut Words".
    var selectedWordIDs: [String] = []
    /// A candidate adoption with conflicts waiting for the user's decisions.
    var pendingMerge: PendingMerge?

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private let autosaver: EditAutosaver
    @ObservationIgnored private let saveQueue: EditSaveQueue
    @ObservationIgnored private let presetStore = PresetStore(directory: PresetStore.defaultDirectory())

    // Undo coalescing.
    @ObservationIgnored private var continuousDepth = 0
    @ObservationIgnored private var continuousStart: EditConfig?
    @ObservationIgnored private var continuousAction = ""
    @ObservationIgnored private var lastCoalesceKey: AnyHashable?
    @ObservationIgnored private var lastCoalesceDate = Date.distantPast

    // Rendering and playback plumbing.
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderNeeded = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pendingSeek: (time: Double, exact: Bool)?
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var previewSizeTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var isClosed = false

    /// Preview frame rate: the recording's rate, 24…60.
    let previewFrameRate: Int

    init(project: RenderProject, renderer: ProjectRenderer) {
        package = project.package
        meta = project.meta
        edit = renderer.project.edit
        timeline = EditTimeline(segments: renderer.project.edit.segments)
        events = project.events
        clickTimes = project.events.filter(\.isLeftClick).map(\.t)
        self.renderer = renderer
        previewFrameRate = min(60, max(24, project.meta.screen.frameRate))

        let available = project.package.availableStreams()
        var recorded: Set<StreamKind> = [.screen]
        if project.meta.webcam != nil, available.contains(.webcam) { recorded.insert(.webcam) }
        if project.meta.capturedSystemAudio, available.contains(.systemAudio) { recorded.insert(.systemAudio) }
        if project.meta.microphone != nil, available.contains(.microphone) { recorded.insert(.microphone) }
        recordedStreams = recorded

        player = AVPlayer(playerItem: renderer.makePlayerItem())
        player.actionAtItemEnd = .pause

        let saver = EditAutosaver(package: project.package) { edit, package in
            try package.saveEdit(edit)
        }
        autosaver = saver
        saveQueue = EditSaveQueue(autosaver: saver)
        startObservingPlayer()
        loadWaveforms()
        reloadPresets()
        loadTranscripts()
    }

    // MARK: - Edits, undo, autosave

    /// Applies a new edit. `coalesce`: consecutive changes with the same key within a second (e.g. typing, colour
    /// wells, steppers) share one undo step. Inside ``beginContinuousChange()``/``endContinuousChange()`` (slider
    /// and drag gestures) the whole gesture is one undo step.
    func apply(_ newEdit: EditConfig, action: String, coalesce: AnyHashable? = nil) {
        let next = newEdit.normalized(duration: meta.duration)
        guard next != edit else { return }
        let old = edit
        if continuousDepth > 0 {
            if continuousStart == nil {
                continuousStart = old
                continuousAction = action
            }
        } else if let coalesce, coalesce == lastCoalesceKey, Date.now.timeIntervalSince(lastCoalesceDate) < 1 {
            // Merged into the undo step registered by the previous change.
        } else {
            registerUndo(restoring: old, action: action)
        }
        lastCoalesceKey = continuousDepth > 0 ? nil : coalesce
        lastCoalesceDate = .now
        setEditState(next)
    }

    /// Applies a change the user didn't make (data derived from the package), without an undo step.
    func applyDerived(_ change: (inout EditConfig) -> Void) {
        var copy = edit
        change(&copy)
        let next = copy.normalized(duration: meta.duration)
        guard next != edit else { return }
        setEditState(next)
    }

    /// Mutates the edit through ``apply(_:action:coalesce:)``.
    func update(_ action: String, coalesce: AnyHashable? = nil, _ change: (inout EditConfig) -> Void) {
        var copy = edit
        change(&copy)
        apply(copy, action: action, coalesce: coalesce)
    }

    /// A binding to one edit value; each change is an undoable edit (coalesced per key path).
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<EditConfig, Value>, _ action: String) -> Binding<Value> {
        Binding(
            get: { self.edit[keyPath: keyPath] },
            set: { value in
                guard self.edit[keyPath: keyPath] != value else { return }
                self.update(action, coalesce: AnyHashable(keyPath)) { $0[keyPath: keyPath] = value }
            })
    }

    /// Starts a gesture (slider drag, timeline drag): changes until the matching end are one undo step.
    func beginContinuousChange() {
        continuousDepth += 1
    }

    func endContinuousChange() {
        continuousDepth = max(0, continuousDepth - 1)
        guard continuousDepth == 0, let start = continuousStart else { return }
        continuousStart = nil
        if start != edit { registerUndo(restoring: start, action: continuousAction) }
    }

    /// For `Slider(onEditingChanged:)`.
    func editingChanged(_ editing: Bool) {
        if editing { beginContinuousChange() } else { endContinuousChange() }
    }

    private func registerUndo(restoring old: EditConfig, action: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.revert(to: old, action: action) }
        }
        undoManager.setActionName(action)
    }

    /// Undo/redo: swaps the edit back and registers the inverse (AppKit files it on the redo stack while undoing).
    private func revert(to old: EditConfig, action: String) {
        registerUndo(restoring: edit, action: action)
        lastCoalesceKey = nil
        var restored = old
        if let id = restored.subtitles.revisionID, let revision = transcripts[id] {
            _ = restored.subtitles.fillWordTimings(from: revision)
        }
        setEditState(restored)
    }

    private func setEditState(_ next: EditConfig) {
        let segmentsChanged = next.segments != edit.segments
        edit = next
        if segmentsChanged { timeline = EditTimeline(segments: next.segments) }
        validateSelection()
        hasUnsavedChanges = true
        saveError = nil
        saveQueue.schedule(next)
        scheduleSaveConfirmation(for: next)
        scheduleRender()
    }

    /// The autosaver writes after 500 ms of quiet; mirror its state so `hasPendingSaves` is synchronous.
    @ObservationIgnored private var saveConfirmTask: Task<Void, Never>?
    private func scheduleSaveConfirmation(for config: EditConfig) {
        saveConfirmTask?.cancel()
        saveConfirmTask = Task { [weak self, autosaver] in
            try? await Task.sleep(for: autosaver.debounce + .milliseconds(150))
            guard !Task.isCancelled else { return }
            let pending = await autosaver.hasPendingChanges
            let saved = await autosaver.lastSaved
            let failure = await autosaver.lastError
            guard let self, !Task.isCancelled else { return }
            if !pending, saved == self.edit {
                self.hasUnsavedChanges = false
            } else if let failure {
                self.saveError = "Couldn't save edits: \(failure.localizedDescription)"
            }
        }
    }

    /// Writes pending edits now (window close, rename, delete).
    func flush() async {
        saveConfirmTask?.cancel()
        let latest = edit
        do {
            try await saveQueue.flush(latest)
            if latest == edit { hasUnsavedChanges = false }
        } catch {
            saveError = "Couldn't save edits: \(error.localizedDescription)"
        }
    }

    /// Synchronous save for app termination (`EditorSessions.flushAll`).
    func flushSynchronously() {
        guard hasUnsavedChanges else { return }
        do {
            try package.saveEdit(edit)
            hasUnsavedChanges = false
        } catch {
            Log.app.error("Couldn't save \(self.package.url.lastPathComponent, privacy: .public): \(error)")
        }
    }

    private func validateSelection() {
        switch selection {
        case .segment(let id): if !edit.segments.contains(where: { $0.id == id }) { selection = nil }
        case .keyframe(let id): if !edit.zoom.keyframes.contains(where: { $0.id == id }) { selection = nil }
        case .blur(let id): if !edit.blur.contains(where: { $0.id == id }) { selection = nil }
        case .cue(let id): if !edit.subtitles.cues.contains(where: { $0.id == id }) { selection = nil }
        case nil: break
        }
    }

    // MARK: - Rendering

    /// Pushes the latest edit to the renderer; at most one update runs at a time and the newest edit wins.
    private func scheduleRender() {
        renderNeeded = true
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while let self, self.renderNeeded, !self.isClosed {
                self.renderNeeded = false
                let target = self.edit
                do {
                    let kind = try await self.renderer.update(edit: target)
                    guard !self.isClosed else { break }
                    self.renderer.apply(kind, to: self.player)
                    // Overlays map through the renderer's zoom state; refresh them now it matches the edit.
                    if !kind.isEmpty, !self.clock.isPlaying { self.playhead.send(self.currentTime) }
                    self.renderError = nil
                } catch {
                    Log.app.error("Preview update failed: \(error)")
                    self.renderError = "The preview couldn't be updated (\(error.localizedDescription))."
                }
            }
            self?.renderTask = nil
        }
    }

    /// The preview view's backing size changed; re-render at that size once resizing settles.
    func previewSizeChanged(_ backingSize: CGSize) {
        guard backingSize.width >= 16, backingSize.height >= 16 else { return }
        // Round up to 64 px steps so small resizes don't rebuild the video composition.
        let size = CGSize(
            width: (backingSize.width / 64).rounded(.up) * 64, height: (backingSize.height / 64).rounded(.up) * 64)
        previewSizeTask?.cancel()
        previewSizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            let kind = self.renderer.update(options: .preview(maxSize: size, frameRate: self.previewFrameRate))
            self.renderer.apply(kind, to: self.player)
        }
    }

    /// The Audio panel's level meters appeared or disappeared: install the metering audio taps only while they're
    /// visible (each tap runs on the audio thread for every block played).
    func setMetersVisible(_ visible: Bool) {
        guard !isClosed else { return }
        renderer.apply(renderer.setMetering(visible), to: player)
    }

    // MARK: - Playback

    private func startObservingPlayer() {
        let interval = CMTime(value: 1, timescale: 10)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.pendingSeek == nil, self.seekTarget == nil else { return }
                let t = time.seconds
                guard t.isFinite else { return }
                self.clock.time = t
                if !self.clock.isPlaying { self.playhead.send(t) }
            }
        }
        rateObserver = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPlaying() }
        }
    }

    private func syncPlaying() {
        let playing = player.rate != 0
        guard playing != clock.isPlaying else { return }
        clock.isPlaying = playing
        if !playing {
            renderer.audioLevels.reset()
            let t = currentTime
            clock.time = t
            playhead.send(t)
        }
    }

    /// Edited seconds at the playhead (the pending seek target while seeking).
    var currentTime: Double {
        if let pendingSeek { return pendingSeek.time }
        if let seekTarget { return seekTarget }
        let t = player.currentTime().seconds
        return t.isFinite ? min(max(t, 0), timeline.duration) : 0
    }

    /// Source (session) seconds at the playhead.
    var currentSourceTime: Double { timeline.sourceTime(forEdited: currentTime) }

    var isPlaying: Bool { clock.isPlaying }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= timeline.duration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    func pause() {
        if player.rate != 0 { player.pause() }
    }

    /// Seeks the player. `exact: false` is for scrubbing (tolerant, chased: only the newest target is kept while a
    /// seek is in flight).
    func seek(to time: Double, exact: Bool = true) {
        let t = min(max(time, 0), timeline.duration)
        clock.time = t
        playhead.send(t)
        pendingSeek = (t, exact)
        if seekTarget == nil { runNextSeek() }
    }

    private func runNextSeek() {
        guard let next = pendingSeek else {
            seekTarget = nil
            return
        }
        pendingSeek = nil
        seekTarget = next.time
        let tolerance = next.exact ? CMTime.zero : CMTime(value: 1, timescale: 20)
        player.seek(
            to: CMTime(seconds: next.time, preferredTimescale: 90_000), toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor in self?.runNextSeek() }
        }
    }

    func step(by seconds: Double) {
        pause()
        seek(to: currentTime + seconds)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Window occluded or minimised: stop decoding and compositing.
    func windowVisibilityChanged(visible: Bool) {
        if !visible { pause() }
    }

    // MARK: - Messages

    func flash(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }

    // MARK: - Waveforms and presets

    private func loadWaveforms() {
        for kind in [StreamKind.systemAudio, .microphone] where recordedStreams.contains(kind) {
            let task = Task { [weak self, package] in
                do {
                    let waveform = try await Waveform.load(package: package, stream: kind)
                    guard !Task.isCancelled else { return }
                    self?.waveforms[kind] = waveform
                } catch {
                    Log.app.error("Waveform for \(kind.rawValue, privacy: .public) failed: \(error)")
                }
            }
            waveformTasks.append(task)
        }
    }

    func reloadPresets() {
        Task { [weak self, presetStore] in
            do {
                let list = try await presetStore.list()
                self?.presets = list
            } catch {
                Log.app.error("Couldn't load presets: \(error)")
            }
        }
    }

    func applyPreset(_ preset: EditPreset) {
        apply(preset.applied(to: edit), action: "Apply Preset “\(preset.name)”")
    }

    /// Saves the current look as a preset (replacing one with the same name).
    func saveCurrentAsPreset(named name: String) async -> String? {
        do {
            try await presetStore.save(EditPreset(name: name, from: edit))
            reloadPresets()
            return nil
        } catch PresetStore.StoreError.emptyName {
            return "Enter a name for the preset."
        } catch {
            return "Couldn't save the preset: \(error.localizedDescription)"
        }
    }

    func deletePreset(_ preset: EditPreset) {
        Task { [weak self, presetStore] in
            do {
                try await presetStore.delete(id: preset.id)
            } catch {
                Log.app.error("Couldn't delete preset: \(error)")
            }
            self?.reloadPresets()
        }
    }

    // MARK: - Library operations

    private var library: RecordingLibrary { RecordingLibrary(root: package.url.deletingLastPathComponent()) }

    /// Renames the recording (`meta.name`). Returns an error message on failure.
    func rename(to name: String) async -> String? {
        await flush()
        do {
            meta = try library.rename(package, to: name)
            return nil
        } catch RecordingLibrary.LibraryError.emptyName {
            return "The name can't be empty."
        } catch {
            return "Couldn't rename: \(error.localizedDescription)"
        }
    }

    /// Moves the recording to the Trash. Returns an error message on failure.
    func deleteRecording() async -> String? {
        pause()
        await flush()
        if let saveError { return saveError }
        waveformTasks.forEach { $0.cancel() }
        do {
            try library.delete(package)
            return nil
        } catch {
            return "Couldn't move the recording to the Trash: \(error.localizedDescription)"
        }
    }

    // MARK: - Lifecycle

    /// Window closing: save, stop playback and release the player item.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let rateObserver { NotificationCenter.default.removeObserver(rateObserver) }
        rateObserver = nil
        undoManager?.removeAllActions(withTarget: self)
        previewSizeTask?.cancel()
        waveformTasks.forEach { $0.cancel() }
        messageTask?.cancel()
        await flush()
        saveQueue.finish()
        player.replaceCurrentItem(with: nil)
    }
}
