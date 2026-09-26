import AppKit
import CaptureKit
import CoreGraphics

/// Display lookups that don't need Screen Recording permission (AppKit + Core Graphics only), so the recorder
/// can list displays and place overlays before permission is granted without triggering a ScreenCaptureKit
/// prompt.
enum ScreenGeometry {
    /// Connected displays from `NSScreen`, main display first (same shape as `CaptureSources.displays()`).
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let id = screen.displayID else { return nil }
            let bounds = CGDisplayBounds(id)
            var pixelWidth = Int(bounds.width * screen.backingScaleFactor)
            var pixelHeight = Int(bounds.height * screen.backingScaleFactor)
            if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth > 0 {
                pixelWidth = mode.pixelWidth
                pixelHeight = mode.pixelHeight
            }
            return DisplayInfo(
                id: id, name: screen.localizedName, frame: bounds, scale: screen.backingScaleFactor,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, isMain: CGDisplayIsMain(id) != 0)
        }
        .sorted {
            ($0.isMain ? 0 : 1, $0.frame.minX, $0.frame.minY) < ($1.isMain ? 0 : 1, $1.frame.minX, $1.frame.minY)
        }
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// The screen showing most of a rectangle given in global Core Graphics points (origin top-left of the main
    /// display, y down), e.g. `WindowInfo.frame`.
    static func screen(containingCGRect rect: CGRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let overlap = CGDisplayBounds(id).intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen
    }

    /// The screen a recording of `source` happens on (for the countdown overlay).
    static func screen(for source: ScreenSource, windowFrame: CGRect?) -> NSScreen? {
        switch source {
        case .display(let id), .region(let id, _): screen(for: id)
        case .window: windowFrame.flatMap(screen(containingCGRect:))
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension DisplayInfo {
    /// "Built-in Retina Display (3024×1964) (Primary)".
    var pickerTitle: String {
        "\(name) (\(pixelWidth)×\(pixelHeight))" + (isMain ? " (Primary)" : "")
    }
}

extension WindowInfo {
    /// "Safari — Apple".
    var pickerTitle: String {
        if let appName, appName != title { return "\(appName) — \(title)" }
        return title
    }

    var sizeDescription: String { "\(Int(frame.width))×\(Int(frame.height))" }
}

/// "mm:ss", or "h:mm:ss" past an hour.
func formatElapsed(_ seconds: Int) -> String {
    let seconds = max(0, seconds)
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    let secs = seconds % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%02d:%02d", minutes, secs)
}
