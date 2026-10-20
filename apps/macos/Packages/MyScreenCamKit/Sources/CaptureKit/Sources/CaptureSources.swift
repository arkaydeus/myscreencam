import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Lists what can be captured and renders still previews. All calls need Screen Recording permission
/// (ScreenCaptureKit throws without it).
public enum CaptureSources {
    /// Connected displays, main display first.
    public static func displays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ids = content.displays.map(\.displayID)
        let names = await screenNames()
        return ids.map { displayInfo(for: $0, name: names[$0]) }
            .sorted {
                ($0.isMain ? 0 : 1, $0.frame.minX, $0.frame.minY) < ($1.isMain ? 0 : 1, $1.frame.minX, $1.frame.minY)
            }
    }

    /// On-screen, titled, normal-level (layer 0) windows of other applications (and this one's, if
    /// `includingOwnApplication`), front to back.
    public static func windows(includingOwnApplication: Bool = false) async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window -> WindowInfo? in
            guard window.windowLayer == 0, window.isOnScreen, let title = window.title, !title.isEmpty,
                let app = window.owningApplication, includingOwnApplication || app.processID != ownPID,
                window.frame.width >= 1, window.frame.height >= 1
            else { return nil }
            return WindowInfo(
                id: window.windowID, title: title, appName: app.applicationName.nilIfEmpty,
                bundleID: app.bundleIdentifier.nilIfEmpty, processID: app.processID, frame: window.frame)
        }
    }

    /// A still image of the source, at most `maxPixelWidth` wide, for the recorder's source preview.
    public static func thumbnail(of source: ScreenSource, maxPixelWidth: Int = 480) async throws -> CGImage {
        let resolved = try await ContentResolver.resolve(source, excludingOwnApplication: true)
        let configuration = SCStreamConfiguration()
        let size = resolved.contentRect.size
        let scale = min(resolved.scale, Double(maxPixelWidth) / max(1, Double(size.width)))
        let pixels = CaptureGeometry.evenPixelSize(points: size, scale: scale)
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = false
        if let sourceRect = resolved.sourceRect { configuration.sourceRect = sourceRect }
        return try await SCScreenshotManager.captureImage(contentFilter: resolved.filter, configuration: configuration)
    }

    /// Display facts from Core Graphics (thread-safe, no AppKit).
    static func displayInfo(for id: CGDirectDisplayID, name: String?) -> DisplayInfo {
        let frame = CGDisplayBounds(id)
        var scale = 1.0
        var pixelWidth = Int(frame.width)
        var pixelHeight = Int(frame.height)
        if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            scale = Double(mode.pixelWidth) / Double(mode.width)
        }
        return DisplayInfo(
            id: id, name: name ?? "Display \(id)", frame: frame, scale: scale, pixelWidth: pixelWidth,
            pixelHeight: pixelHeight, isMain: CGDisplayIsMain(id) != 0)
    }

    /// `NSScreen` localised names keyed by display ID. AppKit screen objects are read on the main actor.
    @MainActor
    static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return names
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
