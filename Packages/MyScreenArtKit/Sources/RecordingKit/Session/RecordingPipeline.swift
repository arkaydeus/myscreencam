import CaptureKit
import CoreMedia
import Foundation
import ProjectKit

/// Static facts for a recording's `meta.json` and writers.
struct RecordingPipelineConfiguration: Sendable {
    var package: RecordingPackage
    var id: UUID
    var name: String
    var createdAt: Date
    var source: CaptureSource
    var screen: ScreenStreamInfo
    var webcam: WebcamStreamInfo?
    var microphone: AudioDeviceInfo?
    var capturesSystemAudio: Bool
    var systemCursorHidden: Bool
    var codec: VideoCodec
    var recordsEvents: Bool
    var appVersion: String?
}

/// The capture-independent core of a recording: the session clock, one writer per stream, the events log,
/// and `meta.json`. ``RecordingSession`` feeds it from live capture; tests feed it synthetic buffers.
///
/// Thread-safe: `append…` and `record` are called from capture queues/threads; the clock is behind a lock and
/// each writer serialises on its own queue.
final class RecordingPipeline: @unchecked Sendable {
    let configuration: RecordingPipelineConfiguration
    private let lock = NSLock()
    private var clock = SessionClock()
    private var firstFrameHandler: (@Sendable () -> Void)?
    private let writers: [StreamKind: StreamWriter]
    private let events: EventLogWriter?

    /// Creates the writers (video encoders start immediately) and `events.jsonl`.
    init(
        configuration: RecordingPipelineConfiguration,
        onStreamFailure: @escaping @Sendable (StreamKind, String) -> Void
    ) throws {
        self.configuration = configuration
        let package = configuration.package
        var writers: [StreamKind: StreamWriter] = [:]
        let screen = configuration.screen
        writers[.screen] = StreamWriter(
            kind: .screen, url: package.url(for: .screen),
            videoSettings: EncoderSettings.video(
                codec: configuration.codec, width: screen.pixelWidth, height: screen.pixelHeight,
                frameRate: screen.frameRate, isCamera: false),
            onFailure: onStreamFailure)
        if let webcam = configuration.webcam {
            writers[.webcam] = StreamWriter(
                kind: .webcam, url: package.url(for: .webcam),
                videoSettings: EncoderSettings.video(
                    codec: configuration.codec == .proRes422Proxy ? .proRes422Proxy : .hevc,
                    width: CaptureGeometry.evenFloor(Double(webcam.pixelWidth)),
                    height: CaptureGeometry.evenFloor(Double(webcam.pixelHeight)), frameRate: webcam.frameRate,
                    isCamera: true),
                onFailure: onStreamFailure)
        }
        if configuration.capturesSystemAudio {
            writers[.systemAudio] = StreamWriter(
                kind: .systemAudio, url: package.url(for: .systemAudio), videoSettings: nil,
                onFailure: onStreamFailure)
        }
        if configuration.microphone != nil {
            writers[.microphone] = StreamWriter(
                kind: .microphone, url: package.url(for: .microphone), videoSettings: nil,
                onFailure: onStreamFailure)
        }
        for writer in writers.values { try writer.prepare() }
        self.writers = writers
        events = configuration.recordsEvents ? try EventLogWriter(url: package.url(PackageLayout.events)) : nil
    }

    /// Called once, on the screen capture queue, when the first screen frame starts the session clock.
    func onFirstFrame(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { firstFrameHandler = handler }
    }

    var isStarted: Bool { lock.withLock { clock.isStarted } }

    // MARK: Ingest

    /// A screen frame. The first one starts the session clock (session time 0 = its timestamp).
    func appendScreen(_ buffer: CMSampleBuffer) {
        let host = buffer.presentationTimeStamp.seconds
        let (placement, firstFrame) = lock.withLock {
            var handler: (@Sendable () -> Void)?
            if !clock.isStarted, !clock.isStopped {
                clock.start(atHostTime: host)
                handler = firstFrameHandler
                firstFrameHandler = nil
            }
            return (clock.placement(forHostTime: host), handler)
        }
        firstFrame?()
        if let placement { writers[.screen]?.append(buffer, placement: placement) }
    }

