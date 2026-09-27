import CryptoKit
import Foundation
import MyScreenArtCore

/// Install state of one catalogue model (spec §7). `preparing`/`ready` (a loaded runtime) are tracked by the
/// transcription service, not here: an installed model isn't necessarily warm.
public enum ModelInstallState: Sendable, Equatable {
    case notInstalled
    case downloading(DownloadProgress)
    case verifying(fraction: Double)
    case installed
    case failed(String)
    case removing
}

/// Download progress with a smoothed rate.
public struct DownloadProgress: Sendable, Equatable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    /// Bytes per second over the last few seconds; nil until there's enough data.
    public var bytesPerSecond: Double?

    public init(completedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }

    /// Seconds left at the current rate.
    public var secondsRemaining: Double? {
        guard let rate = bytesPerSecond, rate > 1 else { return nil }
        return Double(max(0, totalBytes - completedBytes)) / rate
    }
}

public enum ModelStoreError: Error, Sendable, Equatable, LocalizedError {
    case unknownModel(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case hashMismatch(String)
    case sizeMismatch(String)
    case unsafePath(String)
    case inUse
    case cancelled
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): "Unknown model \(id)."
        case .insufficientDiskSpace(let needed, let available):
            "Not enough disk space: \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed, "
                + "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available."
        case .hashMismatch(let path): "\(path) didn't match its checksum."
        case .sizeMismatch(let path): "\(path) has the wrong size."
        case .unsafePath(let path): "Refused an unsafe file path: \(path)."
        case .inUse: "The model is in use by a transcription."
        case .cancelled: "Cancelled."
        case .network(let message): message
        }
    }
}

