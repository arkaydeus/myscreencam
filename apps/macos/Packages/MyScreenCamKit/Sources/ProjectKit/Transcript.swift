import Foundation

// The application-owned transcript contract (docs/subtitles-plan.md §2). Nothing here refers to a speech SDK:
// adapters convert their output into these types, and the editor only ever reads these.
//
// Times are rational on the recording's **session timeline** (the same timeline as every other source time in the
// package). Recognition output uses the prepared-audio sample rate as its timescale, so a prepared sample index
// converts exactly; floating-point SDK seconds are converted once, at the adapter boundary.

/// A rational time. `value` is encoded as a decimal string so Int64 survives any JSON reader.
public struct MediaTime: Sendable, Hashable, Comparable {
    public var value: Int64
    /// Positive.
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    /// Rounds `seconds` to the nearest tick (half away from zero). The one place floating-point seconds become
    /// rational.
    public init(seconds: Double, timescale: Int32) {
        self.init(value: Int64((seconds * Double(timescale)).rounded(.toNearestOrAwayFromZero)), timescale: timescale)
    }

    public static func zero(_ timescale: Int32) -> MediaTime { MediaTime(value: 0, timescale: timescale) }

    public var seconds: Double { Double(value) / Double(timescale) }
    public var isValid: Bool { timescale > 0 }

    /// This time in another timescale (rounded to the nearest tick).
    public func converted(to timescale: Int32) -> MediaTime {
        if timescale == self.timescale { return self }
        let scaled = (Double(value) * Double(timescale) / Double(self.timescale)).rounded(.toNearestOrAwayFromZero)
        return MediaTime(value: Int64(scaled), timescale: timescale)
    }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        if lhs.timescale == rhs.timescale { return lhs.value < rhs.value }
        // Exact cross-multiplication; only astronomically large values fall back to (lossy) seconds.
        let (l, lo) = lhs.value.multipliedReportingOverflow(by: Int64(rhs.timescale))
        let (r, ro) = rhs.value.multipliedReportingOverflow(by: Int64(lhs.timescale))
        if !lo && !ro { return l < r }
        return lhs.seconds < rhs.seconds
    }

    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        let r = rhs.converted(to: lhs.timescale)
        return MediaTime(value: lhs.value + r.value, timescale: lhs.timescale)
    }

    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        let r = rhs.converted(to: lhs.timescale)
        return MediaTime(value: lhs.value - r.value, timescale: lhs.timescale)
    }
}

extension MediaTime: Codable {
    private enum CodingKeys: String, CodingKey { case value, timescale }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let string = try c.decode(String.self, forKey: .value)
        guard let value = Int64(string) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "Bad Int64 \(string)")
        }
        let timescale = try c.decode(Int32.self, forKey: .timescale)
        guard timescale > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .timescale, in: c, debugDescription: "Timescale ≤ 0")
        }
        self.init(value: value, timescale: timescale)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(value), forKey: .value)
        try c.encode(timescale, forKey: .timescale)
    }
}

/// A half-open range `[start, start + duration)`.
public struct MediaRange: Codable, Sendable, Hashable {
    public var start: MediaTime
    /// Non-negative.
    public var duration: MediaTime

    public init(start: MediaTime, duration: MediaTime) {
        self.start = start
        self.duration = duration
    }

    public init(start: MediaTime, end: MediaTime) {
        self.init(start: start, duration: end - start)
    }

    public var end: MediaTime { start + duration }
    public var startSeconds: Double { start.seconds }
    public var endSeconds: Double { end.seconds }
    public var isValid: Bool { start.isValid && duration.isValid && duration.value >= 0 }

    public func contains(_ other: MediaRange) -> Bool { !(other.start < start) && !(end < other.end) }
    public func overlaps(_ other: MediaRange) -> Bool { other.start < end && start < other.end }
}

public enum TimingMethod: String, Codable, Sendable, Hashable {
    /// Token-and-duration transducer timing (Parakeet).
    case tdt
    /// A forced-alignment pass over the recognised text (Qwen aligner).
    case forcedAlignment
    /// Only the processing window is known.
    case coarseChunk
    /// Set by the user; never acoustic.
    case manual
}

public enum TimingValidation: String, Codable, Sendable, Hashable {
    case unchecked
    /// Structural checks passed. It does **not** certify that the boundary is acoustically exact.
    case valid
    /// Estimated or suspicious (e.g. an end inferred from the next token).
    case needsReview
}

public struct UnitTiming: Codable, Sendable, Hashable {
    public var sourceRange: MediaRange
    public var method: TimingMethod
    public var validation: TimingValidation

    public init(sourceRange: MediaRange, method: TimingMethod, validation: TimingValidation) {
        self.sourceRange = sourceRange
        self.method = method
        self.validation = validation
    }

