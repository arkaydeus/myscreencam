import AVFoundation
import AppKit
import ExportKit
import Foundation
import ProjectKit
import RenderKit
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

    private func editorFixture() async throws -> (URL, EditorModel) {
        let (root, package, originalMeta) = try temporaryPackage()
        let screen = package.url(for: .screen)
        let writer = try AVAssetWriter(outputURL: screen, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 180,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        for index in 0..<2 {
            guard input.isReadyForMoreMediaData else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let frame = try #require(buffer)
            guard adaptor.append(frame, withPresentationTime: CMTime(seconds: Double(index), preferredTimescale: 600))
            else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        var meta = originalMeta
        meta.streams = [.screen: StreamTiming(startOffset: 0)]
        meta.screen.codec = "avc1"
        try package.saveMeta(meta)
        let edit = EditConfig.initial(for: meta)
        let project = RenderProject(package: package, meta: meta, edit: edit, events: [], cursorIndex: CursorIndex())
        let renderer = try await ProjectRenderer(
            project: project, options: .preview(maxSize: CGSize(width: 640, height: 360)))
        return (root, EditorModel(project: project, renderer: renderer))
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

    @Test func editorGroupsGestureUndoAndFlushesLatestEdit() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager()
        model.undoManager = undo
        let original = model.edit.background.padding

        model.beginContinuousChange()
        model.update("Padding") { $0.background.padding = 0.1 }
        model.update("Padding") { $0.background.padding = 0.2 }
        model.endContinuousChange()
        #expect(model.edit.background.padding == 0.2)
        undo.undo()
        #expect(model.edit.background.padding == original)

        model.update("Padding", coalesce: "padding") { $0.background.padding = 0.1 }
        model.update("Padding", coalesce: "padding") { $0.background.padding = 0.2 }
        undo.undo()
        #expect(model.edit.background.padding == original)

        model.update("Padding") { $0.background.padding = 0.15 }
        await model.flush()
        #expect(try model.package.loadEdit() == model.edit)
        #expect(!model.hasUnsavedChanges)
        await model.close()
    }

    @Test func handledEditorShortcutIsConsumedByMonitorRoute() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        let hooks = EditorWindowHooks.HooksView(model: model, holder: WindowHolder())
        window.contentView = hooks
        window.makeKeyAndOrderFront(nil)
        defer {
            hooks.teardown()
            window.close()
        }
        let space = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49))
        #expect(EditorWindowHooks.HooksView.route(space, through: hooks) == nil)
        #expect(EditorWindowHooks.HooksView.route(space, through: nil) === space)
        await model.close()
    }
}