/// The single owner of model installations under `root` (normally
/// `~/Library/Application Support/<app bundle id>/Models`):
///
/// ```
/// Models/<id>/<revision>/      a complete, verified installation (+ `.verified`)
/// Models/.staging/<id>-<rev>/  partial downloads (kept across launches so downloads resume)
/// Models/.runtime/<id>-<rev>/  files the SDKs derive at load time (never inside the verified snapshot)
/// Models/.trash/               installations being removed
/// ```
///
/// Installation is a transaction: check disk space → download into staging → verify every size and SHA-256 →
/// write the marker → rename into place. A partially populated folder is never reported as installed. Removal
/// waits for no active lease.
public actor ModelStore {
    public static let verifiedMarker = ".verified"
    public static let runtimeDirectoryName = ".runtime"
    static let stagingDirectoryName = ".staging"
    static let trashDirectoryName = ".trash"

    public nonisolated let root: URL
    public nonisolated let catalogue: ModelCatalogue
    private let downloader: ModelDownloader
    private let capacity: @Sendable (URL) -> Int64?
    private var states: [String: ModelInstallState] = [:]
    private var leases: [String: Int] = [:]
    private var tasks: [SpeechEngine: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[String: ModelInstallState]>.Continuation] = [:]

    public static func defaultRoot(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.myscreenart.app")
        -> URL
    {
        URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    public init(
        root: URL, catalogue: ModelCatalogue = .bundled, session: URLSession = .shared,
        capacity: (@Sendable (URL) -> Int64?)? = nil
    ) {
        self.root = root
        self.catalogue = catalogue
        downloader = ModelDownloader(session: session)
        self.capacity = capacity ?? { ModelStore.availableCapacity(at: $0) }
        for model in catalogue.models {
            states[model.id] = Self.isInstalled(model, root: root) ? .installed : .notInstalled
        }
    }

    // MARK: Queries

    public nonisolated func installDirectory(for model: ModelManifest) -> URL {
        root.appending(path: model.id, directoryHint: .isDirectory).appending(
            path: model.revision, directoryHint: .isDirectory)
    }

    public nonisolated func runtimeDirectory(for model: ModelManifest) -> URL {
        root.appending(path: Self.runtimeDirectoryName, directoryHint: .isDirectory)
            .appending(path: "\(model.id)-\(model.revision)", directoryHint: .isDirectory)
    }

    nonisolated func stagingDirectory(for model: ModelManifest) -> URL {
        root.appending(path: Self.stagingDirectoryName, directoryHint: .isDirectory)
            .appending(path: "\(model.id)-\(model.revision)", directoryHint: .isDirectory)
    }

    public func state(_ id: String) -> ModelInstallState { states[id] ?? .notInstalled }

    public func allStates() -> [String: ModelInstallState] { states }

    public func isInstalled(_ engine: SpeechEngine) -> Bool {
        engine.modelIDs.allSatisfy { states[$0] == .installed }
    }

    /// Streams every state change (starting with the current states).
    public func updates() -> AsyncStream<[String: ModelInstallState]> {
        let (stream, continuation) = AsyncStream<[String: ModelInstallState]>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(states)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func set(_ id: String, _ state: ModelInstallState) {
        states[id] = state
        for continuation in observers.values { continuation.yield(states) }
    }

    /// Bytes still to download for `engine` (partial staging files count as done).
    public func remainingBytes(for engine: SpeechEngine) -> Int64 {
        catalogue.manifests(for: engine).reduce(0) { total, model in
            guard states[model.id] != .installed else { return total }
            return total + model.files.reduce(0) { $0 + max(0, $1.size - stagedSize(model, $1)) }
        }
    }

    // MARK: Install

    /// Downloads and installs every missing model of `engine`, one file at a time. Returns immediately; follow
    /// progress through ``updates()``. Calling it again while running does nothing.
    public func install(_ engine: SpeechEngine) {
        guard tasks[engine] == nil else { return }
        let models = catalogue.manifests(for: engine)
        tasks[engine] = Task {
            for model in models where self.state(model.id) != .installed {
                guard await self.runInstall(model) else { break }
            }
            self.finishTask(engine)
        }
    }

    private func finishTask(_ engine: SpeechEngine) { tasks[engine] = nil }

    public func isInstalling(_ engine: SpeechEngine) -> Bool { tasks[engine] != nil }

    /// Cancels in-flight downloads for `engine`; partial files stay in staging so the next install resumes.
    public func cancelInstall(_ engine: SpeechEngine) {
        tasks[engine]?.cancel()
    }

    /// Waits for running installs of `engine` to finish (tests, quitting).
    public func waitForInstall(_ engine: SpeechEngine) async {
        await tasks[engine]?.value
    }

    /// True when the model ended up installed.
    private func runInstall(_ model: ModelManifest) async -> Bool {
        do {
            try await install(model)
            set(model.id, .installed)
            Log.app.info("Speech model installed: \(model.id, privacy: .public)@\(model.revision, privacy: .public)")
            return true
        } catch is CancellationError {
            set(model.id, .notInstalled)
        } catch ModelStoreError.cancelled {
            set(model.id, .notInstalled)
        } catch {
            Log.app.error("Speech model install failed: \(model.id, privacy: .public): \(error, privacy: .public)")
            set(model.id, .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
        return false
    }

    private func install(_ model: ModelManifest) async throws {
        for file in model.files {
            guard Self.isSafeRelativePath(file.path) else { throw ModelStoreError.unsafePath(file.path) }
        }
        let fm = FileManager.default
        let staging = stagingDirectory(for: model)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // Disk space: everything not yet staged, plus 5 % headroom (the final rename doesn't copy).
        let needed = model.files.reduce(Int64(0)) { $0 + max(0, $1.size - stagedSize(model, $1)) }
        let available = capacity(root)
        if let available, needed + needed / 20 > available {
            throw ModelStoreError.insufficientDiskSpace(needed: needed, available: available)
        }

        let total = model.totalBytes
        var done: Int64 = 0
        let meter = RateMeter()
        set(model.id, .downloading(DownloadProgress(completedBytes: 0, totalBytes: total, bytesPerSecond: nil)))
        // Largest first: the throughput estimate settles quickly instead of reflecting small-file request latency.
        for file in model.files.sorted(by: { $0.size > $1.size }) {
            try Task.checkCancellation()
            let destination = staging.appending(path: file.path)
            if stagedSize(model, file) == file.size {
                done += file.size
                continue
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let resumeURL = staging.appending(path: ".resume-\(file.sha256)")
            let (stream, continuation) = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let url = model.downloadURL(for: file)
            let downloader = self.downloader
            async let finished: Void = {
                defer { continuation.finish() }
                try await downloader.download(
                    url, to: destination, expectedSize: file.size, resumeDataURL: resumeURL
                ) { written in continuation.yield(written) }
            }()
            for await written in stream {
                let completed = base + written
                set(
                    model.id,
                    .downloading(
                        DownloadProgress(
                            completedBytes: completed, totalBytes: total, bytesPerSecond: meter.record(completed))))
            }
            do {
                try await finished
            } catch let error as URLError where error.code == .cancelled {
                throw ModelStoreError.cancelled
            }
            done += file.size
        }

        try verifyAndPromote(model)
    }

    /// Verifies every staged file (size, SHA-256, containment), writes the marker and renames the staging
    /// directory into place.
    private func verifyAndPromote(_ model: ModelManifest) throws {
        let fm = FileManager.default
        let staging = stagingDirectory(for: model)
        let total = model.totalBytes
        // Verify sizes, hashes and containment before anything counts as installed.
        set(model.id, .verifying(fraction: 0))
        var hashed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            let url = staging.appending(path: file.path)
            guard Self.isContained(url, in: staging) else { throw ModelStoreError.unsafePath(file.path) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            guard size == file.size else {
                try? fm.removeItem(at: url)
                throw ModelStoreError.sizeMismatch(file.path)
            }
            let before = hashed
            let digest = try Self.sha256(of: url) { bytes in
                self.set(model.id, .verifying(fraction: Double(before + bytes) / Double(max(total, 1))))
            }
            guard digest == file.sha256 else {
                try? fm.removeItem(at: url)
                throw ModelStoreError.hashMismatch(file.path)
            }
            hashed += file.size
        }
        for leftover in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] where leftover.hasPrefix(".resume-") {
            try? fm.removeItem(at: staging.appending(path: leftover))
        }
        let marker = try JSONEncoder().encode(["manifestDigest": model.digest, "revision": model.revision])
        try marker.write(to: staging.appending(path: Self.verifiedMarker), options: .atomic)

        // Promote atomically (same volume rename).
        let destination = installDirectory(for: model)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try moveToTrash(destination) }
        try fm.moveItem(at: staging, to: destination)
    }

    /// Installs `model` from files already on disk (offline installs, tests, developer tools): copies them into
    /// staging and runs the same verification and promotion as a download.
    public func importLocal(_ model: ModelManifest, from directory: URL) throws {
        let fm = FileManager.default
        let staging = stagingDirectory(for: model)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in model.files {
            guard Self.isSafeRelativePath(file.path) else { throw ModelStoreError.unsafePath(file.path) }
            let source = directory.appending(path: file.path)
            let destination = staging.appending(path: file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
        }
        do {
            try verifyAndPromote(model)
            set(model.id, .installed)
        } catch {
            set(model.id, .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            throw error
        }
    }

    // MARK: Leases and removal

    /// Marks `engine`'s models as in use until the lease is released; removal refuses meanwhile.
    public func acquireLease(_ engine: SpeechEngine) throws -> [ModelManifest] {
        let models = catalogue.manifests(for: engine)
        guard models.count == engine.modelIDs.count, models.allSatisfy({ states[$0.id] == .installed }) else {
            throw ModelStoreError.unknownModel(engine.rawValue)
        }
        for model in models { leases[model.id, default: 0] += 1 }
        return models
    }

    public func releaseLease(_ engine: SpeechEngine) {
        for id in engine.modelIDs { leases[id] = max(0, (leases[id] ?? 0) - 1) }
    }

    /// Removes `engine`'s installed models, staging and derived runtime files. Models shared with another
    /// installed engine are kept. Throws ``ModelStoreError/inUse`` while a transcription holds a lease.
    public func remove(_ engine: SpeechEngine, keeping other: SpeechEngine? = nil) async throws {
        let keep = Set(other?.modelIDs ?? [])
        let models = catalogue.manifests(for: engine).filter { !keep.contains($0.id) }
        guard models.allSatisfy({ (leases[$0.id] ?? 0) == 0 }) else { throw ModelStoreError.inUse }
        if let task = tasks[engine] {
            task.cancel()
            await task.value
        }
        for model in models {
            set(model.id, .removing)
            for url in [installDirectory(for: model), stagingDirectory(for: model), runtimeDirectory(for: model)]
            where FileManager.default.fileExists(atPath: url.path) {
                try moveToTrash(url)
            }
            set(model.id, .notInstalled)
        }
        emptyTrash()
    }

    private func moveToTrash(_ url: URL) throws {
        let trash = root.appending(path: Self.trashDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trash.appending(path: UUID().uuidString))
    }

    /// Deletes removed installations (safe: nothing references the trash).
    public nonisolated func emptyTrash() {
        let trash = root.appending(path: Self.trashDirectoryName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: trash)
    }

    // MARK: Helpers

    private nonisolated func stagedSize(_ model: ModelManifest, _ file: ModelManifest.File) -> Int64 {
        let url = stagingDirectory(for: model).appending(path: file.path)
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// Cheap startup check: the marker matches this manifest and every file is present with the right size.
    /// (Hashes were verified at install; they aren't re-read on every launch.)
    static func isInstalled(_ model: ModelManifest, root: URL) -> Bool {
        let directory = root.appending(path: model.id).appending(path: model.revision)
        guard let data = try? Data(contentsOf: directory.appending(path: verifiedMarker)),
            let marker = try? JSONDecoder().decode([String: String].self, from: data),
            marker["manifestDigest"] == model.digest
        else { return false }
        return model.files.allSatisfy { file in
            let size = try? directory.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map(Int64.init) == file.size
        }
    }

    /// Relative, no `..`, no leading `/`, no empty components, no backslashes.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == ".." || $0 == "." }
    }

    /// True when `url` (symlinks resolved) is inside `directory`.
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base + "/")
    }

    static func availableCapacity(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Streams the file through SHA-256 in 4 MB blocks.
    static func sha256(of url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        var lastReport: Int64 = 0
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            hasher.update(data: data)
            total += Int64(data.count)
            if total - lastReport >= 64 << 20 {
                lastReport = total
                progress?(total)
            }
        }
        progress?(total)
        return hasher.finalize().hexString
    }
}

/// Bytes/second over a sliding window (default 3 s). Thread-safe.
public final class RateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: Double, bytes: Int64)] = []
    private let window: Double
    private let now: @Sendable () -> Double

    public init(window: Double = 3, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.window = window
        self.now = now
    }

    /// Records the cumulative byte count; returns the current rate (nil until ≥ 1.5 s of data).
    @discardableResult
    public func record(_ bytes: Int64) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let t = now()
        samples.append((t, bytes))
        while let first = samples.first, t - first.time > window, samples.count > 2 { samples.removeFirst() }
        guard let first = samples.first, t - first.time >= 1.5 else { return nil }
        return Double(bytes - first.bytes) / (t - first.time)
    }
}
