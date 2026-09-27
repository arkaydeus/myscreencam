import AppKit
import MyScreenArtCore
import Observation
import ServiceManagement

/// Shell preferences, persisted in `UserDefaults`. Observers (`DockIconController`, `GlobalHotkeys`)
/// react through Observation; the Settings window binds to these properties directly.
@MainActor
@Observable
final class ShellSettings {
    enum Key {
        static let hideDockIconWhenIdle = "shell.hideDockIconWhenIdle"
        static let globalHotkeysEnabled = "shell.globalHotkeysEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var hideDockIconWhenIdle: Bool {
        didSet { defaults.set(hideDockIconWhenIdle, forKey: Key.hideDockIconWhenIdle) }
    }

    var globalHotkeysEnabled: Bool {
        didSet { defaults.set(globalHotkeysEnabled, forKey: Key.globalHotkeysEnabled) }
    }

    /// Mirrors `SMAppService.mainApp`; the system (System Settings > Login Items) is the source of truth.
    private(set) var launchAtLogin: Bool
    /// Set when the last launch-at-login change failed or needs approval in System Settings.
    private(set) var launchAtLoginMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hideDockIconWhenIdle: false,
            Key.globalHotkeysEnabled: true,
        ])
        hideDockIconWhenIdle = defaults.bool(forKey: Key.hideDockIconWhenIdle)
        globalHotkeysEnabled = defaults.bool(forKey: Key.globalHotkeysEnabled)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginMessage = nil
        } catch {
            Log.app.error("Launch at login change failed: \(error, privacy: .public)")
            launchAtLoginMessage = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    /// Re-reads the login-item status (the user can change it in System Settings at any time).
    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            launchAtLoginMessage = "Approve MyScreenArt in System Settings > General > Login Items."
        }
    }
}