    /// Fine enough to cut on or highlight: acoustic (not coarse, not manual) and structurally valid.
    public var isFine: Bool { (method == .tdt || method == .forcedAlignment) && validation == .valid }
}

public struct TranscriptUnit: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case word, character, subword, punctuation
    }

    public var id: String
    /// Half-open UTF-8 byte range into the segment's `rawText`.
    public var utf8Start: Int
    public var utf8End: Int
    public var kind: Kind
    public var timing: UnitTiming?
    public var languageTag: String?
    /// Backend-specific score for diagnostics only; not comparable across recognisers.
    public var backendScore: Double?
    public var warnings: [String]

    public init(
        id: String, utf8Start: Int, utf8End: Int, kind: Kind, timing: UnitTiming? = nil, languageTag: String? = nil,
        backendScore: Double? = nil, warnings: [String] = []
    ) {
        self.id = id
        self.utf8Start = utf8Start
        self.utf8End = utf8End
        self.kind = kind
        self.timing = timing
        self.languageTag = languageTag
        self.backendScore = backendScore
        self.warnings = warnings
    }
}

public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public enum RangeMeaning: String, Codable, Sendable, Hashable {
        /// The range is where the speech is.
        case speech
        /// The range is only the window the text was recognised from (plain Qwen recognition).
        case processingWindow
    }

    public var id: String
    public var sourceRange: MediaRange
    public var rangeMeaning: RangeMeaning
    /// Exactly what the recogniser produced. Display corrections live elsewhere.
    public var rawText: String
    public var languageTag: String?
    public var units: [TranscriptUnit]

    public init(
        id: String, sourceRange: MediaRange, rangeMeaning: RangeMeaning, rawText: String, languageTag: String?,
        units: [TranscriptUnit]
    ) {
        self.id = id
        self.sourceRange = sourceRange
        self.rangeMeaning = rangeMeaning
        self.rawText = rawText
        self.languageTag = languageTag
        self.units = units
    }

    /// The text of one unit (nil when its byte range doesn't fall on UTF-8 boundaries).
    public func text(of unit: TranscriptUnit) -> String? {
        let bytes = Array(rawText.utf8)
        guard unit.utf8Start >= 0, unit.utf8End <= bytes.count, unit.utf8Start <= unit.utf8End else { return nil }
        return String(bytes: bytes[unit.utf8Start..<unit.utf8End], encoding: .utf8)
    }
}

public struct ModelIdentity: Codable, Sendable, Hashable {
    public var catalogueID: String
    public var repository: String
    public var revision: String
    public var manifestDigest: String
    public var quantisation: String

    public init(catalogueID: String, repository: String, revision: String, manifestDigest: String, quantisation: String)
    {
        self.catalogueID = catalogueID
        self.repository = repository
        self.revision = revision
        self.manifestDigest = manifestDigest
        self.quantisation = quantisation
    }
}

/// Which recorded track was transcribed.
public enum TranscriptAudioSource: String, Codable, Sendable, Hashable, CaseIterable {
    case microphone
    case systemAudio

    public var stream: StreamKind {
        switch self {
        case .microphone: .microphone
        case .systemAudio: .systemAudio
        }
    }
}

/// The options a transcription ran with, persisted in full next to their fingerprint.
public struct TranscriptionOptions: Codable, Sendable, Hashable {
    /// `parakeet` or `qwen`.
    public var engine: String
    public var audioSource: TranscriptAudioSource
    /// BCP-47 tag the user asked for, or nil for automatic.
    public var languageHint: String?
    /// Outer work-unit length and hard cap, seconds.
    public var windowSeconds: Double
    public var maxWindowSeconds: Double
    /// Explicit generation budget per window; nil = the adapter's default (versioned with the adapters).
    public var tokenBudgetPerWindow: Int?
    /// Downmix / resample recipe version (changes the prepared-audio identity).
    public var audioRecipe: String

    public init(
        engine: String, audioSource: TranscriptAudioSource, languageHint: String?, windowSeconds: Double,
        maxWindowSeconds: Double, tokenBudgetPerWindow: Int?, audioRecipe: String
    ) {
        self.engine = engine
        self.audioSource = audioSource
        self.languageHint = languageHint
        self.windowSeconds = windowSeconds
        self.maxWindowSeconds = maxWindowSeconds
        self.tokenBudgetPerWindow = tokenBudgetPerWindow
        self.audioRecipe = audioRecipe
    }
}

/// One immutable transcription result (`transcripts/<id>.json`). Retranscription makes a new revision.
public struct TranscriptRevision: Codable, Sendable, Hashable, Identifiable {
    public static let currentSchemaVersion = 1

    public enum Status: String, Codable, Sendable, Hashable {
        case partial
        case complete
    }

