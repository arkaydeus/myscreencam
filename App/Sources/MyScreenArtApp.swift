import MyScreenArtCore
import SwiftUI

@main
struct MyScreenArtApp: App {
    @State private var model = AppModel(environment: AppEnvironment.live())

    var body: some Scene {
        Window("Library", id: AppRouter.SceneID.library) {
            LibraryView()
                .environment(model)
                .environment(model.environment)
                .bindRouter(model.router)
        }
        .defaultSize(width: 1100, height: 720)

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

        MenuBarExtra("MyScreenArt", systemImage: "record.circle") {
            RecorderMenuBarContent()
                .environment(model)
        }
    }
}
