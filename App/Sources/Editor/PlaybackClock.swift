import Observation

/// The only playback state SwiftUI observes. `time` changes at most ~10 Hz (from a periodic time observer), and only
/// the transport's time label reads it; the playhead and meters are CALayers driven by display links.
@MainActor
@Observable
final class PlaybackClock {
    /// Edited-timeline seconds, for the time label.
    var time: Double = 0
    /// True while the player is playing (rate ≠ 0).
    var isPlaying = false
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