    public var schemaVersion: Int
    public var id: String
    public var parentRevisionID: String?
    /// `RecordingMeta.id`.
    public var sourceMediaID: String
    public var audioIdentityHash: String
    public var recogniser: ModelIdentity
    public var aligner: ModelIdentity?
    public var implementationFingerprint: String
    /// Versions of the adapters, SDKs and runtime, in full (the fingerprint alone can't be debugged).
    public var implementation: [String: String]
    public var optionsFingerprint: String
    public var options: TranscriptionOptions
    /// Source intervals that were actually processed (silence included; skipped/failed windows excluded).
    public var sourceCoverage: [MediaRange]
    public var segments: [TranscriptSegment]
    public var status: Status
    public var warnings: [String]
    public var createdAt: Date

    public init(
        schemaVersion: Int = TranscriptRevision.currentSchemaVersion, id: String, parentRevisionID: String?,
        sourceMediaID: String, audioIdentityHash: String, recogniser: ModelIdentity, aligner: ModelIdentity?,
        implementationFingerprint: String, implementation: [String: String], optionsFingerprint: String,
        options: TranscriptionOptions, sourceCoverage: [MediaRange], segments: [TranscriptSegment], status: Status,
        warnings: [String], createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.parentRevisionID = parentRevisionID
        self.sourceMediaID = sourceMediaID
        self.audioIdentityHash = audioIdentityHash
        self.recogniser = recogniser
        self.aligner = aligner
        self.implementationFingerprint = implementationFingerprint
        self.implementation = implementation
        self.optionsFingerprint = optionsFingerprint
        self.options = options
        self.sourceCoverage = sourceCoverage
        self.segments = segments
        self.status = status
        self.warnings = warnings
        self.createdAt = createdAt
    }

    /// Every unit across segments with its segment, in order.
    public var allUnits: [(segment: TranscriptSegment, unit: TranscriptUnit)] {
        segments.flatMap { segment in segment.units.map { (segment, $0) } }
    }

    /// Looks up a unit by id.
    public func unit(id: String) -> (segment: TranscriptSegment, unit: TranscriptUnit)? {
        for segment in segments {
            if let unit = segment.units.first(where: { $0.id == id }) { return (segment, unit) }
        }
        return nil
    }
}

// MARK: - Validation

public enum TranscriptValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case invalidRange(String)
    case outOfSource(String)
    case badUTF8Range(String)
    case duplicateID(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let v): "Unsupported transcript schema \(v)"
        case .invalidRange(let id): "Invalid time range on \(id)"
        case .outOfSource(let id): "Timing outside the recording on \(id)"
        case .badUTF8Range(let id): "Bad UTF-8 range on \(id)"
        case .duplicateID(let id): "Duplicate id \(id)"
        }
    }
}

extension TranscriptRevision {
    /// Structural validation at every persisted-data/IPC boundary: schema, finite positive-timescale ranges,
    /// containment in `0…sourceDuration`, UTF-8 boundaries and unique ids.
    public func validate(sourceDuration: Double) throws {
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw TranscriptValidationError.unsupportedSchema(schemaVersion)
        }
        let source = MediaRange(start: .zero(1_000_000), end: MediaTime(seconds: sourceDuration, timescale: 1_000_000))
        // Sub-sample rounding tolerance (one 16 kHz sample) at the end of the source.
        let tolerance = 1.0 / 16_000
        func check(_ range: MediaRange, _ id: String) throws {
            guard range.isValid, range.startSeconds.isFinite, range.endSeconds.isFinite else {
                throw TranscriptValidationError.invalidRange(id)
            }
            guard range.startSeconds >= -tolerance, range.endSeconds <= source.endSeconds + tolerance else {
                throw TranscriptValidationError.outOfSource(id)
            }
        }
        var ids = Set<String>()
        for range in sourceCoverage { try check(range, "coverage") }
        for segment in segments {
            guard ids.insert(segment.id).inserted else { throw TranscriptValidationError.duplicateID(segment.id) }
            try check(segment.sourceRange, segment.id)
            let bytes = Array(segment.rawText.utf8)
            for unit in segment.units {
                guard ids.insert(unit.id).inserted else { throw TranscriptValidationError.duplicateID(unit.id) }
                guard unit.utf8Start >= 0, unit.utf8Start < unit.utf8End, unit.utf8End <= bytes.count,
                    UTF8Boundary.isBoundary(bytes, unit.utf8Start), UTF8Boundary.isBoundary(bytes, unit.utf8End)
                else { throw TranscriptValidationError.badUTF8Range(unit.id) }
                if let timing = unit.timing { try check(timing.sourceRange, unit.id) }
            }
        }
    }
}

public enum UTF8Boundary {
    /// True when `index` is at a scalar boundary of `bytes` (0 and count included).
    public static func isBoundary(_ bytes: [UInt8], _ index: Int) -> Bool {
        if index == 0 || index == bytes.count { return true }
        guard index > 0, index < bytes.count else { return false }
        return bytes[index] & 0xC0 != 0x80
    }
}
