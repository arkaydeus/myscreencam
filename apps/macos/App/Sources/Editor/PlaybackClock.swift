import Observation

/// The only playback state SwiftUI observes is `isPlaying`. `time` changes ~10 Hz (from a periodic time observer) and
/// is pushed straight to the AppKit time label: a SwiftUI update makes the editor's `NSHostingView` recompute the
/// window's minimum size and re-lay out the whole editor, which cost ~5% of a core at 10 Hz. The playhead and meters
/// are CALayers driven by display links.
@MainActor
@Observable
final class PlaybackClock {
    /// Edited-timeline seconds, for the time label (not observable; see ``observeTime(_:_:)``).
    @ObservationIgnored var time: Double = 0 {
        didSet {
            guard time != oldValue else { return }
            for handler in timeHandlers.values { handler(time) }
        }
    }
    /// True while the player is playing (rate ≠ 0).
    var isPlaying = false

    @ObservationIgnored private var timeHandlers: [ObjectIdentifier: (Double) -> Void] = [:]

    /// Calls `handler` with every new `time` until ``removeTimeObserver(_:)``.
    func observeTime(_ owner: AnyObject, _ handler: @escaping (Double) -> Void) {
        timeHandlers[ObjectIdentifier(owner)] = handler
    }

    func removeTimeObserver(_ owner: AnyObject) {
        timeHandlers[ObjectIdentifier(owner)] = nil
    }
}

/// A tiny multicast for "the playhead moved while paused" (seeks, item swaps), so AppKit views can move their layers
/// without SwiftUI invalidation.
@MainActor
final class PlayheadSignal {
    private var handlers: [ObjectIdentifier: (Double) -> Void] = [:]

    func observe(_ owner: AnyObject, _ handler: @escaping (Double) -> Void) {
        handlers[ObjectIdentifier(owner)] = handler
    }

    func remove(_ owner: AnyObject) {
        handlers[ObjectIdentifier(owner)] = nil
    }

    func send(_ time: Double) {
        for handler in handlers.values { handler(time) }
    }
}
