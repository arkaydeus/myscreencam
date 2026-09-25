import Foundation
import MyScreenArtCore
import Observation
import Sparkle

/// Sparkle 2 updates. The feed is `SUFeedURL` in `App/Info.plist`; the EdDSA public key comes from the
/// `SPARKLE_PUBLIC_ED_KEY` build setting in `project.yml`. Until a real key is set, the updater isn't
/// started (Sparkle would refuse to run and show an error) and "Check for Updates…" is disabled.
///
/// Automatic checks are off in Debug builds (`MSA_SPARKLE_AUTOMATIC_CHECKS`). A downloaded update never
/// relaunches the app while `AppModel.isBusy` (recording, exporting or saving): the relaunch is postponed
/// until the model becomes idle.
@MainActor
@Observable
final class UpdateController: NSObject {
    /// False when the build has no valid EdDSA key (see `docs/release.md`).
    let isConfigured: Bool
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstall: (() -> Void)?

    init(model: AppModel, bundle: Bundle = .main) {
        self.model = model
        self.isConfigured = UpdateConfiguration.isValidEdDSAPublicKey(
            bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        super.init()
    }

    /// Creates and starts the updater. Call once, after launch.
    func start() {
        guard isConfigured, controller == nil else {
            if !isConfigured { Log.app.info("Updates disabled: SUPublicEDKey is not configured") }
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Invokes Sparkle's postponed install once `model.isBusy` turns false (Observation, no timers).
    private func installWhenIdle() {
        guard pendingInstall != nil else { return }
        if !model.isBusy {
            let install = pendingInstall
            pendingInstall = nil
            Log.app.info("App idle; relaunching to finish the update")
            install?()
            return
        }
        withObservationTracking {
            _ = model.isBusy
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.installWhenIdle() }
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard model.isBusy else { return false }
        Log.app.info("Postponing update relaunch until recording/export/saves finish")
        pendingInstall = installHandler
        installWhenIdle()
        return true
    }
}
