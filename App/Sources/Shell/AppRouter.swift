import SwiftUI

/// Opens windows from places that aren't SwiftUI views (menus, hotkeys, URL scheme, App Intents).
/// Scene IDs are the constants below; `MyScreenArtApp` declares the scenes.
@MainActor
@Observable
final class AppRouter {
    enum SceneID {
        static let library = "library"
        static let recorder = "recorder"
        static let editor = "editor"
    }

    /// Set once by the first scene that appears (see `RouterBinder`).
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    /// Which source tab the recorder should show when it next opens.
    var recorderSourceRequest: RecorderSourceKind = .display

    func showLibrary() {
        openWindowAction?(id: SceneID.library)
        NSApp.activate()
    }

    func showRecorder(source: RecorderSourceKind? = nil) {
        if let source { recorderSourceRequest = source }
        openWindowAction?(id: SceneID.recorder)
        NSApp.activate()
    }

    func openEditor(for packageURL: URL) {
        openWindowAction?(id: SceneID.editor, value: packageURL)
        NSApp.activate()
    }
}

enum RecorderSourceKind: String, CaseIterable, Sendable {
    case display
    case window
    case region
}

/// Captures SwiftUI's `openWindow` action into the router. Attach to every root scene view.
struct RouterBinder: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let router: AppRouter

    func body(content: Content) -> some View {
        content.onAppear { if router.openWindowAction == nil { router.openWindowAction = openWindow } }
    }
}

extension View {
    func bindRouter(_ router: AppRouter) -> some View { modifier(RouterBinder(router: router)) }
}
