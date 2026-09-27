import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import ProjectKit
@testable import SpeechCore

/// Serves canned bodies for URLs, like a model host.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = Mutex<[String: Data]>([:])
    static let requests = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!.absoluteString
        Self.requests.withLock { $0.append(url) }
        guard let body = Self.bodies.withLock({ $0[url] }) else {
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

enum StoreFixtures {
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).hexString }

    /// A one-engine catalogue whose files are served by `StubProtocol` (with optionally corrupted bodies).
    static func catalogue(files: [String: Data], corrupt: Set<String> = []) -> ModelCatalogue {
        let manifest = ModelManifest(
            id: ModelCatalogue.parakeetID, repository: "test/model-\(UUID().uuidString.prefix(6))", revision: "abc123",
            format: "coreml", quantisation: "int8", license: "CC-BY-4.0", attribution: "Test",
            files: files.keys.sorted().map { .init(path: $0, size: Int64(files[$0]!.count), sha256: sha(files[$0]!)) })
        StubProtocol.bodies.withLock { bodies in
            for file in manifest.files {
                var body = files[file.path]!
                if corrupt.contains(file.path) { body[0] ^= 0xFF }
                bodies[manifest.downloadURL(for: file).absoluteString] = body
            }
        }
        return ModelCatalogue(schemaVersion: 1, models: [manifest])
    }

    static let files: [String: Data] = [
        "Encoder.mlmodelc/weights/weight.bin": Data((0..<200_000).map { UInt8($0 % 251) }),
        "vocab.json": Data("{\"0\":\"a\"}".utf8),
    ]
}

@Suite(.serialized)
struct ModelStoreTests {
    @Test func bundledCatalogueIsPinnedAndComplete() {
        let catalogue = ModelCatalogue.bundled
        #expect(
            catalogue.models.map(\.id).sorted()
                == [
                    ModelCatalogue.parakeetID, ModelCatalogue.qwenAlignerID, ModelCatalogue.qwenASRID,
                ].sorted())
        for model in catalogue.models {
            #expect(model.revision.count == 40)
            #expect(!model.files.isEmpty)
            #expect(
                model.files.allSatisfy {
                    $0.sha256.count == 64 && $0.size > 0 && ModelStore.isSafeRelativePath($0.path)
                })
        }
        #expect(catalogue.downloadBytes(for: .parakeet) > 600_000_000)
        #expect(catalogue.downloadBytes(for: .qwen) > 3_500_000_000)
    }

    @Test func downloadsVerifiesAndInstallsAtomically() async throws {
        let dir = try TempDir()
        let catalogue = StoreFixtures.catalogue(files: StoreFixtures.files)
        let store = ModelStore(root: dir.url, catalogue: catalogue, session: StubProtocol.session())
        #expect(await store.state(ModelCatalogue.parakeetID) == .notInstalled)
        let updates = await store.updates()
        let seen = Task {
            var states: [ModelInstallState] = []
            for await all in updates {
                let state = all[ModelCatalogue.parakeetID] ?? .notInstalled
                states.append(state)
                if state == .installed { break }
            }
            return states
        }
        await store.install(.parakeet)
        await store.waitForInstall(.parakeet)
        let states = await seen.value
        #expect(states.contains { if case .downloading = $0 { true } else { false } })
        #expect(states.contains { if case .verifying = $0 { true } else { false } })
        #expect(await store.isInstalled(.parakeet))
        let model = catalogue.models[0]
        let installed = store.installDirectory(for: model)
        #expect(FileManager.default.fileExists(atPath: installed.appending(path: ModelStore.verifiedMarker).path))
        #expect(try Data(contentsOf: installed.appending(path: "vocab.json")) == StoreFixtures.files["vocab.json"])
        #expect(!FileManager.default.fileExists(atPath: store.stagingDirectory(for: model).path))
        // A new store instance sees the installation without the network.
        let reopened = ModelStore(root: dir.url, catalogue: catalogue, session: StubProtocol.session())
        #expect(await reopened.isInstalled(.parakeet))
    }

    @Test func hashMismatchFailsAndNeverInstalls() async throws {
        let dir = try TempDir()
        let catalogue = StoreFixtures.catalogue(files: StoreFixtures.files, corrupt: ["vocab.json"])
        let store = ModelStore(root: dir.url, catalogue: catalogue, session: StubProtocol.session())
        await store.install(.parakeet)
        await store.waitForInstall(.parakeet)
        guard case .failed(let message) = await store.state(ModelCatalogue.parakeetID) else {
            Issue.record("expected failure")
            return
        }
        #expect(message.contains("checksum"))
        #expect(!FileManager.default.fileExists(atPath: store.installDirectory(for: catalogue.models[0]).path))
    }

    @Test func refusesUnsafePaths() {
        #expect(!ModelStore.isSafeRelativePath("../escape"))
        #expect(!ModelStore.isSafeRelativePath("/abs"))
        #expect(!ModelStore.isSafeRelativePath("a//b"))
        #expect(!ModelStore.isSafeRelativePath("a/./b"))
        #expect(ModelStore.isSafeRelativePath("Encoder.mlmodelc/weights/weight.bin"))
    }

    @Test func leasesBlockRemovalAndRemovalCleansUp() async throws {
        let dir = try TempDir()
        let source = dir.url.appending(path: "download")
        for (path, data) in StoreFixtures.files {
            let url = source.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let catalogue = StoreFixtures.catalogue(files: StoreFixtures.files)
        let root = dir.url.appending(path: "Models")
        let store = ModelStore(root: root, catalogue: catalogue, session: StubProtocol.session())
        try await store.importLocal(catalogue.models[0], from: source)
        _ = try await store.acquireLease(.parakeet)
        await #expect(throws: ModelStoreError.inUse) { try await store.remove(.parakeet) }
        await store.releaseLease(.parakeet)
        try await store.remove(.parakeet)
        #expect(await store.state(ModelCatalogue.parakeetID) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: store.installDirectory(for: catalogue.models[0]).path))
    }

    @Test func rateMeterAveragesOverTheWindow() {
        let clock = Mutex(0.0)
        let meter = RateMeter(window: 3) { clock.withLock { $0 } }
        #expect(meter.record(0) == nil)
        clock.withLock { $0 = 1 }
        #expect(meter.record(1_000) == nil)  // not enough data yet
        clock.withLock { $0 = 2 }
        #expect(meter.record(3_000) == 1_500)
        clock.withLock { $0 = 5 }
        #expect(meter.record(6_000) == 1_000)  // the 3 s window dropped the first sample
        let progress = DownloadProgress(completedBytes: 3_000, totalBytes: 6_000, bytesPerSecond: 1_500)
        #expect(progress.fraction == 0.5)
        #expect(progress.secondsRemaining == 2)
    }
}

