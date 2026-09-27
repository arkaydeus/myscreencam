import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A ``ScreenSource`` resolved against the current shareable content.
struct ResolvedContent {
    let filter: SCContentFilter
    /// For regions: the rectangle in display-local points (`SCStreamConfiguration.sourceRect`).
    let sourceRect: CGRect?
    /// Captured area in global points (origin top-left of the main display).
    let contentRect: CGRect
    /// Pixels per point of the captured content.
    let scale: Double
    /// The display being captured (nil for window capture).
    let displayID: CGDirectDisplayID?
    /// The captured window's owner (window capture only).
    let windowOwnerPID: pid_t?
}

enum ContentResolver {
    static func resolve(_ source: ScreenSource, excludingOwnApplication: Bool) async throws -> ResolvedContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        switch source {
        case .display(let id):
            let display = try display(id, in: content)
            let filter = displayFilter(display, content: content, excludingOwnApplication: excludingOwnApplication)
            return ResolvedContent(
                filter: filter, sourceRect: nil, contentRect: CGDisplayBounds(id),
                scale: scale(of: filter, display: id), displayID: id, windowOwnerPID: nil)

        case .region(let id, let rect):
            let display = try display(id, in: content)
            let bounds = CGDisplayBounds(id)
            let region = CaptureGeometry.clampedRegion(rect, displaySize: bounds.size)
            guard region.width >= 1, region.height >= 1 else { throw CaptureError.emptyRegion }
            let filter = displayFilter(display, content: content, excludingOwnApplication: excludingOwnApplication)
            let global = region.offsetBy(dx: bounds.minX, dy: bounds.minY)
            return ResolvedContent(
                filter: filter, sourceRect: region, contentRect: global, scale: scale(of: filter, display: id),
                displayID: id, windowOwnerPID: nil)

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.sourceNotFound("window \(id)")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = filter.pointPixelScale > 0 ? Double(filter.pointPixelScale) : 2
            return ResolvedContent(
                filter: filter, sourceRect: nil, contentRect: window.frame, scale: scale, displayID: nil,
                windowOwnerPID: window.owningApplication?.processID)
        }
    }

    private static func display(_ id: CGDirectDisplayID, in content: SCShareableContent) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.sourceNotFound("display \(id)")
        }
        return display
    }

    /// The whole display minus this app's windows (recorder UI, HUD, overlays).
    private static func displayFilter(
        _ display: SCDisplay, content: SCShareableContent, excludingOwnApplication: Bool
    ) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = excludingOwnApplication ? content.applications.filter { $0.processID == pid } : []
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    private static func scale(of filter: SCContentFilter, display: CGDirectDisplayID) -> Double {
        if filter.pointPixelScale > 0 { return Double(filter.pointPixelScale) }
        return CaptureSources.displayInfo(for: display, name: nil).scale
    }
}
