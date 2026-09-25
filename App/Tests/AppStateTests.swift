import ExportKit
import Foundation
import ProjectKit
import Testing

@testable import MyScreenArt_Dev

@MainActor
struct AppStateTests {
    private func temporaryPackage() throws -> (URL, RecordingPackage, RecordingMeta) {
        let root = FileManager.default.temporaryDirectory.appending(path: "msa-app-test-\(UUID().uuidString)")
        let package = try RecordingPackage.create(in: root)
        let meta = RecordingMeta(
            name: "Test", duration: 2, source: .display(displayID: 1, name: "Test Display"),
            screen: ScreenStreamInfo(
                pixelWidth: 320, pixelHeight: 180, scale: 1, frameRate: 30, codec: "hvc1",
                contentRectPoints: RectPoints(x: 0, y: 0, width: 320, height: 180)))
        try package.saveMeta(meta)
        return (root, package, meta)
    }

    @Test func libraryRefusesTrashForOpenEditor() throws {
        let (root, package, meta) = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(root: root) { $0 == package.url }
        let item = LibraryItem(package: package, meta: meta, streams: [], thumbnailURL: nil)
        #expect(throws: LibraryModel.LibraryActionError.openInEditor) {
            try model.moveToTrash(item)
        }
        #expect(FileManager.default.fileExists(atPath: package.url.path))
    }

    @Test func exportQueueCancelsQueuedJobsAndResumesIdleWaiters() async throws {
        let (root, package, meta) = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = ExportCenter()
        let edit = EditConfig.initial(for: meta)
        let settings = ExportSettings(format: .h264)
        let first = center.start(
            package: package, name: "First", edit: edit, settings: settings,
            destination: root.appending(path: "first.mp4"))
        let second = center.start(
            package: package, name: "Second", edit: edit, settings: settings,
            destination: root.appending(path: "second.mp4"))
        second.cancel()
        await center.waitUntilIdle()
        #expect(second.state == .cancelled)
        if case .failed = first.state {} else { Issue.record("Missing screen should fail preparation") }
        #expect(!center.isExporting)
    }

    @Test func cancelDuringPreparationStopsTheJob() async throws {
        let (root, package, meta) = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = ExportCenter { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        let job = center.start(
            package: package, name: "Preparing", edit: EditConfig.initial(for: meta),
            settings: ExportSettings(format: .h264), destination: root.appending(path: "out.mp4"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(job.state == .preparing)
        let started = ContinuousClock.now
        job.cancel()
        await center.waitUntilIdle()
        #expect(job.state == .cancelled)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
