import CoreGraphics
import Darwin

/// Turns raw tap events into ``PointerEvent``s: timestamp conversion, content-rect tracking and move
/// coalescing. Pure state machine (no threads), so it's unit-testable with synthesised `CGEvent`s.
public struct InputEventProcessor: Sendable {
    public private(set) var timestamps = EventTimestampConverter()
    public private(set) var tracker: ContentRectTracker
    /// Moves (and drags) closer together than this are dropped; buttons and scrolls always pass.
    /// High-rate mice report up to 1 kHz, far more than a 60 fps recording needs.
    public let minimumMoveInterval: Double
    private var lastMoveTime = -Double.infinity
    private var reportedGone = false

    public init(tracker: ContentRectTracker, minimumMoveInterval: Double = 1.0 / 240) {
        self.tracker = tracker
        self.minimumMoveInterval = minimumMoveInterval
    }

    public enum Output: Sendable, Equatable {
        case event(PointerEvent)
        /// The tracked window disappeared (reported once).
        case sourceGone
    }

    public mutating func setContentRect(_ rect: CGRect) {
        tracker.setRect(rect)
    }

    /// Processes one event. `nowTicks` is `mach_absolute_time()` at receipt (for timestamp calibration).
    public mutating func process(
        type: CGEventType, event: CGEvent, nowTicks: UInt64 = mach_absolute_time(),
        frameProvider: (CGWindowID) -> CGRect?
    ) -> [Output] {
        let hostTime = timestamps.hostSeconds(eventTimestamp: event.timestamp, nowTicks: nowTicks)
        let rect = tracker.rect(at: hostTime, frameProvider: frameProvider)
        var outputs: [Output] = []
        if tracker.isSourceGone, !reportedGone {
            reportedGone = true
            outputs.append(.sourceGone)
        }
        guard
            let pointer = PointerNormalizer.pointerEvent(from: event, type: type, hostTime: hostTime, contentRect: rect)
        else { return outputs }
        if pointer.kind == .move {
            guard hostTime - lastMoveTime >= minimumMoveInterval else { return outputs }
            lastMoveTime = hostTime
        }
        outputs.append(.event(pointer))
        return outputs
    }
}