    /// A webcam frame, system-audio or microphone buffer (host-clock timestamps). Dropped before the first screen
    /// frame, during pauses and after stop.
    func append(_ buffer: CMSampleBuffer, to kind: StreamKind) {
        guard kind != .screen, let writer = writers[kind] else { return }
        let host = buffer.presentationTimeStamp.seconds
        guard let placement = lock.withLock({ clock.placement(forHostTime: host) }) else { return }
        writer.append(buffer, placement: placement)
    }

    /// A pointer event, stamped with the cursor image showing at the time.
    func record(_ pointer: PointerEvent, cursor: Int?) {
        guard let events, let t = lock.withLock({ clock.sessionTime(forHostTime: pointer.hostTime) }) else { return }
        events.append(pointer.inputEvent(sessionTime: t, cursor: cursor))
    }

    // MARK: Control

    func pause(atHostTime host: Double) -> Bool {
        let paused = lock.withLock { clock.pause(atHostTime: host) }
        if paused { events?.flush() }
        return paused
    }

    func resume(atHostTime host: Double) -> Bool {
        lock.withLock { clock.resume(atHostTime: host) }
    }

    var isPaused: Bool { lock.withLock { clock.isPaused } }

    func elapsed(atHostTime host: Double) -> Double {
        lock.withLock { clock.elapsed(atHostTime: host) }
    }

    /// Stops the clock at `host` without finalising: later samples are dropped while capture shuts down.
    func stopClock(atHostTime host: Double) {
        lock.withLock { clock.stop(atHostTime: host) }
    }

    /// Finalises every file and writes `cursors/index.json` and `meta.json`. Call after capture has stopped.
    func finish(cursorIndex: CursorIndex?) async throws -> RecordingMeta {
        let clock = lock.withLock {
            if !self.clock.isStopped { self.clock.stop(atHostTime: HostClock.now()) }
            return self.clock
        }
        let duration = clock.elapsed(atHostTime: clock.stopHostTime ?? .infinity)
        let endFileTime = clock.startHostTime.map { HostClock.time(seconds: $0 + duration) }
        let results = await withTaskGroup(of: StreamWriter.Result.self) { group in
            for writer in writers.values { group.addTask { await writer.finish(endFileTime: endFileTime) } }
            return await group.reduce(into: [StreamWriter.Result]()) { $0.append($1) }
        }
        try await events?.close()
        let package = configuration.package
        do {
            if let cursorIndex { try package.saveCursorIndex(cursorIndex) }
            let meta = RecordingMetaBuilder.meta(configuration: configuration, clock: clock, results: results)
            try package.saveMeta(meta)
            return meta
        } catch {
            throw RecordingError.packageFailed(error.localizedDescription)
        }
    }

    // MARK: Diagnostics

    var streamStatistics: [StreamKind: RecordingStatistics.Stream] {
        writers.mapValues { writer in
            let stats = writer.statistics
            return RecordingStatistics.Stream(appended: stats.appended, dropped: stats.dropped)
        }
    }

    var eventsWritten: Int { events?.count ?? 0 }
}

/// Assembles `meta.json` from the configuration, the final clock and the writer results.
enum RecordingMetaBuilder {
    static func meta(
        configuration: RecordingPipelineConfiguration, clock: SessionClock, results: [StreamWriter.Result]
    ) -> RecordingMeta {
        let written = results.filter { $0.startOffset != nil }
        let streams = Dictionary(
            uniqueKeysWithValues: written.map { ($0.kind, StreamTiming(startOffset: $0.startOffset!)) })
        let kinds = Set(streams.keys)
        return RecordingMeta(
            id: configuration.id,
            name: configuration.name,
            createdAt: configuration.createdAt,
            duration: clock.elapsed(atHostTime: clock.stopHostTime ?? .infinity),
            source: configuration.source,
            screen: configuration.screen,
            webcam: kinds.contains(.webcam) ? configuration.webcam : nil,
            microphone: kinds.contains(.microphone) ? configuration.microphone : nil,
            capturedSystemAudio: kinds.contains(.systemAudio),
            streams: streams,
            pauses: clock.pauseRecords,
            systemCursorHidden: configuration.systemCursorHidden,
            appVersion: configuration.appVersion)
    }

    /// "0.1.0 (1)" from the main bundle, if it has version keys.
    static func appVersion(bundle: Bundle = .main) -> String? {
        guard let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
