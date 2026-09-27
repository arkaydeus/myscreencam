import Foundation
import ProjectKit

// The typed protocol between the app (the one owner of the transcription queue) and the `MyScreenArtSpeech` XPC
// service (the one owner of loaded models). Every message is JSON inside an XPC `Data` payload and is validated
// on arrival. Audio travels as a path to a prepared file plus sample ranges, never as a payload. Results are in
// **prepared-audio samples**; the host adds the source offset exactly once (`TranscriptAssembler`).

public enum WorkerProtocolVersion {
    public static let current = 1
}

/// A half-open range of prepared-audio samples.
public struct SampleRange: Codable, Sendable, Hashable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var count: Int64 { max(0, end - start) }
}

/// One outer work unit: the samples it owns (its results are kept only inside these) and the samples it reads
/// (owned plus a little context each side, so words at the edge aren't clipped).
public struct WorkWindow: Codable, Sendable, Hashable {
    public var index: Int
    public var owned: SampleRange
    public var read: SampleRange

    public init(index: Int, owned: SampleRange, read: SampleRange) {
        self.index = index
        self.owned = owned
        self.read = read
    }
}

/// A recognised unit, local to its window's text; times in prepared samples (absolute in the prepared file).
public struct RecognisedUnit: Codable, Sendable, Hashable {
    public var utf8Start: Int
    public var utf8End: Int
    public var kind: TranscriptUnit.Kind
    public var startSample: Int64?
    public var endSample: Int64?
    public var method: TimingMethod?
    /// The end was inferred (e.g. from the next token's start), not measured.
    public var endEstimated: Bool
    public var score: Double?

    public init(
        utf8Start: Int, utf8End: Int, kind: TranscriptUnit.Kind, startSample: Int64? = nil, endSample: Int64? = nil,
        method: TimingMethod? = nil, endEstimated: Bool = false, score: Double? = nil
    ) {
        self.utf8Start = utf8Start
        self.utf8End = utf8End
        self.kind = kind
        self.startSample = startSample
        self.endSample = endSample
        self.method = method
        self.endEstimated = endEstimated
        self.score = score
    }
}

public enum WindowTermination: String, Codable, Sendable, Hashable {
    /// The recogniser finished on its own (end of sequence / whole window decoded).
    case complete
    /// The window held no speech.
    case silent
    /// Generation hit the token budget: the text is probably truncated.
    case tokenBudgetExhausted
    /// The recogniser stopped on a repetition guard: the tail may be missing.
    case repetitionStop
}

/// A recognition result for one window.
public struct RecognisedWindow: Codable, Sendable, Hashable {
    public var window: WorkWindow
    /// Exact recogniser text (units index into its UTF-8 bytes).
    public var text: String
    /// Canonical language tag the recogniser reported, if any.
    public var languageTag: String?
    /// Units; empty for text-only recognition.
    public var units: [RecognisedUnit]
    public var termination: WindowTermination
    public var generatedTokens: Int?
    public var tokenBudget: Int?
    public var warnings: [String]
    public var processingSeconds: Double

    public init(
        window: WorkWindow, text: String, languageTag: String?, units: [RecognisedUnit],
        termination: WindowTermination, generatedTokens: Int? = nil, tokenBudget: Int? = nil, warnings: [String] = [],
        processingSeconds: Double
    ) {
        self.window = window
        self.text = text
        self.languageTag = languageTag
        self.units = units
        self.termination = termination
        self.generatedTokens = generatedTokens
        self.tokenBudget = tokenBudget
        self.warnings = warnings
        self.processingSeconds = processingSeconds
    }
}

/// One aligner item (the aligner's own word split), in prepared samples.
public struct AlignedItem: Codable, Sendable, Hashable {
    public var text: String
    public var startSample: Int64
    public var endSample: Int64

    public init(text: String, startSample: Int64, endSample: Int64) {
        self.text = text
        self.startSample = startSample
        self.endSample = endSample
    }
}

public struct AlignedWindow: Codable, Sendable, Hashable {
    public var windowIndex: Int
    public var items: [AlignedItem]
    public var processingSeconds: Double

