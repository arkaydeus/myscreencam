import AVFoundation
import CryptoKit
import ExportKit
import Foundation
import ProjectKit
import SpeechCore
import Testing

@testable import MyScreenCam

/// A worker with exactly one loaded role; the first recognition can be held while re-time is requested.
nonisolated private final class PausingSpeechClient: SpeechServiceManaging, @unchecked Sendable {
    private struct State {
        var loaded: WorkerModelRole?
        var lastLoaded: WorkerModelRole?
        var holdRecognition = true
        var crashFirstRecognition = false
        var recognitionCount = 0
        var recognitionStarted = false
        var recognitionWaiters: [CheckedContinuation<Void, Never>] = []
        var heldRecognition: CheckedContinuation<Void, Never>?
        var failures: [WorkerFailure] = []
    }

    private let lock = NSLock()
    private var state: State

    init(holdRecognition: Bool = true, crashFirstRecognition: Bool = false) {
        state = State(holdRecognition: holdRecognition, crashFirstRecognition: crashFirstRecognition)
    }

    var failures: [WorkerFailure] { lock.withLock { state.failures } }
    var recognitionCount: Int { lock.withLock { state.recognitionCount } }

    func waitForRecognition() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if state.recognitionStarted { return true }
                state.recognitionWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    nonisolated func resumeRecognition() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            state.holdRecognition = false
            defer { state.heldRecognition = nil }
            return state.heldRecognition
        }
        held?.resume()
    }

    nonisolated func release() { lock.withLock { state.loaded = nil } }
    nonisolated func reset() {
        lock.withLock {
            state.loaded = nil
            state.lastLoaded = nil
        }
    }

    func send(_ request: WorkerRequest) async throws -> WorkerResponse {
        switch request {
        case .handshake:
            return .capabilities(WorkerCapabilities(protocolVersion: 1, implementation: ["test": "1"], supported: true))
        case .load(let role, _, _):
            lock.withLock {
                state.loaded = role
                state.lastLoaded = role
            }
            return .loaded(role: role, seconds: 0)
        case .unload, .shutdown:
            reset()
            return .ok
        case .recognise(_, let window, _, _):
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                state.recognitionStarted = true
                state.recognitionCount += 1
                defer { state.recognitionWaiters.removeAll() }
                return state.recognitionWaiters
            }
            for waiter in waiters { waiter.resume() }
            try await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let held = lock.withLock { () -> Bool in
                        if !state.holdRecognition { return false }
                        state.heldRecognition = continuation
                        return true
                    }
                    if !held { continuation.resume() }
                }
                try Task.checkCancellation()
            } onCancel: {
                self.resumeRecognition()
            }
            if lock.withLock({ state.crashFirstRecognition && state.recognitionCount == 1 }) {
                throw TranscriptionError.workerCrashed
            }
            let role = lock.withLock { () -> WorkerModelRole? in
                if state.loaded == nil { state.loaded = state.lastLoaded }
                return state.loaded
            }
            guard role == .qwenRecogniser else {
                lock.withLock { state.failures.append(.noModelLoaded) }
                return .failure(.noModelLoaded, message: "recogniser was replaced")
            }
            return .recognised(
                RecognisedWindow(
                    window: window, text: "word", languageTag: "en", units: [], termination: .complete,
                    processingSeconds: 0))
        case .align(_, let window, let text, _):
            let role = lock.withLock { () -> WorkerModelRole? in
                if state.loaded == nil { state.loaded = state.lastLoaded }
                return state.loaded
            }
            guard role == .qwenAligner else {
                lock.withLock { state.failures.append(.noModelLoaded) }
                return .failure(.noModelLoaded, message: "aligner was replaced")
            }
            return .aligned(
                AlignedWindow(
                    windowIndex: window.index,
                    items: [AlignedItem(text: text, startSample: 0, endSample: 1_600)], processingSeconds: 0))
        }
    }
}

