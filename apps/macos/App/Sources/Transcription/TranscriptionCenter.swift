import AppKit
import Foundation
import MyScreenArtCore
import Observation
import ProjectKit
import SpeechCore

/// The app's one transcription queue (and the one owner of the speech service's lifecycle).
///
/// - Jobs run one at a time, each with an immutable engine, audio source and options.
/// - New recordings are queued automatically (`.recordingFinished`) when an engine is installed and
///   "Transcribe new recordings" is on; the editor queues on demand.
/// - Results are committed through the open editor (one undoable edit) or straight into `edit.json`. A result
///   never overwrites user edits: it lands as a candidate instead (`SubtitleSettings.receive`).
/// - New Qwen work is held while an editor plays or an export runs, and all work pauses on critical memory
///   pressure (the service is recycled; checkpoints make resuming cheap).
///
/// Other areas use: `job(for:)`, `transcribe(_:engine:)`, `cancel(_:)`, `cancelAll()`, `isAvailable`, `settings`,
/// `models`, `retime(…)`.
@MainActor
@Observable
final class TranscriptionCenter {
    @MainActor
    @Observable
    final class Job: Identifiable {
        enum Phase: Equatable {
            case queued
            case running(TranscriptionStage)
            case held(String)
            case succeeded(SubtitleSettings.Receipt)
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let packageURL: URL
        let engine: SpeechEngine
        fileprivate(set) var phase: Phase = .queued
        @ObservationIgnored fileprivate var task: Task<Void, Never>?

        init(packageURL: URL, engine: SpeechEngine) {
            self.packageURL = packageURL
            self.engine = engine
        }

        var isActive: Bool {
            switch phase {
            case .queued, .running, .held: true
            default: false
            }
        }

        var statusText: String {
            switch phase {
            case .queued: "Waiting…"
            case .running(let stage): stage.title + "…"
            case .held(let reason): reason
            case .succeeded(.adopted): "Subtitles ready"
            case .succeeded(.candidate): "New transcript ready"
            case .failed(let message): message
            case .cancelled: "Cancelled"
            }
        }

        /// 0…1, or nil while indeterminate.
        var fraction: Double? {
            if case .running(let stage) = phase { return stage.overall(aligning: engine == .qwen) }
            return nil
        }
    }

    let settings: SpeechSettings
    let models: SpeechModels
    private(set) var jobs: [Job] = []

    @ObservationIgnored weak var editors: EditorSessions?
    @ObservationIgnored weak var exports: ExportCenter?
    @ObservationIgnored private let client: any SpeechServiceManaging
    @ObservationIgnored private let workerGate = SpeechWorkGate()
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var retimeTasks: [UUID: Task<(start: Double, end: Double)?, any Error>] = [:]
    @ObservationIgnored private var finishedObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var memorySource: (any DispatchSourceMemoryPressure)?
    private var memoryCritical = false
    private var retimeCount = 0

    init(
        settings: SpeechSettings = SpeechSettings(), models: SpeechModels = SpeechModels(),
        client: (any SpeechServiceManaging)? = nil
    ) {
        self.settings = settings
        self.models = models
        self.client = client ?? SpeechServiceClient()
        finishedObserver = NotificationCenter.default.addObserver(
            forName: .recordingFinished, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated { self?.recordingFinished(url) }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated { self?.memoryPressureChanged(critical: event.contains(.critical)) }
        }
        source.resume()
        memorySource = source
    }

    /// An engine is chosen and installed.
    var isAvailable: Bool {
        guard let engine = settings.engine else { return false }
        return models.isInstalled(engine)
    }

    /// The latest job for a recording.
    func job(for packageURL: URL) -> Job? {
        let key = packageURL.standardizedFileURL
        return jobs.last { $0.packageURL == key }
    }

    var isTranscribing: Bool { jobs.contains(where: \.isActive) }
    var isRetiming: Bool { retimeCount > 0 }
    var isWorking: Bool { isTranscribing || isRetiming }

    // MARK: Queueing

    private func recordingFinished(_ url: URL) {
        guard settings.autoTranscribe, let engine = settings.engine, models.isInstalled(engine) else { return }
        transcribe(url, engine: engine)
    }

    /// Queues a transcription (a no-op when one is already queued or running for the recording).
    @discardableResult
    func transcribe(_ packageURL: URL, engine: SpeechEngine? = nil) -> Job? {
        guard let engine = engine ?? settings.engine else { return nil }
        let key = packageURL.standardizedFileURL
        if let existing = job(for: key), existing.isActive { return existing }
        let job = Job(packageURL: key, engine: engine)
        jobs.append(job)
        trimFinished()
        if runner == nil { runner = Task { [weak self] in await self?.drain() } }
        return job
    }

    func cancel(_ packageURL: URL) {
        guard let job = job(for: packageURL), job.isActive else { return }
        if job.task == nil { job.phase = .cancelled } else { job.task?.cancel() }
    }