    public init(windowIndex: Int, items: [AlignedItem], processingSeconds: Double) {
        self.windowIndex = windowIndex
        self.items = items
        self.processingSeconds = processingSeconds
    }
}

/// Which model the worker should hold.
public enum WorkerModelRole: String, Codable, Sendable, Hashable {
    case parakeet
    case qwenRecogniser
    case qwenAligner
}

public enum WorkerRequest: Codable, Sendable, Hashable {
    /// Protocol/version check; returns `.capabilities`.
    case handshake(protocolVersion: Int)
    /// Loads (replacing whatever is loaded) the model in `directory`, which must be an installed, verified model
    /// under the models root the worker was started with. `runtimeDirectory` is a scratch directory the SDK may
    /// write derived files into (never the verified snapshot).
    case load(role: WorkerModelRole, directory: String, runtimeDirectory: String)
    case unload
    /// Recognises `window` of the prepared file at `audioPath` with the loaded recogniser.
    case recognise(audioPath: String, window: WorkWindow, languageHint: String?, tokenBudget: Int?)
    /// Aligns `text` against the window's audio with the loaded aligner.
    case align(audioPath: String, window: WorkWindow, text: String, languageTag: String)
    case shutdown
}

public struct WorkerCapabilities: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    /// Adapter/SDK/runtime versions, e.g. `["FluidAudio": "0.17.3", "mlx-audio-swift": "<sha>", ...]`.
    public var implementation: [String: String]
    /// Apple silicon with the required OS.
    public var supported: Bool

    public init(protocolVersion: Int, implementation: [String: String], supported: Bool) {
        self.protocolVersion = protocolVersion
        self.implementation = implementation
        self.supported = supported
    }
}

public enum WorkerFailure: String, Codable, Sendable, Hashable, Error {
    case unsupportedPlatform
    case badRequest
    case pathNotAllowed
    case modelMissingOrCorrupt
    case modelInitialisation
    case noModelLoaded
    case unreadableAudio
    case recognitionFailed
    case alignmentFailed
    case oversizedRequest
}

public enum WorkerResponse: Codable, Sendable, Hashable {
    case capabilities(WorkerCapabilities)
    case loaded(role: WorkerModelRole, seconds: Double)
    case ok
    case recognised(RecognisedWindow)
    case aligned(AlignedWindow)
    case failure(WorkerFailure, message: String)
}

public enum WorkerCoding {
    /// Largest message accepted in either direction.
    public static let maxMessageBytes = 16 << 20

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxMessageBytes else { throw WorkerFailure.oversizedRequest }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Path checks the worker applies to every request: models only from inside the models root, audio only as a
/// prepared `.f32` file inside a recording's transcription cache.
public struct WorkerPathPolicy: Sendable {
    public let modelsRoot: URL

    public init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func modelDirectory(_ path: String) -> URL? {
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(modelsRoot.path + "/"),
            FileManager.default.fileExists(atPath: url.appending(path: ModelStore.verifiedMarker).path)
        else { return nil }
        return url
    }

    public func runtimeDirectory(_ path: String) -> URL? {
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        let root = modelsRoot.appending(path: ModelStore.runtimeDirectoryName).standardizedFileURL
        return url.path.hasPrefix(root.path + "/") ? url : nil
    }

    public func audioFile(_ path: String) -> URL? {
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension == PreparedAudio.sampleFileExtension,
            url.path.contains("/\(PackageLayout.transcriptionCacheDirectory)/"),
            FileManager.default.isReadableFile(atPath: url.path)
        else { return nil }
        return url
    }
}

/// The XPC interface of the `MyScreenArtSpeech` service: one method carrying a JSON ``WorkerRequest`` and
/// replying with a JSON ``WorkerResponse``.
@objc public protocol SpeechServiceProtocol {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

public enum SpeechServiceIdentity {
    /// The service's bundle id is the app's plus this suffix (see project.yml).
    public static let bundleSuffix = ".speech"

    /// The app bundle id a service bundle id belongs to.
    public static func appBundleIdentifier(forService id: String) -> String {
        id.hasSuffix(bundleSuffix) ? String(id.dropLast(bundleSuffix.count)) : id
    }
}
