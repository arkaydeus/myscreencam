import CoreGraphics

/// What to capture.
public enum ScreenSource: Sendable, Hashable {
    /// A whole display (the app's own windows are excluded).
    case display(CGDirectDisplayID)
    /// A single window, independent of what's in front of it.
    case window(CGWindowID)
    /// A rectangle of a display, in that display's points with the origin at its top-left.
    case region(display: CGDirectDisplayID, rect: CGRect)
}

/// A capturable display.
public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public var id: CGDirectDisplayID
    /// Localised name from `NSScreen.localizedName`, e.g. "Built-in Retina Display".
    public var name: String
    /// Frame in global points, origin at the top-left of the main display (y down), like `CGDisplayBounds`.
    public var frame: CGRect
    /// Backing scale factor (pixels per point) of the current display mode.
    public var scale: Double
    /// Native pixel size of the current mode (points × scale).
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isMain: Bool

    public init(
        id: CGDirectDisplayID, name: String, frame: CGRect, scale: Double, pixelWidth: Int, pixelHeight: Int,
        isMain: Bool
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
    }
}

/// A capturable on-screen application window.
public struct WindowInfo: Sendable, Hashable, Identifiable {
    public var id: CGWindowID
    public var title: String
    public var appName: String?
    public var bundleID: String?
    public var processID: pid_t
    /// Frame in global points, origin at the top-left of the main display (y down).
    public var frame: CGRect

    public init(
        id: CGWindowID, title: String, appName: String?, bundleID: String?, processID: pid_t, frame: CGRect
    ) {
        self.id = id
        self.title = title
        self.appName = appName
        self.bundleID = bundleID
        self.processID = processID
        self.frame = frame
    }
}

/// Pixel-size arithmetic for capture and encoding.
public enum CaptureGeometry {
    /// Native pixel size for a content size in points: `points × scale`, rounded down to even numbers
    /// (4:2:0 chroma and the H.264/HEVC encoders need even dimensions), never below 2×2.
    public static func evenPixelSize(points: CGSize, scale: Double) -> (width: Int, height: Int) {
        (evenFloor(Double(points.width) * scale), evenFloor(Double(points.height) * scale))
    }

    /// Rounds down to an even integer, at least 2. A tiny epsilon absorbs float error (e.g. 1511.9999 × 2).
    public static func evenFloor(_ value: Double) -> Int {
        let whole = Int((value + 1e-6).rounded(.down))
        return max(2, whole - whole % 2)
    }

    /// Clips a region to its display's bounds (both in display-local points) and snaps it to whole points.
    public static func clampedRegion(_ rect: CGRect, displaySize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: displaySize)
        let clipped = rect.standardized.intersection(bounds)
        guard !clipped.isNull else { return .zero }
        return clipped.integral.intersection(bounds)
    }
}
