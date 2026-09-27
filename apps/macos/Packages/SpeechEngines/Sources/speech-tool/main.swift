import Darwin
import Foundation
import ProjectKit
import SpeechCore
import SpeechEngines

// Developer tool: on-device smoke tests and benchmarks for the speech engines, using exactly the code the
// `MyScreenCamSpeech` service runs (in-process here). Build with xcodebuild (see docs/speech-integration.md).
//
//   speech-tool import-models <downloaded-dir> <models-root>        verify + install catalogue models from disk
//   speech-tool transcribe <pkg.mscam> <models-root> [--engine parakeet|qwen] [--language xx] [--source mic|system]
//                          [--out revision.json] [--cues] [--fresh]   (--fresh: ignore prepared audio/checkpoints)
//   speech-tool compare-aligners <pkg.mscam> <models-root> <other-aligner-dir> [--language xx] [--out both.json]

struct LocalWorker: SpeechWorker {
    let engine: InferenceEngine
    func send(_ request: WorkerRequest) async throws -> WorkerResponse { await engine.handle(request) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Peak resident footprint of this process, bytes.
func peakMemory() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func mb(_ bytes: Int) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: speech-tool import-models|transcribe|compare-aligners …")
}

switch command {
case "import-models":
    guard args.count >= 3 else { fail("usage: speech-tool import-models <downloaded-dir> <models-root>") }
    let source = URL(filePath: args[1], directoryHint: .isDirectory)
    let store = ModelStore(root: URL(filePath: args[2], directoryHint: .isDirectory))
    for model in ModelCatalogue.bundled.models {
        let dir = source.appending(path: model.id)
        guard FileManager.default.fileExists(atPath: dir.path) else { continue }
        let started = Date()
        do {
            try await store.importLocal(model, from: dir)
            print("installed \(model.id) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
            fail("\(model.id): \(error)")
        }
    }

case "transcribe":
    guard args.count >= 3 else { fail("usage: speech-tool transcribe <pkg> <models-root> [options]") }
    let package = RecordingPackage(url: URL(filePath: args[1], directoryHint: .isDirectory))
    let root = URL(filePath: args[2], directoryHint: .isDirectory)
    let engineName = option("--engine", in: args) ?? "parakeet"
    guard let engine = SpeechEngine(rawValue: engineName) else { fail("unknown engine \(engineName)") }
    let source: TranscriptAudioSource = option("--source", in: args) == "system" ? .systemAudio : .microphone
    let meta = try package.loadMeta()
    if args.contains("--fresh") {
        try? FileManager.default.removeItem(at: package.url(PackageLayout.transcriptionCacheDirectory))
    }
    let store = ModelStore(root: root)
    let models = try await store.acquireLease(engine)
    let job = TranscriptionJob(
        package: package, meta: meta, engine: engine, audioSource: source,
        languageHint: option("--language", in: args), models: models,
        modelDirectories: Dictionary(uniqueKeysWithValues: models.map { ($0.id, store.installDirectory(for: $0)) }),
        runtimeDirectories: Dictionary(uniqueKeysWithValues: models.map { ($0.id, store.runtimeDirectory(for: $0)) }),
        parentRevisionID: nil)
    let worker = LocalWorker(engine: InferenceEngine(modelsRoot: root))
    let started = Date()
    let stageTimes = StageClock()
    let revision = try await TranscriptionPipeline.run(
        job, worker: worker, implementation: InferenceEngine.implementation,
        progress: { stage in stageTimes.mark(stage) })
    let elapsed = Date().timeIntervalSince(started)
    let words = revision.allUnits.count
    let fine = revision.allUnits.filter { $0.unit.timing?.isFine == true }.count
    print("engine      \(engine.rawValue)  status \(revision.status.rawValue)")
    print(
        "audio       \(String(format: "%.1f", meta.duration)) s  processing \(String(format: "%.2f", elapsed)) s  "
            + "RTFx \(String(format: "%.1f", meta.duration / max(elapsed, 0.001)))")
    for (stage, seconds) in stageTimes.durations() {
        print("  \(stage.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%.2f", seconds)) s")
    }
    print("peak memory \(mb(peakMemory()))")
    print("units       \(words) (\(fine) with fine timing)  segments \(revision.segments.count)")
    for warning in revision.warnings { print("warning     \(warning)") }
    if let out = option("--out", in: args) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(revision).write(to: URL(filePath: out))
    }
    if args.contains("--cues") {
        for cue in CueBuilder.cues(from: revision) {
            print(String(format: "%7.2f–%7.2f  ", cue.start, cue.end) + (cue.coarse ? "[coarse] " : "") + cue.text)
        }
    } else {
        for segment in revision.segments { print(segment.rawText) }
    }
    await store.releaseLease(engine)

case "compare-aligners":
    guard args.count >= 4 else { fail("usage: speech-tool compare-aligners <pkg> <models-root> <other-aligner-dir>") }
    // Aligns the same Qwen recognition with the installed 8-bit aligner and another checkpoint directory (e.g. the
    // BF16 one, imported under the models root), and reports the boundary differences between them.
    let package = RecordingPackage(url: URL(filePath: args[1], directoryHint: .isDirectory))
    let root = URL(filePath: args[2], directoryHint: .isDirectory)
    let other = URL(filePath: args[3], directoryHint: .isDirectory)
    let meta = try package.loadMeta()
    let store = ModelStore(root: root)
    let models = try await store.acquireLease(.qwen)
    let worker = LocalWorker(engine: InferenceEngine(modelsRoot: root))
    func run(alignerDirectory: URL) async throws -> TranscriptRevision {
        var dirs = Dictionary(uniqueKeysWithValues: models.map { ($0.id, store.installDirectory(for: $0)) })
        dirs[ModelCatalogue.qwenAlignerID] = alignerDirectory
        let runtime = root.appending(path: ModelStore.runtimeDirectoryName).appending(
            path: alignerDirectory.lastPathComponent)
        var runtimes = Dictionary(uniqueKeysWithValues: models.map { ($0.id, store.runtimeDirectory(for: $0)) })
        runtimes[ModelCatalogue.qwenAlignerID] = runtime
        let job = TranscriptionJob(
            package: package, meta: meta, engine: .qwen, audioSource: .microphone,
            languageHint: option("--language", in: args), models: models, modelDirectories: dirs,
            runtimeDirectories: runtimes, parentRevisionID: nil)
        return try await TranscriptionPipeline.run(job, worker: worker, implementation: InferenceEngine.implementation)
    }
    /// Alignment checkpoints are keyed by the catalogue aligner; clear them so each run really aligns.
    func clearAlignmentCheckpoints() {
        let cache = package.url(PackageLayout.transcriptionCacheDirectory)
        let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)?.allObjects ?? []
        for case let file as URL in files where file.lastPathComponent.hasPrefix("a-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
    clearAlignmentCheckpoints()
    let a = try await run(alignerDirectory: store.installDirectory(for: models[1]))
    clearAlignmentCheckpoints()
    let b = try await run(alignerDirectory: other)
    clearAlignmentCheckpoints()
    if let out = option("--out", in: args) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([a, b]).write(to: URL(filePath: out))
    }
    var diffs: [Double] = []
    for (ua, ub) in zip(a.allUnits, b.allUnits) {
        guard let ta = ua.unit.timing, let tb = ub.unit.timing else { continue }
        diffs.append(abs(ta.sourceRange.startSeconds - tb.sourceRange.startSeconds))
        diffs.append(abs(ta.sourceRange.endSeconds - tb.sourceRange.endSeconds))
    }
    diffs.sort()
    guard !diffs.isEmpty else { fail("no comparable timings") }
    let median = diffs[diffs.count / 2]
    let p95 = diffs[min(diffs.count - 1, Int(Double(diffs.count) * 0.95))]
    print(
        String(
            format: "boundaries %d  median |Δ| %.0f ms  p95 |Δ| %.0f ms  max %.0f ms", diffs.count, median * 1000,
            p95 * 1000, (diffs.last ?? 0) * 1000))
    await store.releaseLease(.qwen)

default:
    fail("unknown command \(command)")
}

/// Wall time per stage title.
final class StageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (String, Date)?
    private var totals: [(String, Double)] = []

    func mark(_ stage: TranscriptionStage) {
        lock.lock()
        defer { lock.unlock() }
        let name = String(describing: stage).components(separatedBy: "(").first ?? ""
        if current?.0 == name { return }
        if let (previous, start) = current { totals.append((previous, Date().timeIntervalSince(start))) }
        current = (name, Date())
    }

    func durations() -> [(String, Double)] {
        lock.lock()
        defer { lock.unlock() }
        var result = totals
        if let (name, start) = current { result.append((name, Date().timeIntervalSince(start))) }
        return result
    }
}