    func cancelAll() {
        for job in jobs where job.isActive {
            if job.task == nil { job.phase = .cancelled } else { job.task?.cancel() }
        }
        for task in retimeTasks.values { task.cancel() }
    }

    func waitUntilIdle() async {
        guard isWorking else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func drain() async {
        while let job = jobs.first(where: { $0.phase == .queued }) {
            await workerGate.acquire()
            guard job.phase == .queued else {
                workerGate.release()
                continue
            }
            let task = Task { await self.run(job) }
            job.task = task
            await task.value
            job.task = nil
            workerGate.release()
        }
        runner = nil
        // Idle: end the service process so its model memory goes back to the system.
        if !workerGate.isBusy { client.reset() }
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard !isWorking else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Running

    private func run(_ job: Job) async {
        job.phase = .running(.waitingForModels)
        let package = RecordingPackage(url: job.packageURL)
        do {
            let (meta, edit) = try await Self.load(package)
            let source = try Self.audioSource(for: edit, meta: meta, package: package)
            let models = try await self.models.store.acquireLease(job.engine)
            defer { Task { await self.models.store.releaseLease(job.engine) } }
            let store = self.models.store
            let transcriptionJob = TranscriptionJob(
                package: package, meta: meta, engine: job.engine, audioSource: source,
                languageHint: settings.languageHint(for: job.engine), models: models,
                modelDirectories: Dictionary(
                    uniqueKeysWithValues: models.map { ($0.id, store.installDirectory(for: $0)) }),
                runtimeDirectories: Dictionary(
                    uniqueKeysWithValues: models.map { ($0.id, store.runtimeDirectory(for: $0)) }),
                parentRevisionID: edit.subtitles.revisionID)
            let capabilities = try await handshake()
            let revision = try await runWithOneRetry(
                transcriptionJob, job: job, implementation: capabilities.implementation)
            try Task.checkCancellation()
            job.phase = .running(.committing)
            let receipt = try await commit(revision, to: package, meta: meta)
            job.phase = .succeeded(receipt)
            Log.app.info(
                "Transcription finished: \(job.engine.rawValue, privacy: .public), \(revision.segments.count) segments, \(revision.status.rawValue, privacy: .public)"
            )
        } catch is CancellationError {
            job.phase = .cancelled
        } catch TranscriptionError.cancelled {
            job.phase = .cancelled
        } catch {
            if Task.isCancelled {
                job.phase = .cancelled
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Log.app.error("Transcription failed: \(message, privacy: .public)")
                job.phase = .failed(message)
            }
        }
    }

    private func handshake() async throws -> WorkerCapabilities {
        let response = try await client.send(.handshake(protocolVersion: WorkerProtocolVersion.current))
        guard case .capabilities(let capabilities) = response,
            capabilities.protocolVersion == WorkerProtocolVersion.current
        else { throw TranscriptionError.workerFailure(.badRequest, "The speech service is a different version.") }
        guard capabilities.supported else { throw TranscriptionError.unsupportedPlatform }
        return capabilities
    }

    /// At most one automatic retry, and only after the service crashed (checkpoints make it resume, not restart).
    private func runWithOneRetry(
        _ transcriptionJob: TranscriptionJob, job: Job, implementation: [String: String]
    ) async throws -> TranscriptRevision {
        let progress: TranscriptionPipeline.Progress = { stage in
            Task { @MainActor in if case .running = job.phase { job.phase = .running(stage) } }
        }
        let admission: TranscriptionPipeline.Admission = { [weak self] in
            await self?.admit(job)
        }
        do {
            return try await TranscriptionPipeline.run(
                transcriptionJob, worker: client, implementation: implementation, admission: admission,
                progress: progress)
        } catch TranscriptionError.workerCrashed where !Task.isCancelled {
            Log.app.error("Speech service crashed; retrying once from checkpoints")
            client.release()
            return try await TranscriptionPipeline.run(
                transcriptionJob, worker: client, implementation: implementation, admission: admission,
                progress: progress)
        }
    }

    // MARK: Admission (playback, export, memory)

    /// Waits while work shouldn't start: critical memory pressure (all engines; the service is recycled), or an
    /// editor playing / an export running (Qwen, which competes for the GPU).
    private func admit(_ job: Job) async {
        while !Task.isCancelled, let reason = holdReason(for: job) {
            let previous = job.phase
            job.phase = .held(reason)
            if memoryCritical { client.release() }
            await waitForChange()
            if case .held = job.phase { job.phase = previous }
        }
    }

    func holdReason(for job: Job) -> String? {
        if memoryCritical { return "Paused: the Mac is low on memory" }
        guard job.engine == .qwen else { return nil }
        if exports?.isExporting == true { return "Paused while exporting" }
        if editors?.isAnyPlaying == true { return "Paused during playback" }
        return nil
    }

    /// Returns when anything the hold depends on changes (Observation, not polling), or the task is cancelled.
    private func waitForChange() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(continuation)
                withObservationTracking {
                    _ = memoryCritical
                    _ = exports?.isExporting
                    _ = editors?.isAnyPlaying
                } onChange: {
                    once.resume()
                }
                pendingWake = once
            }
        } onCancel: {
            Task { @MainActor in self.pendingWake?.resume() }
        }
        pendingWake = nil
    }

