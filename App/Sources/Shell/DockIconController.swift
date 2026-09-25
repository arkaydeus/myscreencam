import AppKit
import MyScreenArtCore
import Observation

/// "Hide Dock icon when idle": switches between `.regular` and `.accessory` activation policies.
///
/// Re-evaluated only on events: window notifications (a window became key/main, closed, (de)miniaturised,
/// or changed visibility), recording state and the preference (both via Observation). Nothing polls.
@MainActor
final class DockIconController {
    private let settings: ShellSettings
    private let recording: RecordingController
    private var observers: [any NSObjectProtocol] = []
    private var current: DockIconPolicy?

    init(settings: ShellSettings, recording: RecordingController) {
        self.settings = settings
        self.recording = recording
    }

    func start() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // `willClose` fires while the window is still visible: evaluate on the next turn.
                    DispatchQueue.main.async { self?.update() }
                })
        }
        observeState()
        update()
    }

    /// Tracks the preference and the recording state; re-arms after every change.
    private func observeState() {
        withObservationTracking {
            _ = settings.hideDockIconWhenIdle
            _ = recording.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observeState()
            }
        }
    }

    func update() {
        let policy = DockIconPolicy.resolve(
            hideWhenIdle: settings.hideDockIconWhenIdle,
            hasVisibleWindows: Self.hasVisibleAppWindows(),
            isRecording: recording.isActive)
        guard policy != current else { return }
        current = policy
        switch policy {
        case .regular:
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
                if NSApp.windows.contains(where: Self.isAppWindow) { NSApp.activate() }
            }
        case .accessory:
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
        Log.app.debug("Dock icon policy: \(String(describing: policy), privacy: .public)")
    }

    /// Titled document/app windows that are on screen or minimised. Panels (HUD, overlays), menus and the
    /// status item's window don't count.
    static func hasVisibleAppWindows() -> Bool {
        NSApp.windows.contains { isAppWindow($0) && ($0.isVisible || $0.isMiniaturized) }
    }

    private static func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.canBecomeMain
    }
}