/// A worker that "recognises" each window as `word<index>` spoken over its first half.
actor FakeWorker: SpeechWorker {
    var requests: [WorkerRequest] = []
    var truncateFirstQwenWindow = false
    var failAfter: Int?

    func setTruncateFirstQwenWindow(_ value: Bool) { truncateFirstQwenWindow = value }

    func send(_ request: WorkerRequest) async throws -> WorkerResponse {
        requests.append(request)
        switch request {
        case .load(let role, _, _): return .loaded(role: role, seconds: 0)
        case .unload, .shutdown: return .ok
        case .handshake:
            return .capabilities(WorkerCapabilities(protocolVersion: 1, implementation: [:], supported: true))
        case .recognise(_, let window, _, let budget):
            let text = "word\(window.index)"
            let mid = (window.owned.start + window.owned.end) / 2
            if truncateFirstQwenWindow, window.index == 0 {
                return .recognised(
                    RecognisedWindow(
                        window: window, text: text, languageTag: "en", units: [], termination: .tokenBudgetExhausted,
                        generatedTokens: 1, tokenBudget: budget ?? 1, processingSeconds: 0))
            }
            return .recognised(
                RecognisedWindow(
                    window: window, text: text, languageTag: "en",
                    units: [
                        RecognisedUnit(
                            utf8Start: 0, utf8End: text.utf8.count, kind: .word, startSample: window.owned.start,
                            endSample: mid, method: .tdt)
                    ], termination: .complete, processingSeconds: 0))
        case .align(_, let window, let text, _):
            let tokens = AlignmentMapper.tokens(text, chineseMode: false)
            return .aligned(
                AlignedWindow(
                    windowIndex: window.index,
                    items: tokens.map { AlignedItem(text: $0.text, startSample: 0, endSample: 1_600) },
                    processingSeconds: 0))
        }
    }

    func count(where predicate: (WorkerRequest) -> Bool) -> Int { requests.filter(predicate).count }
}

@Suite(.serialized)
struct TranscriptionPipelineTests {
    /// A package with `seconds` of tone on the microphone and fake installed model directories.
    func makeJob(_ dir: TempDir, engine: SpeechEngine, seconds: Double = 200) throws -> TranscriptionJob {
        let package = try RecordingPackage.create(in: dir.url)
        let meta = AudioFixtures.meta(duration: seconds, micOffset: 0.5)
        try package.saveMeta(meta)
        try AudioFixtures.writeTone(to: package.url(for: .microphone), seconds: seconds - 0.5, onset: 0, aac: true)
        let models = ModelCatalogue.bundled.manifests(for: engine)
        return TranscriptionJob(
            package: package, meta: meta, engine: engine, audioSource: .microphone, languageHint: nil, models: models,
            modelDirectories: Dictionary(uniqueKeysWithValues: models.map { ($0.id, dir.url.appending(path: $0.id)) }),
            runtimeDirectories: [:], parentRevisionID: nil)
    }

