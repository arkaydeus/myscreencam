import Foundation
import MyScreenArtCore
import ProjectKit

/// Something that answers worker requests: the XPC client in the app, an in-process ``InferenceEngine`` in
/// `speech-tool`, a fake in tests.
public protocol SpeechWorker: Sendable {
    func send(_ request: WorkerRequest) async throws -> WorkerResponse
}

/// Real stages with real progress (spec §8). Model loading is indeterminate.
public enum TranscriptionStage: Sendable, Equatable {
    case queued
    case waitingForModels
    case preparingAudio(Double)
    case loadingRecogniser
    case recognising(Double)
    case unloadingRecogniser
    case loadingAligner
    case aligning(Double)
    case validating
    case committing
    case completed

    public var title: String {
        switch self {
        case .queued: "Waiting"
        case .waitingForModels: "Waiting for models"
        case .preparingAudio: "Preparing audio"
        case .loadingRecogniser: "Loading model"
        case .recognising: "Transcribing"
        case .unloadingRecogniser: "Transcribing"
        case .loadingAligner: "Adding word timing"
        case .aligning: "Adding word timing"
        case .validating, .committing: "Saving"
        case .completed: "Done"
        }
    }

    /// Overall fraction 0…1 (never 1 before `.completed`), or nil while indeterminate.
    public func overall(aligning hasAlignment: Bool) -> Double? {
        let recogniseEnd = hasAlignment ? 0.7 : 0.95
        switch self {
        case .queued, .waitingForModels: return 0
        case .preparingAudio(let f): return 0.05 * f
        case .loadingRecogniser: return nil
        case .recognising(let f): return 0.05 + (recogniseEnd - 0.05) * f
        case .unloadingRecogniser, .loadingAligner: return recogniseEnd
        case .aligning(let f): return recogniseEnd + (0.95 - recogniseEnd) * f
        case .validating, .committing: return 0.97
        case .completed: return 1
        }
    }
}

public enum TranscriptionError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedPlatform
    case unsupportedLanguage(String)
    case modelsMissing
    case noAudio
    case unreadableAudio(String)
    case modelInitialisation(String)
    case workerFailure(WorkerFailure, String)
    case workerCrashed
    case invalidTiming(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: "Local transcription needs a Mac with Apple silicon."
        case .unsupportedLanguage(let tag): "The selected engine can't transcribe \(tag)."
        case .modelsMissing: "The speech model isn't installed. Download it in Settings › Subtitles."
        case .noAudio: "This recording has no microphone or system audio to transcribe."
        case .unreadableAudio(let message): "The audio couldn't be read: \(message)"
        case .modelInitialisation(let message): "The speech model couldn't be loaded: \(message)"
        case .workerFailure(let failure, let message): "Transcription failed (\(failure.rawValue)): \(message)"
        case .workerCrashed: "The speech service stopped unexpectedly."
        case .invalidTiming(let message): "The transcript had invalid timing: \(message)"
        case .cancelled: "Cancelled."
        }
    }
}

/// Everything a job needs, fixed when it's queued (the model choice can't change under a running job).
public struct TranscriptionJob: Sendable {
    public var package: RecordingPackage
    public var meta: RecordingMeta
    public var engine: SpeechEngine
    public var audioSource: TranscriptAudioSource
    public var languageHint: String?
    /// Recogniser first, then (Qwen) the aligner.
    public var models: [ModelManifest]
    public var modelDirectories: [String: URL]
    public var runtimeDirectories: [String: URL]
    public var parentRevisionID: String?

    public init(
        package: RecordingPackage, meta: RecordingMeta, engine: SpeechEngine, audioSource: TranscriptAudioSource,
        languageHint: String?, models: [ModelManifest], modelDirectories: [String: URL],
        runtimeDirectories: [String: URL], parentRevisionID: String?
    ) {
        self.package = package
        self.meta = meta
        self.engine = engine
        self.audioSource = audioSource
        self.languageHint = languageHint
        self.models = models
        self.modelDirectories = modelDirectories
        self.runtimeDirectories = runtimeDirectories
        self.parentRevisionID = parentRevisionID
    }

