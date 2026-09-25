import MyScreenArtCore
import Observation
import SwiftUI

/// Root object shared by every scene. Each area owns its controller:
/// - `recording` (App/Sources/Recorder): recording lifecycle, HUD, menu-bar content
/// - `exports`   (App/Sources/Export):   running exports
/// - `editors`   (App/Sources/Editor):   open editor sessions and their pending saves
/// - `router`    (App/Sources/Shell):    opening windows from anywhere (menus, hotkeys, URLs, intents)
@MainActor
@Observable
final class AppModel {
    let environment: AppEnvironment
    let router: AppRouter
    let recording: RecordingController
    let exports: ExportCenter
    let editors: EditorSessions

    init(environment: AppEnvironment) {
        self.environment = environment
        let router = AppRouter()
        self.router = router
        self.recording = RecordingController(environment: environment, router: router)
        self.exports = ExportCenter()
        self.editors = EditorSessions()
    }

    /// True while quitting or updating would lose work.
    var isBusy: Bool { recording.isActive || exports.isExporting || editors.hasPendingSaves }
}
