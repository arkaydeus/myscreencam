import Foundation
import MyScreenCamCore
import Observation
import SpeechCore

/// The app's view of speech-model installations: per-engine state for the Settings UI, backed by the one
/// `ModelStore`. Downloads only start from an explicit user action.
@MainActor
@Observable
final class SpeechModels {
    /// An engine's models taken together.
    enum EngineState: Equatable {
        case notInstalled
        case downloading(DownloadProgress)
        case verifying(Double)
        case installed
        case failed(String)
        case removing

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .removing: true
            default: false
            }
        }
    }

    @ObservationIgnored let store: ModelStore
    private(set) var states: [String: ModelInstallState] = [:]
    /// A removal or install error to show once.
    var lastError: String?
    @ObservationIgnored private var observer: Task<Void, Never>?

    init(store: ModelStore = ModelStore(root: ModelStore.defaultRoot())) {
        self.store = store
        observer = Task { [weak self, store] in
            for await states in await store.updates() {
                self?.states = states
            }
        }
    }

    var catalogue: ModelCatalogue { store.catalogue }

    func downloadBytes(for engine: SpeechEngine) -> Int64 { catalogue.downloadBytes(for: engine) }

    /// Combined state of the engine's models (downloads run one model after another; progress spans all of them).
    func state(of engine: SpeechEngine) -> EngineState {
        let manifests = catalogue.manifests(for: engine)
        let modelStates = manifests.map { states[$0.id] ?? .notInstalled }
        if modelStates.allSatisfy({ $0 == .installed }) { return .installed }
        if modelStates.contains(.removing) { return .removing }
        for state in modelStates { if case .failed(let message) = state { return .failed(message) } }
        let total = manifests.reduce(Int64(0)) { $0 + $1.totalBytes }
        var done: Int64 = 0
        var rate: Double?
        var active = false
        for (model, state) in zip(manifests, modelStates) {
            switch state {
            case .installed: done += model.totalBytes
            case .downloading(let progress):
                done += progress.completedBytes
                rate = progress.bytesPerSecond
                active = true
            case .verifying(let fraction):
                if manifests.count == 1 { return .verifying(fraction) }
                done += model.totalBytes
                active = true
            default: break
            }
        }
        if active {
            return .downloading(DownloadProgress(completedBytes: done, totalBytes: total, bytesPerSecond: rate))
        }
        return .notInstalled
    }

    func isInstalled(_ engine: SpeechEngine) -> Bool { state(of: engine) == .installed }

    func install(_ engine: SpeechEngine) {
        lastError = nil
        Task { await store.install(engine) }
    }

    func cancel(_ engine: SpeechEngine) {
        Task { await store.cancelInstall(engine) }
    }

    /// Removes an engine's models (keeping anything the other engine shares).
    func remove(_ engine: SpeechEngine) async {
        do {
            let other = SpeechEngine.allCases.first { $0 != engine && isInstalled($0) }
            try await store.remove(engine, keeping: other)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