    public var policy: WindowPolicy { engine == .parakeet ? .parakeet : .qwen }

    public var options: TranscriptionOptions {
        TranscriptionOptions(
            engine: engine.rawValue, audioSource: audioSource, languageHint: languageHint,
            windowSeconds: policy.maximum, maxWindowSeconds: policy.hardCap,
            tokenBudgetPerWindow: nil, audioRecipe: PreparedAudio.recipe)
    }
}

/// Host-side orchestration of one transcription: prepare audio → plan windows → recognise (checkpointing each
/// window, retrying a truncated Qwen window once with smaller windows) → for Qwen, unload and run alignment as a
/// separate phase → assemble and validate. It never writes the project; the caller commits the revision.
public enum TranscriptionPipeline {
    public typealias Progress = @Sendable (TranscriptionStage) -> Void
    /// Awaited before each window; the app uses it to hold new work during playback/export.
    public typealias Admission = @Sendable () async -> Void

    public static func run(
        _ job: TranscriptionJob, worker: any SpeechWorker, implementation: [String: String],
        admission: Admission? = nil, progress: Progress? = nil
    ) async throws -> TranscriptRevision {
        let cache = job.package.url(PackageLayout.transcriptionCacheDirectory)
        guard let recogniser = job.models.first, let recogniserDir = job.modelDirectories[recogniser.id] else {
            throw TranscriptionError.modelsMissing
        }
        if let hint = job.languageHint, !LanguageCapabilities.canRecognise(hint, engine: job.engine) {
            throw TranscriptionError.unsupportedLanguage(hint)
        }

        // 1. Audio.
        progress?(.preparingAudio(0))
        let prepared: PreparedAudio
        do {
            prepared = try await AudioPreparation.prepare(
                package: job.package, meta: job.meta, stream: job.audioSource.stream, directory: cache
            ) { progress?(.preparingAudio($0)) }
        } catch AudioPreparationError.cancelled {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.unreadableAudio(String(describing: error))
        }
        try checkCancelled()
        let audioPath = cache.appending(path: prepared.samplesFileName).path
        let samples = try PreparedSamples(url: cache.appending(path: prepared.samplesFileName))
        let energies = samples.frameEnergies(frame: WindowPlanner.frameSamples)
        let windows = WindowPlanner.plan(
            range: SampleRange(start: 0, end: prepared.sampleCount), energies: energies, policy: job.policy)

        let recognitionKey = Fingerprint.of(strings: [
            prepared.identity, recogniser.digest, Fingerprint.of(implementation), Fingerprint.of(job.options),
            Fingerprint.of(job.policy),
        ])
        let checkpoints = CheckpointStore(directory: cache.appending(path: recognitionKey))

        // 2. Recognition.
        var results: [RecognisedWindow] = []
        var pending: [WorkWindow] = []
        for window in windows {
            if let saved = checkpoints.recognised(window.index) {
                results.append(saved)
            } else {
                pending.append(window)
            }
        }
        let role: WorkerModelRole = job.engine == .parakeet ? .parakeet : .qwenRecogniser
        if !pending.isEmpty {
            progress?(.loadingRecogniser)
            try await load(role, directory: recogniserDir, runtime: job.runtimeDirectories[recogniser.id], worker)
            let total = Double(prepared.sampleCount)
            var done = Double(results.reduce(Int64(0)) { $0 + $1.window.owned.count })
            progress?(.recognising(done / max(total, 1)))
            var nextIndex = (windows.map(\.index).max() ?? 0) + 1
            for window in pending {
                await admission?()
                try checkCancelled()
                var result = try await recognise(window, audioPath: audioPath, hint: job.languageHint, worker)
                if job.engine == .qwen,
                    result.termination == .tokenBudgetExhausted || result.termination == .repetitionStop
                {
                    // One bounded retry with smaller windows; if they finish, they replace the truncated window.
                    let retryWindows = WindowPlanner.plan(
                        range: window.owned, energies: energies, policy: .qwenRetry, firstIndex: nextIndex,
                        totalSamples: prepared.sampleCount)
                    nextIndex += retryWindows.count
                    var retried: [RecognisedWindow] = []
                    for sub in retryWindows {
                        try checkCancelled()
                        retried.append(try await recognise(sub, audioPath: audioPath, hint: job.languageHint, worker))
                    }
                    if retried.allSatisfy({ $0.termination == .complete || $0.termination == .silent }) {
                        for sub in retried { try checkpoints.save(sub) }
                        results += retried
                        done += Double(window.owned.count)
                        progress?(.recognising(done / max(total, 1)))
                        continue
                    }
                    result.warnings.append("retry with smaller windows didn't complete either")
                }
                try checkpoints.save(result)
                results.append(result)
                done += Double(window.owned.count)
                progress?(.recognising(done / max(total, 1)))
            }
        }
        try checkCancelled()

        // 3. Alignment (Qwen): release the recogniser first; never keep both resident.
        var alignments: [Int: AlignedWindow] = [:]
        var aligner: ModelIdentity?
        if job.engine == .qwen, job.models.count > 1 {
            progress?(.unloadingRecogniser)
            _ = try await worker.send(.unload)
            let alignerModel = job.models[1]
            let alignable = results.filter { window in
                let tag = job.languageHint ?? window.languageTag
                return !window.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && LanguageCapabilities.hasFineTiming(tag, engine: .qwen)
            }
            if !alignable.isEmpty, let alignerDir = job.modelDirectories[alignerModel.id] {
                aligner = alignerModel.identity
                var todo: [(RecognisedWindow, String)] = []
                for window in alignable {
                    let key = alignmentKey(recognitionKey, window, alignerModel)
                    if let saved = checkpoints.aligned(key) {
                        alignments[window.window.index] = saved
                    } else {
                        todo.append((window, key))
                    }
                }
                if !todo.isEmpty {
                    progress?(.loadingAligner)
                    try await load(
                        .qwenAligner, directory: alignerDir, runtime: job.runtimeDirectories[alignerModel.id], worker)
                    for (i, (window, key)) in todo.enumerated() {
                        await admission?()
                        try checkCancelled()
                        let tag = job.languageHint ?? window.languageTag ?? "en"
                        let response = try await worker.send(
                            .align(audioPath: audioPath, window: window.window, text: window.text, languageTag: tag))
                        switch response {
                        case .aligned(let aligned):
                            try checkpoints.save(aligned, key: key)
                            alignments[window.window.index] = aligned
                        case .failure(let failure, let message):
                            // Alignment failure keeps the recognised text (coarse timing) and is reported.
                            Log.app.error(
                                "Alignment failed: \(failure.rawValue, privacy: .public) \(message, privacy: .public)")
                        default:
                            throw TranscriptionError.workerFailure(.badRequest, "Unexpected alignment response")
                        }
                        progress?(.aligning(Double(i + 1) / Double(todo.count)))
                    }
                }
            }
        }
        _ = try? await worker.send(.unload)
        try checkCancelled()

        // 4. Assemble and validate.
        progress?(.validating)
        let input = TranscriptAssembler.Input(
            revisionID: UUID().uuidString.lowercased(), parentRevisionID: job.parentRevisionID, prepared: prepared,
            sourceDuration: job.meta.duration, engine: job.engine, recogniser: recogniser.identity, aligner: aligner,
            implementation: implementation, options: job.options, windows: results, alignments: alignments)
        do {
            return try TranscriptAssembler.assemble(input)
        } catch let error as TranscriptValidationError {
            throw TranscriptionError.invalidTiming(error.description)
        }
    }

