import AppKit
import MyScreenArtCore
import Observation

/// Owns the shell services: preferences, actions, global hotkeys, Dock-icon policy and updates.
/// Created in `MyScreenArtApp.init` next to the `AppModel`; the app delegate and the menus use it.
@MainActor
@Observable
final class AppShell {
    let model: AppModel
    let settings: ShellSettings
    let actions: ShellActions
    let updates: UpdateController
    @ObservationIgnored let hotkeys: GlobalHotkeys
    @ObservationIgnored let dockIcon: DockIconController
    @ObservationIgnored private var started = false

    init(model: AppModel) {
        self.model = model
        let settings = ShellSettings()
        let actions = ShellActions(model: model)
        self.settings = settings
        self.actions = actions
        self.updates = UpdateController(model: model)
        self.hotkeys = GlobalHotkeys(actions: actions)
        self.dockIcon = DockIconController(settings: settings, recording: model.recording)
    }

    /// URL schemes this build answers to (`CFBundleURLSchemes`, e.g. `myscreenart-dev` in Debug).
    static let urlSchemes: Set<String> = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() })
    }()

    /// Called from `applicationDidFinishLaunching`.
    func start() {
        guard !started else { return }
        started = true
        // The Midnight Glass theme is dark-only; menus, alerts and panels follow it.
        AppTheme.applyAppearance()
        dockIcon.start()
        observeHotkeyPreference()
        updates.start()
    }

    private func observeHotkeyPreference() {
        withObservationTracking {
            hotkeys.setEnabled(settings.globalHotkeysEnabled)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeHotkeyPreference() }
        }
    }
}
