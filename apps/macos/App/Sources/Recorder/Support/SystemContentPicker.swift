import CaptureKit
import CoreGraphics
import Foundation
import MyScreenCamCore
import ScreenCaptureKit

/// "Choose with System Picker": presents `SCContentSharingPicker` for a single display or window and maps the
/// chosen filter back to a `ScreenSource` (via `SCContentFilter.includedDisplays/includedWindows`, macOS 15.2+).
/// On earlier systems the filter can't be mapped, so the button isn't offered.
@MainActor
final class SystemContentPicker: NSObject {
    static var isSupported: Bool {
        if #available(macOS 15.2, *) { return true }
        return false
    }

    private var completion: ((ScreenSource?) -> Void)?

    func present(completion: @escaping (ScreenSource?) -> Void) {
        guard Self.isSupported else {
            completion(nil)
            return
        }
        self.completion = completion
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        if let bundleID = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundleID] }
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    private func finish(_ source: ScreenSource?) {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        let completion = completion
        self.completion = nil
        completion?(source)
    }

    /// Reads the IDs out of the filter (on the picker's callback thread; `SCContentFilter` isn't `Sendable`).
    nonisolated private static func source(from filter: SCContentFilter) -> ScreenSource? {
        guard #available(macOS 15.2, *) else { return nil }
        switch filter.style {
        case .window: return filter.includedWindows.first.map { .window($0.windowID) }
        case .display: return filter.includedDisplays.first.map { .display($0.displayID) }
        default: return nil
        }
    }
}

extension SystemContentPicker: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        let source = Self.source(from: filter)
        if source == nil { Log.app.notice("System picker returned content that can't be recorded as one source") }
        Task { @MainActor in self.finish(source) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Log.app.error("System picker failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in self.finish(nil) }
    }
}