    /// Re-times one corrected cue (Qwen languages with fine timing): aligns `text` against the cue's audio with
    /// `context` seconds either side. Returns the new source start/end of the aligned words, or nil when nothing
    /// aligned. The aligner must be installed; the caller holds a lease.
    public static func retime(
        text: String, sourceStart: Double, sourceEnd: Double, languageTag: String, context: Double = 1,
        package: RecordingPackage, meta: RecordingMeta, audioSource: TranscriptAudioSource, aligner: ModelManifest,
        alignerDirectory: URL, runtimeDirectory: URL, worker: any SpeechWorker
    ) async throws -> (start: Double, end: Double)? {
        guard LanguageCapabilities.hasFineTiming(languageTag, engine: .qwen) else {
            throw TranscriptionError.unsupportedLanguage(languageTag)
        }
        let cache = package.url(PackageLayout.transcriptionCacheDirectory)
        let prepared = try await AudioPreparation.prepare(
            package: package, meta: meta, stream: audioSource.stream, directory: cache)
        let sr = Double(PreparedAudio.sampleRate)
        let origin = prepared.originSample
        let start = max(0, Int64((sourceStart - context) * sr) - origin)
        let end = min(prepared.sampleCount, Int64((sourceEnd + context) * sr) - origin)
        guard end > start else { return nil }
        let window = WorkWindow(
            index: 0, owned: SampleRange(start: start, end: end), read: SampleRange(start: start, end: end))
        try await load(.qwenAligner, directory: alignerDirectory, runtime: runtimeDirectory, worker)
        let response = try await worker.send(
            .align(
                audioPath: cache.appending(path: prepared.samplesFileName).path, window: window, text: text,
                languageTag: languageTag))
        _ = try? await worker.send(.unload)
        guard case .aligned(let aligned) = response else {
            if case .failure(let failure, let message) = response {
                throw TranscriptionError.workerFailure(failure, message)
            }
            return nil
        }
        let timed = aligned.items.filter { $0.endSample > $0.startSample }
        guard let first = timed.first, let last = timed.last else { return nil }
        let s = Double(origin + start + first.startSample) / sr
        let e = Double(origin + start + last.endSample) / sr
        return e > s ? (s, e) : nil
    }

