import ProjectKit
import SwiftUI

/// The editor layout: header, preview, transport and timeline on the left, the 320 pt inspector on the right.
struct EditorView: View {
    @Bindable var model: EditorModel
    @Environment(\.undoManager) private var undoManager
    @State private var windowHolder = WindowHolder()

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(model: model) { windowHolder.window?.close() }
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewContainer(model: model)
                        .frame(minHeight: 240)
                    Divider()
                    TransportBar(model: model)
                    Divider()
                    TimelineContainer(model: model)
                        .frame(height: TimelineMetrics.preferredHeight(for: model.recordedStreams))
                }
                Divider()
                InspectorView(model: model)
                    .frame(width: 320)
            }
        }
        .background(EditorWindowHooks(model: model, holder: windowHolder))
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(package: model.package, edit: model.edit)
        }
        .focusedSceneValue(\.exportAction) {
            model.pause()
            model.showExport = true
        }
        .navigationTitle(model.meta.name)
    }
}

/// The editor's `NSWindow`, captured by ``EditorWindowHooks``.
@MainActor
final class WindowHolder {
    weak var window: NSWindow?
}

/// Window-level AppKit hooks: editor keyboard shortcuts (a local key monitor, ignored while a text field has focus)
/// and pausing playback when the window is occluded or minimised.
struct EditorWindowHooks: NSViewRepresentable {
    let model: EditorModel
    let holder: WindowHolder

    func makeNSView(context: Context) -> HooksView {
        HooksView(model: model, holder: holder)
    }

    func updateNSView(_ nsView: HooksView, context: Context) {}

    static func dismantleNSView(_ nsView: HooksView, coordinator: ()) {
        nsView.teardown()
    }

    final class HooksView: NSView {
        private weak var model: EditorModel?
        private let holder: WindowHolder
        private var keyMonitor: Any?
        private var occlusionObserver: (any NSObjectProtocol)?

        init(model: EditorModel, holder: WindowHolder) {
            self.model = model
            self.holder = holder
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard let window else { return }
            holder.window = window
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Self.route(event, through: self)
            }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.model?.windowVisibilityChanged(visible: window.occlusionState.contains(.visible))
                }
            }
        }

        func teardown() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = nil
        }

        static func route(_ event: NSEvent, through hooks: HooksView?) -> NSEvent? {
            guard let hooks else { return event }
            return hooks.handle(event)
        }

        /// Returns nil when the key was handled.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let model, let window, event.window === window, window.attachedSheet == nil else { return event }
            if let responder = window.firstResponder, responder is NSText || responder is NSTextField { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let shift = event.modifierFlags.contains(.shift)
            let frame = 1 / Double(model.previewFrameRate)
            switch event.keyCode {
            case 49: model.togglePlay()  // Space
            case 123: model.step(by: shift ? -1 : -frame)  // ←
            case 124: model.step(by: shift ? 1 : frame)  // →
            case 115: model.seek(to: 0)  // Home
            case 119: model.seek(to: model.timeline.duration)  // End
            case 51, 117: model.deleteSelection()  // Backspace, forward Delete
            case 53:  // Esc
                if model.isPickingZoomTarget {
                    model.isPickingZoomTarget = false
                } else {
                    model.selection = nil
                }
            default:
                guard event.charactersIgnoringModifiers?.lowercased() == "c" else { return event }
                model.cutAtPlayhead()
            }
            return nil
        }
    }
}
