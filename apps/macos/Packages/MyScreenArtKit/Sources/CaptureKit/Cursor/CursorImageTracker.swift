import Foundation
import ProjectKit

/// Records the system cursor's appearance during a recording.
///
/// Call ``noteActivity()`` from pointer events (moves, button changes). The tracker samples
/// `NSCursor.currentSystem` on the main thread (AppKit isn't documented thread-safe for it) at most
/// `maximumRate` times a second, with a trailing sample so the final cursor after a burst is caught. Nothing
/// runs while the pointer is idle. Each sample is hashed; new images are classified and written as PNGs on a
/// utility queue. ``currentCursorID`` is the id to stamp on events.
public final class CursorImageTracker: @unchecked Sendable {
    /// Produces the current cursor at a scale. Runs on the main actor.
    public typealias Source = @MainActor @Sendable (_ scale: Double) -> CursorSnapshot?

    public let scale: Double
    public let maximumRate: Double
    private let directory: URL
    private let source: Source
    private let providedClassifier: CursorClassifier?
    private let queue = DispatchQueue(label: "com.myscreenart.capture.cursor", qos: .utility)
    private let lock = NSLock()
    private var store: CursorImageStore?
    private var current: Int?
    private var lastSample = -Double.infinity
    private var pending = false
    private var stopped = true
    private var samples = 0

    /// - Parameters:
    ///   - directory: the package's `cursors/` folder.
    ///   - scale: pixels per point to store images at (the captured display's backing scale).
    ///   - classifier: defaults to ``CursorClassifier/standard(scale:)``.
    ///   - source: defaults to `NSCursor.currentSystem`.
    public init(
        directory: URL, scale: Double, maximumRate: Double = 30, classifier: CursorClassifier? = nil,
        source: @escaping Source = { CursorSnapshot.currentSystem(scale: $0) }
    ) {
        self.directory = directory
        self.scale = scale
        self.maximumRate = maximumRate
        self.providedClassifier = classifier
        self.source = source
    }

    /// The id (in `cursors/index.json`) of the cursor last seen, if any.
    public var currentCursorID: Int? { lock.withLock { current } }

    /// Samples taken so far (for diagnostics).
    public var sampleCount: Int { lock.withLock { samples } }

    /// Prepares the classifier and takes a first sample.
    public func start() async {
        let scale = scale
        let classifier = await MainActor.run { providedClassifier ?? CursorClassifier.standard(scale: scale) }
        let store = CursorImageStore(directory: directory, classifier: classifier)
        lock.withLock {
            self.store = store
            stopped = false
        }
        await MainActor.run { sampleOnMain() }
    }

    /// Requests a sample soon (throttled). Cheap; call from any thread on every pointer event.
    public func noteActivity() {
        let delay: Double? = lock.withLock {
            guard !stopped, !pending else { return nil }
            pending = true
            return max(0, lastSample + 1 / maximumRate - HostClock.now())
        }
        guard let delay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            MainActor.assumeIsolated { sampleOnMain() }
        }
    }

    /// Stops sampling, waits for pending image writes and returns the index to save as `cursors/index.json`.
    public func finish() async -> CursorIndex {
        lock.withLock { stopped = true }
        // A sample already running on the main actor has enqueued its write once this hop returns.
        await MainActor.run {}
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: lock.withLock { store?.index } ?? CursorIndex())
            }
        }
    }

    @MainActor
    private func sampleOnMain() {
        let proceed = lock.withLock {
            pending = false
            guard !stopped else { return false }
            lastSample = HostClock.now()
            samples += 1
            return true
        }
        guard proceed, let snapshot = source(scale) else { return }
        queue.async { [self] in register(snapshot) }
    }

    private func register(_ snapshot: CursorSnapshot) {
        guard let store = lock.withLock({ store }) else { return }
        do {
            let id = try store.register(snapshot)
            lock.withLock { current = id }
        } catch {
            CaptureLog.cursor.error("Cursor image not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
