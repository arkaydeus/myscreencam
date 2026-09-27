import Foundation
import MyScreenCamCore
import Observation
import ProjectKit

/// The Library window's state: the scanned recordings, the search filter and the selection.
///
/// Scans run off the main actor. It rescans when the recordings folder changes (FSEvents via
/// `RecordingLibrary.changes()`), when the Recorder posts `recordingFinished`, and on Refresh. Overlapping
/// requests are coalesced into one follow-up scan.
@MainActor
@Observable
final class LibraryModel {
    enum LibraryActionError: LocalizedError {
        case openInEditor

        var errorDescription: String? { "Close this recording's editor before moving it to the Trash." }
    }
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let library: RecordingLibrary
    @ObservationIgnored private let isOpenInEditor: @MainActor (URL) -> Bool
    private(set) var phase: Phase = .loading
    private(set) var items: [ProjectKit.LibraryItem] = []
    private(set) var failures: [LibraryFailure] = []
    var searchText = ""
    var selection: URL?

    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var rescanRequested = false

    init(root: URL, isOpenInEditor: @escaping @MainActor (URL) -> Bool) {
        library = RecordingLibrary(root: root)
        self.isOpenInEditor = isOpenInEditor
    }

    /// Items matching the search text (by name), newest first.
    var visibleItems: [ProjectKit.LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.meta.name.localizedStandardContains(query) }
    }

    var selectedItem: ProjectKit.LibraryItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    /// Scans now, then rescans on every folder change until the calling task is cancelled (the window closed).
    func run() async {
        await rescan()
        for await _ in library.changes() {
            await rescan()
        }
    }

    /// Rescans the folder; if a scan is already running, one more runs after it.
    func rescan() async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            rescanRequested = false
            do {
                let scan = try await Self.scan(library)
                apply(scan)
            } catch {
                Log.app.error("Library scan failed: \(error, privacy: .public)")
                if items.isEmpty { phase = .failed(error.localizedDescription) }
            }
        } while rescanRequested
    }

    @concurrent
    private static func scan(_ library: RecordingLibrary) async throws -> LibraryScan {
        try await library.scan()
    }

    private func apply(_ scan: LibraryScan) {
        if scan.items != items { items = scan.items }
        // A package without meta.json is still being written by the Recorder (it posts `recordingFinished`
        // when done), so it isn't reported as broken.
        let broken = scan.failures.filter {
            FileManager.default.fileExists(atPath: $0.url.appending(path: PackageLayout.meta).path)
        }
        if broken != failures { failures = broken }
        if let selection, !scan.items.contains(where: { $0.id == selection }) { self.selection = nil }
        phase = .loaded
    }

    /// Sets the recording's display name. The folder isn't renamed, so the watcher doesn't fire: the item is
    /// updated in place.
    func rename(_ item: ProjectKit.LibraryItem, to name: String) throws {
        let updated = try library.rename(item, to: name)
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = updated }
    }

    /// Moves the recording to the Trash (restorable from Finder; there's no in-app undo).
    func moveToTrash(_ item: ProjectKit.LibraryItem) throws {
        guard !isOpenInEditor(item.package.url) else { throw LibraryActionError.openInEditor }
        try library.delete(item.package)
        items.removeAll { $0.id == item.id }
        if selection == item.id { selection = nil }
    }

    /// Moves the selection by `offset` items within the visible (filtered) list.
    func moveSelection(by offset: Int) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }
        guard let selection, let index = visible.firstIndex(where: { $0.id == selection }) else {
            self.selection = visible.first?.id
            return
        }
        let next = min(max(index + offset, 0), visible.count - 1)
        self.selection = visible[next].id
    }
}
