import CoreMedia
import Foundation
import Synchronization

/// Turns appended sample times into throttled, monotonic `ExportProgress` values on an `AsyncStream`.
///
/// Called from the pump queues on every append, so the fast path is a lock, a few comparisons and a
/// clock read; building and yielding a snapshot happens at most once per `interval`.
final class ProgressReporter: Sendable {
    enum Track: Int, Sendable {
        case video = 0
        case audio = 1
    }

    /// The last value of the encoding stage; finishing moves to `finalizing`, then 1.0.
    static let encodingCeiling = 0.99

    private struct State {
        var stage: ExportStage = .preparing
        var stageText = "Preparing…"
        var encodingText = "Encoding video…"
        var duration: Double = 0
        var trackTimes: [Double] = [0, 0]
        var activeTracks: Set<Int> = []
        var frames = 0
        var fraction = 0.0
        var outputURL: URL?
        var lastEmit: ContinuousClock.Instant?
        var lastActivity: ContinuousClock.Instant
        var latest: ExportProgress
        var closed = false
    }

    private let continuation: AsyncStream<ExportProgress>.Continuation
    private let interval: Duration
    private let start: ContinuousClock.Instant
    private let state: Mutex<State>

    init(continuation: AsyncStream<ExportProgress>.Continuation, interval: Duration) {
        let now = ContinuousClock.now
        self.continuation = continuation
        self.interval = interval
        self.start = now
        let initial = ExportProgress(fraction: 0, stage: .preparing, stageText: "Preparing…")
        self.state = Mutex(State(lastActivity: now, latest: initial))
        continuation.yield(initial)
    }

    /// The most recent snapshot (also the last one yielded, modulo throttling).
    var latest: ExportProgress { state.withLock { $0.latest } }

    /// Seconds since the last append or stage change. Drives the stall watchdog.
    var secondsSinceActivity: Double {
        let last = state.withLock { $0.lastActivity }
        return (ContinuousClock.now - last).seconds
    }

    /// Wall-clock seconds since the job started.
    var elapsed: Double { (ContinuousClock.now - start).seconds }

    /// Switches to the encoding stage.
    /// - Parameters:
    ///   - duration: the output duration in seconds (the denominator of `fraction`).
    ///   - tracks: the tracks being pumped; the slowest one drives `fraction`.
    ///   - outputURL: the file being written, for `bytesWritten`.
    func beginEncoding(duration: Double, tracks: Set<Track>, outputURL: URL, text: String) {
        emit(force: true) { state in
            state.stage = .encoding
            state.stageText = text
            state.encodingText = text
            state.duration = max(duration, 0.001)
            state.activeTracks = Set(tracks.map(\.rawValue))
            state.outputURL = outputURL
        }
    }

    /// Records a sample appended up to `endTime` seconds. Throttled.
    func didAppend(_ track: Track, endTime: Double) {
        emit(force: false) { state in
            if endTime > state.trackTimes[track.rawValue] {
                state.trackTimes[track.rawValue] = endTime
            }
            if track == .video {
                state.frames += 1
            }
        }
    }

    /// Records that a track has delivered all its samples.
    func didFinish(_ track: Track) {
        emit(force: false) { state in
            state.activeTracks.remove(track.rawValue)
        }
    }

    func beginFinalizing() {
        emit(force: true) { state in
            state.stage = .finalizing
            state.stageText = "Finalizing…"
            state.fraction = max(state.fraction, Self.encodingCeiling)
        }
    }

    /// Emits the final 1.0 snapshot and closes the stream.
    func finish(bytesWritten: Int64) {
        emit(force: true) { state in
            state.stage = .finished
            state.stageText = "Done"
            state.fraction = 1
            state.outputURL = nil
            state.latest.bytesWritten = bytesWritten
        }
        close()
    }

    /// Closes the stream without reaching 1.0 (failure or cancellation).
    func close() {
        let shouldFinish = state.withLock { state in
            defer { state.closed = true }
            return !state.closed
        }
        if shouldFinish { continuation.finish() }
    }

    // MARK: Private

    private func emit(force: Bool, _ mutate: (inout State) -> Void) {
        let now = ContinuousClock.now
        let snapshot: ExportProgress? = state.withLock { state in
            guard !state.closed else { return nil }
            mutate(&state)
            state.lastActivity = now
            if state.stage == .encoding {
                state.fraction = max(state.fraction, encodingFraction(state))
            }
            if !force, let last = state.lastEmit, now - last < interval {
                return nil
            }
            state.lastEmit = now
            let snapshot = makeSnapshot(state, now: now)
            state.latest = snapshot
            return snapshot
        }
        guard let snapshot else { return }
        continuation.yield(snapshot)
    }

    private func encodingFraction(_ state: State) -> Double {
        // The slowest unfinished track bounds progress; finished tracks count as complete.
        let times = state.activeTracks.map { state.trackTimes[$0] }
        let done = times.min().map { $0 / state.duration } ?? 1
        return min(Self.encodingCeiling, max(0, done) * Self.encodingCeiling)
    }

    private func makeSnapshot(_ state: State, now: ContinuousClock.Instant) -> ExportProgress {
        let elapsed = (now - start).seconds
        var bytes = state.latest.bytesWritten
        if let url = state.outputURL,
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        {
            bytes = max(bytes, Int64(size))
        }
        var eta: TimeInterval?
        if state.stage == .encoding, state.fraction >= 0.02, elapsed >= 0.5 {
            eta = elapsed / state.fraction * (1 - state.fraction)
        }
        return ExportProgress(
            fraction: state.fraction,
            stage: state.stage,
            stageText: state.stageText,
            bytesWritten: bytes,
            framesWritten: state.frames,
            elapsed: elapsed,
            estimatedTimeRemaining: eta
        )
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