    @Test func parakeetRunCoversTheAudioAndResumesFromCheckpoints() async throws {
        let dir = try TempDir()
        let job = try makeJob(dir, engine: .parakeet)
        let worker = FakeWorker()
        let revision = try await TranscriptionPipeline.run(job, worker: worker, implementation: ["fake": "1"])
        #expect(revision.status == .complete)
        #expect(revision.segments.count == 3)  // 199.5 s of uniform tone → cuts at the 90 s midpoints
        #expect(revision.segments[0].units[0].timing?.sourceRange.startSeconds == 0.5)
        #expect(abs((revision.sourceCoverage.last?.endSeconds ?? 0) - 200) < 0.05)
        let first = await worker.count { if case .recognise = $0 { true } else { false } }
        #expect(first == 3)

        // Same job again: every window comes from the checkpoints; the model isn't even loaded.
        let again = FakeWorker()
        let second = try await TranscriptionPipeline.run(job, worker: again, implementation: ["fake": "1"])
        #expect(await again.count { if case .recognise = $0 { true } else { false } } == 0)
        #expect(await again.count { if case .load = $0 { true } else { false } } == 0)
        #expect(second.segments.map(\.rawText) == revision.segments.map(\.rawText))
    }

    @Test func qwenRetriesATruncatedWindowAndAlignsAfterUnloading() async throws {
        let dir = try TempDir()
        let job = try makeJob(dir, engine: .qwen, seconds: 70)
        let worker = FakeWorker()
        await worker.setTruncateFirstQwenWindow(true)
        let revision = try await TranscriptionPipeline.run(job, worker: worker, implementation: ["fake": "1"])
        let requests = await worker.requests
        // The truncated first window was redone as smaller windows, which completed.
        #expect(revision.status == .complete)
        #expect(requests.filter { if case .recognise = $0 { true } else { false } }.count > 3)
        // Recogniser unloaded before the aligner was loaded; never both.
        let roles = requests.compactMap { request -> String? in
            switch request {
            case .load(let role, _, _): role.rawValue
            case .unload: "unload"
            default: nil
            }
        }
        let alignerLoad = try #require(roles.firstIndex(of: WorkerModelRole.qwenAligner.rawValue))
        #expect(roles[alignerLoad - 1] == "unload")
        #expect(revision.aligner?.catalogueID == ModelCatalogue.qwenAlignerID)
        #expect(revision.allUnits.allSatisfy { $0.unit.timing?.method == .forcedAlignment })
    }

    @Test func cancellationStopsBeforeCommitting() async throws {
        let dir = try TempDir()
        let job = try makeJob(dir, engine: .parakeet)
        let task = Task { try await TranscriptionPipeline.run(job, worker: FakeWorker(), implementation: [:]) }
        task.cancel()
        await #expect(throws: TranscriptionError.cancelled) { try await task.value }
    }

    @Test func unsupportedLanguageHintIsRefused() async throws {
        let dir = try TempDir()
        var job = try makeJob(dir, engine: .parakeet, seconds: 5)
        job.languageHint = "ja"
        await #expect(throws: TranscriptionError.unsupportedLanguage("ja")) {
            try await TranscriptionPipeline.run(job, worker: FakeWorker(), implementation: [:])
        }
    }

    @Test func workerPathPolicyOnlyAllowsVerifiedModelsAndPreparedAudio() throws {
        let dir = try TempDir()
        let root = dir.url.appending(path: "Models")
        let model = root.appending(path: "m/rev")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let policy = WorkerPathPolicy(modelsRoot: root)
        #expect(policy.modelDirectory(model.path) == nil)  // no marker yet
        try Data().write(to: model.appending(path: ModelStore.verifiedMarker))
        #expect(policy.modelDirectory(model.path) != nil)
        #expect(policy.modelDirectory(dir.url.path) == nil)
        #expect(policy.modelDirectory(model.path + "/../../..") == nil)
        #expect(policy.audioFile("/etc/passwd") == nil)
        #expect(policy.runtimeDirectory(root.appending(path: ".runtime/x").path) != nil)
        #expect(policy.runtimeDirectory(dir.url.appending(path: "elsewhere").path) == nil)
    }

    @Test func protocolRoundTripsAndRejectsOversizedMessages() throws {
        let request = WorkerRequest.recognise(
            audioPath: "/x.f32",
            window: WorkWindow(index: 1, owned: SampleRange(start: 0, end: 5), read: SampleRange(start: 0, end: 6)),
            languageHint: "de", tokenBudget: nil)
        #expect(try WorkerCoding.decode(WorkerRequest.self, from: WorkerCoding.encode(request)) == request)
        let unicode = WorkerResponse.recognised(
            RecognisedWindow(
                window: WorkWindow(index: 0, owned: SampleRange(start: 0, end: 1), read: SampleRange(start: 0, end: 1)),
                text: "naïve 你好\nline", languageTag: "zh", units: [], termination: .complete, processingSeconds: 0))
        #expect(try WorkerCoding.decode(WorkerResponse.self, from: WorkerCoding.encode(unicode)) == unicode)
        #expect(throws: WorkerFailure.oversizedRequest) {
            try WorkerCoding.decode(WorkerRequest.self, from: Data(count: WorkerCoding.maxMessageBytes + 1))
        }
    }
}
