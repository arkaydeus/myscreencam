import Foundation
import MLX
import ProjectKit
import SpeechCore

/// The one owner of loaded models inside the speech worker. Holds at most one recogniser or aligner; loading
/// another releases the current one first. Every request's paths are checked against ``WorkerPathPolicy``.
public actor InferenceEngine {
    /// Versions reported in the handshake and stored with every transcript (keep in sync with Package.resolved).
    public static let implementation: [String: String] = [
        "adapters": "1",
        "FluidAudio": "0.17.3",
        "mlx-audio-swift": "01dec7c9bdce3088a6b6b7ab9f2e403458195efb",
        "mlx-swift": "0.31.6",
        "mlx-swift-lm": "3.31.4",
        "swift-transformers": "1.3.4",
    ]

    private enum Loaded {
        case parakeet(ParakeetAdapter)
        case qwenRecogniser(QwenAdapter)
        case qwenAligner(QwenAlignmentAdapter)
    }

    private let policy: WorkerPathPolicy
    private var loaded: Loaded?
    private var samples: PreparedSamples?

    public init(modelsRoot: URL) {
        policy = WorkerPathPolicy(modelsRoot: modelsRoot)
        // Keep MLX's buffer cache small: we run one bounded window at a time.
        Memory.cacheLimit = 256 << 20
    }

    public static var isSupportedPlatform: Bool {
        #if arch(arm64)
            return true
        #else
            return false
        #endif
    }

    public func handle(_ request: WorkerRequest) async -> WorkerResponse {
        do {
            return try await perform(request)
        } catch let failure as WorkerFailure {
            return .failure(failure, message: "\(failure)")
        } catch let error as EngineError {
            return .failure(error.failure, message: error.message)
        } catch {
            return .failure(.recognitionFailed, message: String(describing: error))
        }
    }

    private func perform(_ request: WorkerRequest) async throws -> WorkerResponse {
        switch request {
        case .handshake:
            return .capabilities(
                WorkerCapabilities(
                    protocolVersion: WorkerProtocolVersion.current, implementation: Self.implementation,
                    supported: Self.isSupportedPlatform))
        case .load(let role, let directory, let runtime):
            guard Self.isSupportedPlatform else { throw WorkerFailure.unsupportedPlatform }
            guard let modelDirectory = policy.modelDirectory(directory) else { throw WorkerFailure.pathNotAllowed }
            unloadModel()
            let started = Date()
            do {
                switch role {
                case .parakeet:
                    loaded = .parakeet(try await ParakeetAdapter.load(directory: modelDirectory))
                case .qwenRecogniser, .qwenAligner:
                    guard let runtimeURL = policy.runtimeDirectory(runtime) else { throw WorkerFailure.pathNotAllowed }
                    let mirror = try RuntimeDirectory.prepare(mirroring: modelDirectory, at: runtimeURL)
                    loaded =
                        role == .qwenRecogniser
                        ? .qwenRecogniser(try await QwenAdapter.load(runtimeDirectory: mirror))
                        : .qwenAligner(try await QwenAlignmentAdapter.load(runtimeDirectory: mirror))
                }
            } catch let failure as WorkerFailure {
                throw failure
            } catch {
                throw EngineError(failure: .modelInitialisation, message: String(describing: error))
            }
            return .loaded(role: role, seconds: Date().timeIntervalSince(started))
        case .unload:
            unloadModel()
            return .ok
        case .recognise(let path, let window, let hint, let budget):
            let samples = try samples(at: path)
            switch loaded {
            case .parakeet(let adapter):
                do {
                    return .recognised(
                        try await adapter.recognise(samples: samples, window: window, languageHint: hint))
                } catch {
                    throw EngineError(failure: .recognitionFailed, message: String(describing: error))
                }
            case .qwenRecogniser(let adapter):
                return .recognised(
                    adapter.recognise(samples: samples, window: window, languageHint: hint, tokenBudget: budget))
            default:
                throw WorkerFailure.noModelLoaded
            }
        case .align(let path, let window, let text, let language):
            guard case .qwenAligner(let adapter) = loaded else { throw WorkerFailure.noModelLoaded }
            let samples = try samples(at: path)
            return .aligned(try adapter.align(samples: samples, window: window, text: text, languageTag: language))
        case .shutdown:
            unloadModel()
            return .ok
        }
    }

    private func samples(at path: String) throws -> PreparedSamples {
        guard let url = policy.audioFile(path) else { throw WorkerFailure.pathNotAllowed }
        if let samples, samples.url == url { return samples }
        do {
            let loaded = try PreparedSamples(url: url)
            samples = loaded
            return loaded
        } catch {
            throw WorkerFailure.unreadableAudio
        }
    }

    private func unloadModel() {
        loaded = nil
        samples = nil
        Memory.clearCache()
    }
}

/// A failure with the SDK's own description (logged by the host; never contains transcript text).
struct EngineError: Error {
    var failure: WorkerFailure
    var message: String
}