@MainActor
struct TranscriptionCenterTests {
    private func fixture() async throws -> (root: URL, package: RecordingPackage, models: SpeechModels) {
        let root = FileManager.default.temporaryDirectory.appending(path: "msc-center-test-\(UUID().uuidString)")
        let package = try RecordingPackage.create(in: root)
        let meta = RecordingMeta(
            name: "Speech", duration: 2.5, source: .display(displayID: 1, name: "Test"),
            screen: ScreenStreamInfo(
                pixelWidth: 320, pixelHeight: 180, scale: 1, frameRate: 30, codec: "avc1",
                contentRectPoints: RectPoints(x: 0, y: 0, width: 320, height: 180)),
            microphone: AudioDeviceInfo(deviceID: "mic", name: "Mic"),
            streams: [.microphone: StreamTiming(startOffset: 0.5)])
        try package.saveMeta(meta)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let audio = try AVAudioFile(
            forWriting: package.url(for: .microphone),
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = 0.2 * sin(2 * Float.pi * 440 * Float(index) / 48_000)
        }
        try audio.write(from: buffer)

        let bytes = Data("tiny test model".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifests = SpeechEngine.qwen.modelIDs.map { id in
            ModelManifest(
                id: id, repository: "test/\(id)", revision: "test", format: "test", quantisation: "none",
                license: "test", attribution: "test",
                files: [ModelManifest.File(path: "model.bin", size: Int64(bytes.count), sha256: hash)])
        }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try bytes.write(to: source.appending(path: "model.bin"))
        let store = ModelStore(
            root: root.appending(path: "Models"), catalogue: ModelCatalogue(schemaVersion: 1, models: manifests))
        for manifest in manifests { try await store.importLocal(manifest, from: source) }
        let models = SpeechModels(store: store)
        for _ in 0..<100 where !models.isInstalled(.qwen) { await Task.yield() }
        #expect(models.isInstalled(.qwen))
        return (root, package, models)
    }

    @Test func retimeWaitsForRunningTranscriptionAndBothKeepTheirModel() async throws {
        let (root, package, models) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = PausingSpeechClient()
        let center = TranscriptionCenter(models: models, client: worker)
        let job = try #require(center.transcribe(package.url, engine: .qwen))
        await worker.waitForRecognition()
        let retime = Task {
            try await center.retime(
                text: "word", start: 1, end: 1.5, languageTag: "en", packageURL: package.url,
                audioSource: .microphone)
        }
        for _ in 0..<100 where !center.isRetiming { await Task.yield() }
        #expect(center.isRetiming)
        worker.resumeRecognition()
        await center.waitUntilIdle()
        guard case .succeeded = job.phase else {
            Issue.record("Transcription did not finish: \(job.statusText)"); return
        }
        let result = try await retime.value
        #expect(result != nil)
        #expect(worker.failures.isEmpty)
        #expect(try package.loadEdit()?.subtitles.revisionID != nil)
    }

    @Test func crashedWorkerRetriesOnceAndCommitsAdoptedThenCandidate() async throws {
        let (root, package, models) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = PausingSpeechClient(holdRecognition: false, crashFirstRecognition: true)
        let center = TranscriptionCenter(models: models, client: worker)
        let first = try #require(center.transcribe(package.url, engine: .qwen))
        await center.waitUntilIdle()
        #expect(worker.recognitionCount == 2)
        #expect(first.phase == .succeeded(.adopted))
        var edit = try #require(try package.loadEdit())
        #expect(!edit.subtitles.cues.isEmpty)
        edit.subtitles.cues[0].text = "Corrected by user"
        try package.saveEdit(edit)

        let second = try #require(center.transcribe(package.url, engine: .qwen))
        await center.waitUntilIdle()
        #expect(second.phase == .succeeded(.candidate))
        #expect(try package.loadEdit()?.subtitles.candidateRevisionID != nil)
    }

    @Test func qwenWaitsForExportThenResumes() async throws {
        let (root, package, models) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = ExportCenter { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        let worker = PausingSpeechClient(holdRecognition: false)
        let center = TranscriptionCenter(models: models, client: worker)
        center.exports = exports
        let meta = try package.loadMeta()
        let export = exports.start(
            package: package, name: "Busy", edit: EditConfig.initial(for: meta),
            settings: ExportSettings(format: .h264),
            destination: root.appending(path: "busy.mp4"))
        let job = try #require(center.transcribe(package.url, engine: .qwen))
        for _ in 0..<200 {
            if case .held = job.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .held = job.phase else {
            export.cancel()
            Issue.record("Qwen did not pause for export")
            return
        }
        #expect(worker.recognitionCount == 0)
        export.cancel()
        await exports.waitUntilIdle()
        await center.waitUntilIdle()
        #expect(job.phase == .succeeded(.adopted))
    }

    @Test func cancellingRunningJobStopsBeforeCommit() async throws {
        let (root, package, models) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = PausingSpeechClient()
        let center = TranscriptionCenter(models: models, client: worker)
        let job = try #require(center.transcribe(package.url, engine: .qwen))
        await worker.waitForRecognition()
        center.cancel(package.url)
        await center.waitUntilIdle()
        #expect(job.phase == .cancelled)
        #expect(try package.loadEdit()?.subtitles.revisionID == nil)
    }

    @Test func criticalMemoryHoldsAndThenResumesJob() async throws {
        let (root, package, models) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = PausingSpeechClient(holdRecognition: false)
        let center = TranscriptionCenter(models: models, client: worker)
        center.memoryPressureChanged(critical: true)
        let job = try #require(center.transcribe(package.url, engine: .qwen))
        for _ in 0..<200 {
            if case .held = job.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .held = job.phase else { Issue.record("Memory pressure did not hold the job"); return }
        #expect(worker.recognitionCount == 0)
        center.memoryPressureChanged(critical: false)
        await center.waitUntilIdle()
        #expect(job.phase == .succeeded(.adopted))
    }
}
