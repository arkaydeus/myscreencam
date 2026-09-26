import CoreGraphics

/// The rect pointer positions are normalised against, kept current while events arrive.
///
/// For window capture it re-reads the window's frame at most every `minimumInterval` seconds (default 0.1, i.e.
/// ≤ 10 Hz), and **only when an event asks for it**, so an idle pointer costs nothing. Moving the window
/// during recording is therefore reflected within 100 ms. If the window can no longer be found it reports
/// ``isSourceGone``.
public struct ContentRectTracker: Sendable {
    public enum Mode: Sendable, Equatable {
        case fixed
        case window(CGWindowID)
    }

    public let mode: Mode
    public let minimumInterval: Double
    public private(set) var rect: CGRect
    public private(set) var isSourceGone = false
    private var lastRefresh = -Double.infinity

    public init(mode: Mode, rect: CGRect, minimumInterval: Double = 0.1) {
        self.mode = mode
        self.rect = rect
        self.minimumInterval = minimumInterval
    }

    /// Replaces the rect (e.g. the owner learned a new frame some other way).
    public mutating func setRect(_ rect: CGRect) {
        self.rect = rect
    }

    /// The rect to use for an event at `hostTime`, refreshing a tracked window's frame if it's due.
    /// - Parameter frameProvider: current frame of a window, or nil if it no longer exists.
    public mutating func rect(at hostTime: Double, frameProvider: (CGWindowID) -> CGRect?) -> CGRect {
        guard case .window(let id) = mode, !isSourceGone, hostTime - lastRefresh >= minimumInterval else {
            return rect
        }
        lastRefresh = hostTime
        if let frame = frameProvider(id) {
            rect = frame
        } else {
            isSourceGone = true
        }
        return rect
    }
}