    static func alignmentKey(_ recognitionKey: String, _ window: RecognisedWindow, _ aligner: ModelManifest) -> String {
        Fingerprint.of(strings: [
            recognitionKey, String(window.window.index), window.text, aligner.digest, window.languageTag ?? "",
        ])
    }

    private static func load(
        _ role: WorkerModelRole, directory: URL, runtime: URL?, _ worker: any SpeechWorker
    ) async throws {
        let response = try await worker.send(
            .load(role: role, directory: directory.path, runtimeDirectory: runtime?.path ?? ""))
        switch response {
        case .loaded: return
        case .failure(.unsupportedPlatform, _): throw TranscriptionError.unsupportedPlatform
        case .failure(let failure, let message):
            throw TranscriptionError.modelInitialisation("\(failure.rawValue): \(message)")
        default: throw TranscriptionError.workerFailure(.badRequest, "Unexpected load response")
        }
    }

    private static func recognise(
        _ window: WorkWindow, audioPath: String, hint: String?, _ worker: any SpeechWorker
    ) async throws -> RecognisedWindow {
        let response = try await worker.send(
            .recognise(audioPath: audioPath, window: window, languageHint: hint, tokenBudget: nil))
        switch response {
        case .recognised(let result):
            guard result.window == window else {
                throw TranscriptionError.workerFailure(.badRequest, "Window mismatch")
            }
            return result
        case .failure(let failure, let message): throw TranscriptionError.workerFailure(failure, message)
        default: throw TranscriptionError.workerFailure(.badRequest, "Unexpected recognition response")
        }
    }

    private static func checkCancelled() throws {
        if Task.isCancelled { throw TranscriptionError.cancelled }
    }
}

/// Per-window artefacts under `cache/transcription/<recognitionKey>/`, so an interrupted job resumes at the last
/// finished window and alignment can be retried without recognising again. Atomic writes; unreadable files are
/// ignored (the window is simply redone).
public struct CheckpointStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func recognised(_ index: Int) -> RecognisedWindow? {
        read(RecognisedWindow.self, "w-\(index).json")
    }

    public func aligned(_ key: String) -> AlignedWindow? { read(AlignedWindow.self, "a-\(key).json") }

    public func save(_ window: RecognisedWindow) throws { try write(window, "w-\(window.window.index).json") }

    public func save(_ window: AlignedWindow, key: String) throws { try write(window, "a-\(key).json") }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appending(path: name), options: .atomic)
    }
}
