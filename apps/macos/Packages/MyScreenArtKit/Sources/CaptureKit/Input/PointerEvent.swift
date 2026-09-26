import CoreGraphics
import ProjectKit

/// A pointer event from ``InputEventTap``, before it's placed on a recording's session timeline.
public struct PointerEvent: Sendable, Equatable {
    /// Host-clock seconds (same clock as capture sample buffers).
    public var hostTime: Double
    public var kind: InputEvent.Kind
    /// Global position in points, origin top-left of the main display (y down).
    public var location: CGPoint
    /// Position normalised to the content rect at the time of the event (0…1, y down; outside = off content).
    public var x: Double
    public var y: Double
    /// 0 = left, 1 = right, 2+ = other. Set for down/up and for moves while a button is held (drags).
    public var button: Int?
    /// Scroll deltas in points (scroll events only).
    public var dx: Double?
    public var dy: Double?

    public init(
        hostTime: Double, kind: InputEvent.Kind, location: CGPoint, x: Double, y: Double, button: Int? = nil,
        dx: Double? = nil, dy: Double? = nil
    ) {
        self.hostTime = hostTime
        self.kind = kind
        self.location = location
        self.x = x
        self.y = y
        self.button = button
        self.dx = dx
        self.dy = dy
    }

    /// The `events.jsonl` record for this event at session time `t`.
    public func inputEvent(sessionTime t: Double, cursor: Int?) -> InputEvent {
        InputEvent(t: t, kind: kind, x: x, y: y, button: button, cursor: cursor, dx: dx, dy: dy)
    }
}

/// Maps global points into a content rect's normalised space.
public enum PointerNormalizer {
    /// `(p − origin) / size`; values outside 0…1 mean the pointer is outside the content.
    public static func normalize(_ point: CGPoint, in rect: CGRect) -> (x: Double, y: Double) {
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        return (
            Double((point.x - rect.minX) / rect.width),
            Double((point.y - rect.minY) / rect.height)
        )
    }

    /// Converts a tap event into a ``PointerEvent``. Returns nil for event types that aren't recorded.
    public static func pointerEvent(
        from event: CGEvent, type: CGEventType, hostTime: Double, contentRect: CGRect
    ) -> PointerEvent? {
        let location = event.location
        let (x, y) = normalize(location, in: contentRect)
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        func make(_ kind: InputEvent.Kind, button: Int? = nil, dx: Double? = nil, dy: Double? = nil) -> PointerEvent {
            PointerEvent(hostTime: hostTime, kind: kind, location: location, x: x, y: y, button: button, dx: dx, dy: dy)
        }
        switch type {
        case .mouseMoved: return make(.move)
        case .leftMouseDragged: return make(.move, button: 0)
        case .rightMouseDragged: return make(.move, button: 1)
        case .otherMouseDragged: return make(.move, button: max(2, button))
        case .leftMouseDown: return make(.down, button: 0)
        case .rightMouseDown: return make(.down, button: 1)
        case .otherMouseDown: return make(.down, button: max(2, button))
        case .leftMouseUp: return make(.up, button: 0)
        case .rightMouseUp: return make(.up, button: 1)
        case .otherMouseUp: return make(.up, button: max(2, button))
        case .scrollWheel:
            return make(
                .scroll, dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        default: return nil
        }
    }
}
