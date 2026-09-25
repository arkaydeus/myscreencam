import AppKit
import ProjectKit
import SwiftUI

/// The Library window: every recording in the recordings folder as a grid of cards.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            switch environment.recordingsRoot {
            case .success(let root):
                LibraryContent(root: root)
            case .failure(let error):
                ContentUnavailableView(
                    "Recordings Folder Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct LibraryContent: View {
    let root: URL

    @Environment(AppModel.self) private var app
    @State private var model: LibraryModel
    @State private var loader = ThumbnailLoader()
    @State private var gridWidth: CGFloat = 0
    @State private var renaming: ProjectKit.LibraryItem?
    @State private var renameText = ""
    @State private var trashing: ProjectKit.LibraryItem?
    @State private var actionError: String?
    @State private var exportRequest: ExportRequest?
    @FocusState private var gridFocused: Bool

    private static let spacing: CGFloat = 16
    private static let padding: CGFloat = 20
    private static let minimumCardWidth: CGFloat = 240
    private static let maximumColumns = 4

    /// A recording to export from the Library, with its saved edit.
    private struct ExportRequest: Identifiable {
        let package: RecordingPackage
        let edit: EditConfig
        var id: URL { package.url }
    }

    init(root: URL) {
        self.root = root
        _model = State(initialValue: LibraryModel(root: root))
    }

    var body: some View {
        content
            .navigationSubtitle(countText)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search Recordings")
            .toolbar { toolbar }
            .task { await model.run() }
            .onReceive(NotificationCenter.default.publisher(for: .recordingFinished)) { _ in
                Task { await model.rescan() }
            }
            .alert("Rename Recording", isPresented: isPresented($renaming), presenting: renaming) { item in
                TextField("Name", text: $renameText)
                Button("Rename") { commitRename(item) }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Move “\(trashing?.meta.name ?? "")” to the Trash?", isPresented: isPresented($trashing),
                presenting: trashing
            ) { item in
                Button("Move to Trash", role: .destructive) { moveToTrash(item) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("MyScreenArt can't undo this, but you can put the recording back from the Trash in Finder.")
            }
            .sheet(item: $exportRequest) { request in
                ExportSheet(package: request.package, edit: request.edit)
            }
            .alert("Something Went Wrong", isPresented: isPresented($actionError), presenting: actionError) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Read the Recordings Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.rescan() } }
            }
        case .loaded:
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "record.circle")
                } description: {
                    Text("Recordings you make will appear here.")
                } actions: {
                    Button("New Recording") { app.router.showRecorder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else if model.visibleItems.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        let columns = columnCount
        let cardWidth = cardWidth(columns: columns)
        return ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: columns),
                spacing: Self.spacing
            ) {
                ForEach(model.visibleItems) { item in
                    RecordingCard(
                        item: item, isSelected: model.selection == item.id, width: cardWidth, loader: loader,
                        open: { open(item) }
                    )
                    .onTapGesture(count: 2) { open(item) }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            model.selection = item.id
                            gridFocused = true
                        }
                    )
                    .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(Self.padding)
            if !model.failures.isEmpty {
                failuresFooter
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            gridWidth = $0
        }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let item = model.selectedItem else { return .ignored }
            open(item)
            return .handled
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: model.moveSelection(by: -1)
            case .right: model.moveSelection(by: 1)
            case .up: model.moveSelection(by: -columns)
            case .down: model.moveSelection(by: columns)
            @unknown default: break
            }
        }
        .onDeleteCommand {
            if let item = model.selectedItem { trashing = item }
        }
    }

    private var failuresFooter: some View {
        Label(
            model.failures.count == 1
                ? "1 recording couldn't be opened." : "\(model.failures.count) recordings couldn't be opened.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(model.failures.map { $0.url.lastPathComponent }.joined(separator: "\n"))
        .padding(.bottom, Self.padding)
    }

    @ViewBuilder
    private func contextMenu(for item: ProjectKit.LibraryItem) -> some View {
        Button("Open") { open(item) }
        Button("Rename…") {
            renameText = item.meta.name
            renaming = item
        }
        Button("Export…") { export(item) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.package.url]) }
        Divider()
        Button("Move to Trash…", role: .destructive) { trashing = item }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.rescan() } }
                .help("Rescan the recordings folder")
            Button("Show Recordings Folder", systemImage: "folder") { NSWorkspace.shared.open(root) }
                .help("Open the recordings folder in Finder")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New Recording", systemImage: "record.circle") { app.router.showRecorder() }
                .labelStyle(.titleAndIcon)
                .help("Start a new recording")
        }
    }

    // MARK: layout

    private var columnCount: Int {
        let available = max(0, gridWidth - 2 * Self.padding)
        let fitting = Int((available + Self.spacing) / (Self.minimumCardWidth + Self.spacing))
        return min(max(fitting, 1), Self.maximumColumns)
    }

    private func cardWidth(columns: Int) -> CGFloat {
        let available = max(0, gridWidth - 2 * Self.padding - Self.spacing * CGFloat(columns - 1))
        return max(Self.minimumCardWidth, available / CGFloat(columns))
    }

    private var countText: String {
        switch model.items.count {
        case 0: "No recordings"
        case 1: "1 recording"
        default: "\(model.items.count) recordings"
        }
    }

    // MARK: actions

    private func open(_ item: ProjectKit.LibraryItem) {
        model.selection = item.id
        app.router.openEditor(for: item.package.url)
    }

    /// Exports with the recording's saved edit (or the initial edit when it has never been edited).
    private func export(_ item: ProjectKit.LibraryItem) {
        do {
            let edit = try item.package.loadEdit() ?? EditConfig.initial(for: item.meta)
            exportRequest = ExportRequest(package: item.package, edit: edit)
        } catch {
            actionError = "Couldn't read the edits of “\(item.meta.name)”: \(error.localizedDescription)"
        }
    }

    private func commitRename(_ item: ProjectKit.LibraryItem) {
        do {
            try model.rename(item, to: renameText)
        } catch {
            actionError = "Couldn't rename “\(item.meta.name)”: \(error.localizedDescription)"
        }
    }

    private func moveToTrash(_ item: ProjectKit.LibraryItem) {
        do {
            try model.moveToTrash(item)
        } catch {
            actionError = "Couldn't move “\(item.meta.name)” to the Trash: \(error.localizedDescription)"
        }
    }

    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
