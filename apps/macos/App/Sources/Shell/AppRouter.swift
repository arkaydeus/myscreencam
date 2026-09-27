import MyScreenCamCore
import SwiftUI

/// Opens windows from places that aren't SwiftUI views (menus, hotkeys, URL scheme, App Intents).
/// Scene IDs are the constants below; `MyScreenCamApp` declares the scenes.
///
/// Requests made before any scene has appeared (a URL or document that launched the app, an App Intent)
/// are queued and replayed, in order, as soon as the first scene binds `openWindowAction`.
@MainActor
@Observable
final class AppRouter {
    enum SceneID {
        static let library = "library"
        static let recorder = "recorder"
        static let editor = "editor"
    }

    /// Set once by the first scene that appears (see `RouterBinder`). Setting it replays queued requests.
    @ObservationIgnored var openWindowAction: OpenWindowAction? {
        didSet { if openWindowAction != nil { drainPending() } }
    }
    /// Set alongside `openWindowAction`; used to close the launch-time Library window when the app was
    /// launched to open something else.
    @ObservationIgnored var dismissWindowAction: DismissWindowAction?
    /// Which source tab the recorder should show when it next opens.
    var recorderSourceRequest: RecorderSourceKind = .display

    @ObservationIgnored private var pending: [(OpenWindowAction) -> Void] = []
    /// True while requests that arrived during launch (before the first scene) are waiting.
    @ObservationIgnored private var closeLibraryAfterLaunchRequests = false

    /// True once a scene has bound the router and windows can be opened directly.
    var isBound: Bool { openWindowAction != nil }

    func showLibrary() {
        closeLibraryAfterLaunchRequests = false
        perform { $0(id: SceneID.library) }
    }

    func showRecorder(source: RecorderSourceKind? = nil) {
        if let source { recorderSourceRequest = source }
        perform { $0(id: SceneID.recorder) }
    }

    func openEditor(for packageURL: URL) {
        perform { $0(id: SceneID.editor, value: packageURL) }
    }

    /// Called by the app delegate after a URL or document that launched the app has requested its window:
    /// the Library window SwiftUI shows at launch is closed again once that window is open.
    func preferLaunchTarget() {
        if isBound {
            Task { @MainActor [weak self] in self?.dismissWindowAction?(id: SceneID.library) }
        } else {
            closeLibraryAfterLaunchRequests = true
        }
    }

    private func perform(_ request: @escaping (OpenWindowAction) -> Void) {
        guard let openWindowAction else {
            pending.append(request)
            return
        }
        request(openWindowAction)
        NSApp.activate()
    }

    private func drainPending() {
        guard let openWindowAction, !pending.isEmpty else { return }
        let requests = pending
        pending.removeAll()
        Log.app.info("Replaying \(requests.count) window request(s) queued before launch")
        for request in requests { request(openWindowAction) }
        NSApp.activate()
        if closeLibraryAfterLaunchRequests {
            closeLibraryAfterLaunchRequests = false
            // Let the requested window order in before the Library goes away.
            Task { @MainActor [weak self] in self?.dismissWindowAction?(id: SceneID.library) }
        }
    }
}

enum RecorderSourceKind: String, CaseIterable, Sendable {
    case display
    case window
    case region

    init(_ source: AppURLCommand.Source) {
        switch source {
        case .display: self = .display
        case .window: self = .window
        case .region: self = .region
        }
    }
}

/// Captures SwiftUI's `openWindow` action into the router. Attach to every root scene view.
struct RouterBinder: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let router: AppRouter

    func body(content: Content) -> some View {
        content.onAppear {
            if router.openWindowAction == nil {
                router.dismissWindowAction = dismissWindow
                router.openWindowAction = openWindow
            }
        }
    }
}

extension View {
    func bindRouter(_ router: AppRouter) -> some View { modifier(RouterBinder(router: router)) }
}
