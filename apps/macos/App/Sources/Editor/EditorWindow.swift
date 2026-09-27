import MyScreenArtCore
import ProjectKit
import RenderKit
import SwiftUI

/// Editor window for one recording package: loads the project off the main actor, then shows ``EditorView``.
struct EditorWindow: View {
    let packageURL: URL?

    @Environment(AppModel.self) private var app
    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case loaded(EditorModel)
        case failed(EditorLoadError)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Opening recording…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let model):
                EditorView(model: model)
            case .failed(let error):
                failure(error)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .themedWindow()
        .task(id: packageURL) { await load() }
        .onDisappear {
            if case .loaded(let model) = phase {
                let editors = app.editors
                Task { await editors.close(model) }
            }
        }
    }

    private func failure(_ error: EditorLoadError) -> some View {
        ContentUnavailableView {
            Label(error.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            HStack {
                Button("Back to Library") { app.router.showLibrary() }
                if case .corruptEdit = error {
                    Button("Reset Edits") { Task { await load(resetEdit: true) } }
                }
            }
        }
        .navigationTitle("Editor")
    }

    private func load(resetEdit: Bool = false) async {
        guard let packageURL else {
            phase = .failed(.noPackage)
            return
        }
        if case .loaded = phase { return }
        phase = .loading
        let autoZoom = UserDefaults.standard.object(forKey: EditorModel.autoZoomDefaultsKey) as? Bool ?? true
        do {
            let project = try await EditorLoader.loadProject(at: packageURL, autoZoom: autoZoom, resetEdit: resetEdit)
            let renderer: ProjectRenderer
            do {
                // A first guess at the preview size; the preview view reports its real backing size once laid out.
                let frameRate = min(60, max(24, project.meta.screen.frameRate))
                renderer = try await ProjectRenderer(
                    project: project,
                    options: .preview(maxSize: CGSize(width: 1600, height: 1000), frameRate: frameRate))
            } catch {
                throw EditorLoadError.render(String(describing: error))
            }
            let model = EditorModel(project: project, renderer: renderer)
            await app.editors.register(model, resetEdit: resetEdit)
            phase = .loaded(model)
            Log.app.info("Opened editor for \(packageURL.lastPathComponent, privacy: .public)")
        } catch let error as EditorLoadError {
            Log.app.error("Couldn't open \(packageURL.lastPathComponent, privacy: .public): \(error.message)")
            phase = .failed(error)
        } catch {
            phase = .failed(.other(error.localizedDescription))
        }
    }
}

enum EditorLoadError: Error {
    case noPackage
    case missingMeta
    case unreadable(String)
    case corruptEdit(String)
    case render(String)
    case other(String)

    var title: String {
        switch self {
        case .noPackage: "No Recording"
        case .missingMeta: "Not a Recording"
        case .unreadable: "Can't Open Recording"
        case .corruptEdit: "Edits Are Damaged"
        case .render: "Can't Play Recording"
        case .other: "Can't Open Recording"
        }
    }

    var message: String {
        switch self {
        case .noPackage: "Open a recording from the library."
        case .missingMeta: "The package has no meta.json, so it isn't a MyScreenArt recording."
        case .unreadable(let detail): "The recording's files couldn't be read.\n\(detail)"
        case .corruptEdit(let detail):
            "edit.json couldn't be read. Resetting starts the edit over (the recording itself is untouched).\n\(detail)"
        case .render(let detail): "The recording's media couldn't be prepared for playback.\n\(detail)"
        case .other(let detail): detail
        }
    }
}

/// File I/O for opening a recording, off the main actor.
enum EditorLoader {
    /// Reads meta, events and cursors, and the saved edit. With no `edit.json` (or `resetEdit`), creates the
    /// initial edit (auto-zooms from clicks when `autoZoom`) and saves it.
    @concurrent
    static func loadProject(at url: URL, autoZoom: Bool, resetEdit: Bool) async throws -> RenderProject {
        let package = RecordingPackage(url: url)
        let meta: RecordingMeta
        do {
            meta = try package.loadMeta()
        } catch RecordingPackage.PackageError.missingMeta {
            throw EditorLoadError.missingMeta
        } catch {
            throw EditorLoadError.unreadable(String(describing: error))
        }
        let events: [InputEvent]
        let cursors: CursorIndex
        do {
            events = try package.loadEvents()
            cursors = try package.loadCursorIndex()
        } catch {
            throw EditorLoadError.unreadable(String(describing: error))
        }
        let edit: EditConfig
        let saved: EditConfig?
        do {
            saved = resetEdit ? nil : try package.loadEdit()
        } catch {
            throw EditorLoadError.corruptEdit(String(describing: error))
        }
        if let saved {
            edit = saved.normalized(duration: meta.duration)
        } else {
            edit = try package.loadEffectiveEdit(meta: meta, autoZoom: autoZoom)
        }
        return RenderProject(package: package, meta: meta, edit: edit, events: events, cursorIndex: cursors)
    }
}