    @ObservationIgnored private var pendingWake: ResumeOnce?

    func memoryPressureChanged(critical: Bool) {
        guard critical != memoryCritical else { return }
        memoryCritical = critical
        Log.app.info("Memory pressure \(critical ? "critical" : "normal", privacy: .public)")
    }

    // MARK: Committing

    /// Saves the revision (immutable) and lands it in the recording's subtitles.
    func commit(_ revision: TranscriptRevision, to package: RecordingPackage, meta: RecordingMeta) async throws
        -> SubtitleSettings.Receipt
    {
        try await Task.detached { try package.saveTranscript(revision) }.value
        await editors?.waitForClose(of: package.url)
        if let editor = editors?.session(for: package.url) {
            return editor.receiveTranscript(revision)
        }
        // Keep the read/modify/write on the main actor. Registering an editor cannot interleave with it.
        var edit = try package.loadEffectiveEdit(meta: meta, defaults: ProjectDefaultsStore.load())
        let receipt = edit.subtitles.receive(revision)
        try package.saveEdit(edit)
        return receipt
    }

    // MARK: Retiming (Qwen)

    /// Aligns a corrected cue's text against its audio again (fine-timing Qwen languages only).
    func retime(
        text: String, start: Double, end: Double, languageTag: String, packageURL: URL,
        audioSource: TranscriptAudioSource
    )
        async throws -> (start: Double, end: Double)?
    {
        let id = UUID()
        let task = Task {
            try await performRetime(
                text: text, start: start, end: end, languageTag: languageTag, packageURL: packageURL,
                audioSource: audioSource)
        }
        retimeTasks[id] = task
        retimeCount += 1
        defer {
            retimeTasks[id] = nil
            retimeCount -= 1
            resumeIdleWaitersIfNeeded()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRetime(
        text: String, start: Double, end: Double, languageTag: String, packageURL: URL,
        audioSource: TranscriptAudioSource
    ) async throws -> (start: Double, end: Double)? {
        guard models.isInstalled(.qwen) else { throw TranscriptionError.modelsMissing }
        try Task.checkCancellation()
        let package = RecordingPackage(url: packageURL)
        let (meta, _) = try await Self.load(package)
        let manifests = try await models.store.acquireLease(.qwen)
        defer { Task { await self.models.store.releaseLease(.qwen) } }
        let aligner = manifests[1]
        let store = models.store
        await workerGate.acquire()
        defer {
            workerGate.release()
            if runner == nil && !workerGate.isBusy { client.reset() }
        }
        try Task.checkCancellation()
        let result = try await TranscriptionPipeline.retime(
            text: text, sourceStart: start, sourceEnd: end, languageTag: languageTag, package: package, meta: meta,
            audioSource: audioSource, aligner: aligner, alignerDirectory: store.installDirectory(for: aligner),
            runtimeDirectory: store.runtimeDirectory(for: aligner), worker: client)
        return result
    }

    // MARK: Helpers

    private static func load(_ package: RecordingPackage) async throws -> (RecordingMeta, EditConfig) {
        let defaults = ProjectDefaultsStore.load()
        return try await Task.detached {
            let meta = try package.loadMeta()
            let edit = try package.loadEffectiveEdit(meta: meta, defaults: defaults)
            return (meta, edit)
        }.value
    }

    /// The recording's chosen track, else the microphone, else system audio.
    private nonisolated static func audioSource(for edit: EditConfig, meta: RecordingMeta, package: RecordingPackage)
        throws
        -> TranscriptAudioSource
    {
        let available = package.availableStreams()
        func has(_ source: TranscriptAudioSource) -> Bool {
            switch source {
            case .microphone: meta.microphone != nil && available.contains(.microphone)
            case .systemAudio: meta.capturedSystemAudio && available.contains(.systemAudio)
            }
        }
        if let chosen = edit.subtitles.audioSource, has(chosen) { return chosen }
        if has(.microphone) { return .microphone }
        if has(.systemAudio) { return .systemAudio }
        throw TranscriptionError.noAudio
    }

    private func trimFinished() {
        let finished = jobs.filter { !$0.isActive }
        guard finished.count > 20 else { return }
        let drop = Set(finished.prefix(finished.count - 20).map(\.id))
        jobs.removeAll { drop.contains($0.id) }
    }
}

/// A model load, its requests and its unload form one exclusive operation on the single-model service.
@MainActor
final class SpeechWorkGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isBusy: Bool { occupied }

    func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Resumes a continuation at most once (Observation's onChange and cancellation can both fire).
nonisolated private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}
