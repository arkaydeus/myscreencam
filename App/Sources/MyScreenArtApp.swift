import AppIntents
import MyScreenArtCore
import SwiftUI

@main
struct MyScreenArtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var shell: AppShell

    init() {
        let model = AppModel(environment: AppEnvironment.live())
        let shell = AppShell(model: model)
        _model = State(initialValue: model)
        _shell = State(initialValue: shell)
        // Before launch finishes: URL/document opens and App Intents can arrive right after this.
        appDelegate.shell = shell
        AppDependencyManager.shared.add(dependency: model)
    }

    var body: some Scene {
        Window("Library", id: AppRouter.SceneID.library) {
            LibraryView()
                .environment(model)
                .environment(model.environment)
                .bindRouter(model.router)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { AppCommands(shell: shell) }

        Window("New Recording", id: AppRouter.SceneID.recorder) {
            RecorderView()
                .environment(model)
                .environment(model.environment)
                .bindRouter(model.router)
        }
        .windowResizability(.contentSize)

        WindowGroup("Editor", id: AppRouter.SceneID.editor, for: URL.self) { $packageURL in
            EditorWindow(packageURL: packageURL)
                .environment(model)
                .environment(model.environment)
                .bindRouter(model.router)
        }
        .defaultSize(width: 1280, height: 800)
        // URL-scheme and document opens go to `AppDelegate.application(_:open:)`, never to a new editor.
        .handlesExternalEvents(matching: [])

        MenuBarExtra("MyScreenArt", systemImage: "record.circle") {
            RecorderMenuBarContent()
                .environment(model)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.environment)
                .environment(shell)
        }
    }
}
