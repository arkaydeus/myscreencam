import AVFoundation
import AppKit
import ExportKit
import Foundation
import ProjectKit
import RenderKit
import SpeechCore
import SwiftUI
import Testing

@testable import MyScreenCam

@MainActor
struct AppStateTests {
    private func temporaryPackage() throws -> (URL, RecordingPackage, RecordingMeta) {
        let root = FileManager.default.temporaryDirectory.appending(path: "msc-app-test-\(UUID().uuidString)")
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

    /// Deliver real AppKit mouse events through the preview's gesture routing.
    private func cropDrag(
        _ view: PreviewNSView, model: EditorModel, from: NormPoint, to: NormPoint, undo: UndoManager,
        fullFrameState: Bool = false
    ) throws {
        func sync() {
            var state = PreviewOverlayState(model: model)
            if fullFrameState && model.edit.crop == nil { state.crop = .full }
            view.state = state
        }
        func event(_ type: NSEvent.EventType, at source: NormPoint) throws -> NSEvent {
            let layout = CanvasLayout.make(
                sourceSize: model.renderer.layout.sourceSize, background: model.edit.background,
                sizing: model.renderer.options.sizing)
            let geometry = PreviewGeometry(layout: layout)
            let point = geometry.viewPoint(
                fromCanvas: geometry.canvasPoint(fromSource: source), viewSize: view.bounds.size)
            return try #require(
                NSEvent.mouseEvent(
                    with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1))
        }
        sync()
        let original = model.edit
        let couldUndo = undo.canUndo
        view.mouseDown(with: try event(.leftMouseDown, at: from))
        // Multiple updates must all belong to one undo step. A click sends only down/up events.
        if from != to {
            view.mouseDragged(
                with: try event(.leftMouseDragged, at: NormPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)))
            sync()
            view.mouseDragged(with: try event(.leftMouseDragged, at: to))
            sync()
        }
        #expect(undo.canUndo == couldUndo)
        // Empty explicit AppKit groups themselves count as actions, so group only a changed gesture.
        let changed = model.edit != original
        if changed { undo.beginUndoGrouping() }
        view.mouseUp(with: try event(.leftMouseUp, at: to))
        if changed { undo.endUndoGrouping() }
    }

    @Test func cropPreviewDrawMoveResetAndUndo() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.update("Seed") { $0.background.enabled = false }
        model.isEditingCrop = true
        let view = PreviewNSView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        defer { view.teardown() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let start = NormPoint(x: 0.2, y: 0.2)
        let end = NormPoint(x: 0.7, y: 0.7)
        // Clicking, including a sub-threshold drag, leaves nil and adds no undo action.
        try cropDrag(view, model: model, from: start, to: start, undo: undo)
        #expect(model.edit.crop == nil && !undo.canUndo)
        try cropDrag(view, model: model, from: start, to: NormPoint(x: 0.201, y: 0.201), undo: undo)
        #expect(model.edit.crop == nil && !undo.canUndo)
        // Both nil and an explicitly full-frame overlay must route interior drags to drawing.
        for full in [false, true] {
            try cropDrag(view, model: model, from: start, to: end, undo: undo, fullFrameState: full)
            let drawn = try #require(model.edit.crop)
            #expect(abs(drawn.x - 0.2) < 1e-9 && abs(drawn.y - 0.2) < 1e-9)
            #expect(abs(drawn.w - 0.5) < 1e-9 && abs(drawn.h - 0.5) < 1e-9)
            undo.undo()
            #expect(model.edit.crop == nil && !undo.canUndo)
        }
        try cropDrag(view, model: model, from: start, to: end, undo: undo)
        let drawn = model.edit.crop
        undo.removeAllActions()
        try cropDrag(view, model: model, from: .center, to: .center, undo: undo)
        #expect(model.edit.crop == drawn && !undo.canUndo)
        try cropDrag(view, model: model, from: .center, to: NormPoint(x: 0.6, y: 0.6), undo: undo)
        let moved = try #require(model.edit.crop)
        #expect(abs(moved.x - 0.3) < 1e-9 && abs(moved.y - 0.3) < 1e-9)
        #expect(moved.w == drawn?.w && moved.h == drawn?.h)
        undo.undo()
        #expect(model.edit.crop == drawn && !undo.canUndo)
        try cropDrag(view, model: model, from: .center, to: NormPoint(x: 1.4, y: -0.3), undo: undo)
        let bounded = try #require(model.edit.crop)
        #expect(abs(bounded.x - (1 - bounded.w)) < 1e-9 && bounded.y == 0)
        undo.undo()
        #expect(model.edit.crop == drawn && !undo.canUndo)
        undo.beginUndoGrouping()
        model.setCrop(nil, "Reset Crop")
        undo.endUndoGrouping()
        #expect(model.edit.crop == nil)
        undo.undo()
        #expect(model.edit.crop == drawn)
        undo.redo()
        #expect(model.edit.crop == nil)
        undo.removeAllActions()
        try cropDrag(view, model: model, from: start, to: end, undo: undo)
        #expect(model.edit.crop != nil)
        undo.undo()
        #expect(model.edit.crop == nil && !undo.canUndo)
        await model.close()
    }

    @Test func cropPreviewResizesEveryHandleInOneUndoStep() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.update("Seed") { $0.background.enabled = false }
        model.isEditingCrop = true
        let view = PreviewNSView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        defer { view.teardown() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let original = NormRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        for (x, y) in [
            (0.25, 0.25), (0.5, 0.25), (0.75, 0.25), (0.75, 0.5),
            (0.75, 0.75), (0.5, 0.75), (0.25, 0.75), (0.25, 0.5),
        ] {
            undo.beginUndoGrouping()
            model.setCrop(original)
            undo.endUndoGrouping()
            undo.removeAllActions()
            let dx = x == 0.5 ? 0 : (x < 0.5 ? -0.05 : 0.05)
            let dy = y == 0.5 ? 0 : (y < 0.5 ? -0.05 : 0.05)
            try cropDrag(
                view, model: model, from: NormPoint(x: x, y: y), to: NormPoint(x: x + dx, y: y + dy), undo: undo)
            let resized = try #require(model.edit.crop)
            #expect(abs(resized.x - (x < 0.5 ? 0.2 : 0.25)) < 1e-9)
            #expect(abs(resized.y - (y < 0.5 ? 0.2 : 0.25)) < 1e-9)
            #expect(abs(resized.w - (0.5 + abs(dx))) < 1e-9)
            #expect(abs(resized.h - (0.5 + abs(dy))) < 1e-9)
            undo.undo()
            #expect(model.edit.crop == original && !undo.canUndo)
        }
        await model.close()
    }

    @Test func cropModeShowsSourceAndExcludesTargetPicking() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.update("Seed") {
            $0.crop = NormRect(x: 0.5, y: 0, w: 0.5, h: 1)
            $0.zoom.enabled = true
            $0.webcam.enabled = true
            $0.subtitles.enabled = true
        }
        let original = model.edit
        model.isPickingZoomTarget = true
        model.toggleCropEditing()
        #expect(model.isEditingCrop && !model.isPickingZoomTarget)
        #expect(model.previewEdit.crop == nil)
        #expect(
            !model.previewEdit.zoom.enabled && !model.previewEdit.webcam.enabled && !model.previewEdit.subtitles.enabled
        )
        #expect(model.edit == original)
        model.isPickingZoomTarget = true
        #expect(!model.isEditingCrop && model.isPickingZoomTarget)
        #expect(model.previewEdit == original)
        model.toggleCropEditing()
        model.inspectorTab = .background
        #expect(!model.isEditingCrop && model.previewEdit == original)
        await model.close()
    }

    @Test func cropRelativeZoomControlsMarkerAndPivotAgree() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyframe = ZoomKeyframe(time: 0, scale: 2, target: NormPoint(x: 0.2, y: 0.8), hold: 2, instant: true)
        model.update("Seed") {
            $0.crop = NormRect(x: 0.5, y: 0, w: 0.5, h: 1)
            $0.zoom.keyframes = [keyframe]
        }
        model.selection = .keyframes([keyframe.id])
        let x = model.zoomTargetBinding(\.x, keyframe: keyframe)
        let y = model.zoomTargetBinding(\.y, keyframe: keyframe)
        #expect(x.wrappedValue == 0 && y.wrappedValue == 0.8)
        let layout = CanvasLayout.make(
            sourceSize: model.renderer.layout.sourceSize, crop: model.edit.crop, background: model.edit.background,
            sizing: .scale(1))
        let geometry = PreviewGeometry(layout: layout)
        let state = ZoomEvaluator(settings: model.edit.zoom, crop: layout.normalizedCrop).state(at: 1)
        let pivot = NormPoint(x: x.wrappedValue, y: y.wrappedValue)
        #expect(pivot == state.pivot)
        let marker = geometry.canvasPoint(
            fromSource: ZoomEvaluator.targetInSource(pivot, crop: layout.normalizedCrop), zoom: state)
        #expect(abs(marker.x - layout.contentRect.minX) < 1e-9)
        let view = PreviewNSView(model: model)
        view.frame = CGRect(origin: .zero, size: layout.canvasSize)
        view.state = PreviewOverlayState(model: model)
        defer { view.teardown() }
        let markerLayer = try #require(
            view.layer?.sublayers?.flatMap { $0.sublayers ?? [] }.first { $0.name == "zoomTarget" } as? CAShapeLayer)
        let markerBounds = try #require(markerLayer.path).boundingBoxOfPath
        #expect(!markerLayer.isHidden)
        #expect(abs(markerBounds.midX - marker.x) < 1e-9 && abs(markerBounds.midY - marker.y) < 1e-9)
        x.wrappedValue = 0.4
        #expect(abs(model.selectedKeyframe!.target.x - 0.7) < 1e-9)
        #expect(y.wrappedValue == 0.8)
        model.setZoomTarget(NormPoint(x: 0.1, y: 1.2))
        #expect(model.selectedKeyframe?.target == NormPoint(x: 0.5, y: 1))
        #expect(x.wrappedValue == 0 && y.wrappedValue == 1)
        await model.close()
    }

    private func timedRevision() -> TranscriptRevision {
        let entries: [(String, Double, Double)] = [("one", 0, 0.4), ("two", 0.5, 0.9), ("three", 1, 1.4)]
        var text = ""
        var units: [TranscriptUnit] = []
        for (index, entry) in entries.enumerated() {
            if index > 0 { text += " " }
            let start = text.utf8.count
            text += entry.0
            let range = MediaRange(
                start: MediaTime(seconds: entry.1, timescale: 16_000),
                end: MediaTime(seconds: entry.2, timescale: 16_000))
            units.append(
                TranscriptUnit(
                    id: "word-\(index)", utf8Start: start, utf8End: text.utf8.count, kind: .word,
                    timing: UnitTiming(sourceRange: range, method: .tdt, validation: .valid)))
        }
        let range = MediaRange(
            start: MediaTime(seconds: 0, timescale: 16_000),
            end: MediaTime(seconds: 1.4, timescale: 16_000))
        return TranscriptRevision(
            id: "timed", parentRevisionID: nil, sourceMediaID: "media", audioIdentityHash: "audio",
            recogniser: ModelIdentity(
                catalogueID: "test", repository: "test/model", revision: "1", manifestDigest: "digest",
                quantisation: "none"), aligner: nil, implementationFingerprint: "test", implementation: [:],
            optionsFingerprint: "test",
            options: TranscriptionOptions(
                engine: "parakeet", audioSource: .microphone, languageHint: nil, windowSeconds: 120,
                maxWindowSeconds: 150, tokenBudgetPerWindow: nil, audioRecipe: "test"), sourceCoverage: [range],
            segments: [
                TranscriptSegment(
                    id: "speech", sourceRange: range, rangeMeaning: .speech, rawText: text, languageTag: "en",
                    units: units)
            ], status: .complete, warnings: [])
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

    @Test func failedSubtitleSidecarMarksExportFailed() throws {
        let (root, package, meta) = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecar = root.appending(path: "movie.srt")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let center = ExportCenter()
        let settings = ExportSettings(format: .h264)
        let movie = root.appending(path: "movie.mp4")
        let job = center.start(
            package: package, name: "Movie", edit: EditConfig.initial(for: meta), settings: settings,
            destination: movie, subtitleSidecar: "1\n00:00:00,000 --> 00:00:01,000\nHello\n")
        let result = ExportResult(
            url: movie, fileSize: 100, duration: 1, dimensions: CGSize(width: 320, height: 180), frameCount: 30,
            wallTime: 1, encoder: .hardware, settings: settings)
        center.finish(job, with: .succeeded(result))
        guard case .failed(let message) = job.state else {
            Issue.record("Expected the missing sidecar to fail the export")
            return
        }
        #expect(message.contains("Movie saved"))
        #expect(message.contains("subtitles"))
    }

    @Test func transcriptionQueueFailsMissingModelsAndCancelsQueuedJobs() async throws {
        let (root, package, _) = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "transcription-queue-\(UUID().uuidString)")!
        let models = SpeechModels(store: ModelStore(root: root.appending(path: "Models")))
        let center = TranscriptionCenter(settings: SpeechSettings(defaults: defaults), models: models)

        let first = try #require(center.transcribe(package.url, engine: .parakeet))
        #expect(first.phase == .queued)
        await center.waitUntilIdle()
        guard case .failed = first.phase else { Issue.record("Expected missing models to fail"); return }

        let second = try #require(center.transcribe(package.url, engine: .parakeet))
        center.cancel(package.url)
        #expect(second.phase == .cancelled)
    }

    @Test func registeringAnEditorRefreshesAnEditSavedWhileItWasLoading() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var committed = model.edit
        committed.background.padding = 0.22
        try model.package.saveEdit(committed)

        let sessions = EditorSessions()
        await sessions.register(model)
        #expect(model.edit.background.padding == 0.22)
        model.update("User Edit") { $0.background.padding = 0.27 }
        await sessions.close(model)
        #expect(try model.package.loadEdit()?.background.padding == 0.27)
    }

    @Test func resetEditsRebuildsFromDefaultsEvenWithSavedOrCorruptEdit() async throws {
        let (root, package, meta) = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = EditConfig.initial(for: meta)
        saved.zoom.enabled = false
        try package.saveEdit(saved)
        var defaults = ProjectDefaults()
        defaults.zoomTiming.scale = 2.3
        defaults.subtitleStyle.uppercase = true

        let existing = try await EditorLoader.loadProject(at: package.url, defaults: defaults, resetEdit: false)
        #expect(!existing.edit.zoom.enabled)
        let reset = try await EditorLoader.loadProject(at: package.url, defaults: defaults, resetEdit: true)
        #expect(reset.edit.zoom.enabled)
        #expect(reset.edit.zoom.defaults.scale == 2.3)
        #expect(reset.edit.subtitles.style.uppercase)

        try Data("invalid json".utf8).write(to: package.url("edit.json"))
        do {
            _ = try await EditorLoader.loadProject(at: package.url, defaults: defaults, resetEdit: false)
            Issue.record("Expected a corrupt edit error")
        } catch is DecodingError {
            Issue.record("The decoding error must be mapped to corruptEdit")
        } catch let error as EditorLoadError {
            guard case .corruptEdit = error else { Issue.record("Expected corruptEdit, got \(error)"); return }
        }
        let recovered = try await EditorLoader.loadProject(at: package.url, defaults: defaults, resetEdit: true)
        #expect(recovered.edit.zoom.defaults.scale == 2.3)
        #expect(recovered.edit.subtitles.style.uppercase)
    }

    @Test func firstLibraryExportPersistsDefaultsForLaterUses() throws {
        let (root, package, meta) = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        var defaults = ProjectDefaults()
        defaults.zoomTiming.scale = 2.1
        defaults.subtitleStyle.uppercase = true
        defaults.subtitlePlacement.anchor = .top
        let first = try package.loadOrCreateEdit(meta: meta, defaults: defaults)
        #expect(try package.loadEdit() == first)

        defaults.zoomTiming.scale = 1.2
        defaults.subtitleStyle.uppercase = false
        defaults.subtitlePlacement.anchor = .bottom
        let later = try package.loadOrCreateEdit(meta: meta, defaults: defaults)
        #expect(later == first)
        #expect(later.zoom.defaults.scale == 2.1)
        #expect(later.subtitles.style.uppercase)
        #expect(later.subtitles.placement.anchor == .top)
    }

    @Test func firstTranscriptionUsesProjectDefaults() async throws {
        let (root, package, meta) = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        try InputEventLog.encodeLine(InputEvent(t: 1, kind: .down, x: 0.5, y: 0.5, button: 0))
            .write(to: package.url(PackageLayout.events))
        var defaults = ProjectDefaults()
        defaults.autoZoom = true
        defaults.zoomTiming.scale = 2.4
        defaults.subtitleStyle.uppercase = true
        defaults.subtitlePlacement.anchor = .top
        let center = TranscriptionCenter(projectDefaults: { defaults })
        #expect(try await center.commit(timedRevision(), to: package, meta: meta) == .adopted)
        let edit = try #require(try package.loadEdit())
        #expect(edit.zoom.defaults.scale == 2.4)
        #expect(edit.zoom.keyframes.count == 1)
        #expect(edit.zoom.keyframes.first?.scale == 2.4)
        #expect(edit.subtitles.style.uppercase)
        #expect(edit.subtitles.placement.anchor == .top)
        #expect(!edit.subtitles.cues.isEmpty)
    }

    @Test func groupMoveClampsTogetherAndSelectedEditsUndoTogether() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ZoomKeyframe(time: 0.4)
        let second = ZoomKeyframe(time: 1.2)
        model.update("Seed") { $0.zoom.keyframes = [first, second] }
        let ids: Set<ZoomKeyframe.ID> = [first.id, second.id]
        let original = [first.id: first.time, second.id: second.time]
        model.moveKeyframes(original, by: -10)
        #expect(abs(model.edit.zoom.keyframes[0].time) < 1e-9)
        #expect(abs(model.edit.zoom.keyframes[1].time - 0.8) < 1e-9)
        model.moveKeyframes(original, by: 10)
        #expect(abs(model.edit.zoom.keyframes[0].time - 1.2) < 1e-9)
        #expect(abs(model.edit.zoom.keyframes[1].time - 2) < 1e-9)

        let undo = UndoManager()
        model.undoManager = undo
        model.updateKeyframes(ids, "Change Zooms") { $0.scale = 2.5 }
        #expect(model.edit.zoom.keyframes.allSatisfy { $0.scale == 2.5 })
        undo.undo()
        #expect(model.edit.zoom.keyframes.allSatisfy { $0.scale == first.scale })
        #expect(!undo.canUndo)
        await model.close()
    }

    @Test func deletingZoomsPrunesSelectionAndAnchorFallsBackToEarliest() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ZoomKeyframe(time: 0.3)
        let second = ZoomKeyframe(time: 1.1)
        model.update("Seed") { $0.zoom.keyframes = [first, second] }
        model.selection = .keyframes([first.id, second.id])
        model.keyframeAnchor = second.id
        #expect(model.selectedKeyframe?.id == second.id)
        model.update("Remove Second") { $0.zoom.keyframes.removeAll { $0.id == second.id } }
        #expect(model.selectedKeyframeIDs == [first.id])
        #expect(model.selectedKeyframe?.id == first.id)
        model.deleteKeyframes([first.id])
        #expect(model.selection == nil)
        await model.close()
    }

    @Test func plainClickKeepsZoomGroupForDragAndCollapsesWithoutDrag() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ZoomKeyframe(time: 0.3)
        let second = ZoomKeyframe(time: 1.1)
        model.update("Seed") { $0.zoom.keyframes = [first, second] }
        model.selection = .keyframes([first.id, second.id])
        #expect(KeyframeClick.begin(second.id, modifier: .replace, model: model))
        #expect(model.selectedKeyframeIDs == [first.id, second.id])
        KeyframeClick.end(second.id, moving: true, model: model)
        #expect(model.selectedKeyframeIDs == [first.id, second.id])
        #expect(KeyframeClick.begin(second.id, modifier: .replace, model: model))
        KeyframeClick.end(second.id, moving: false, model: model)
        #expect(model.selectedKeyframeIDs == [second.id])
        await model.close()
    }

    @Test func transcriptCommitsThroughOpenEditorAsAdoptedThenCandidate() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = EditorSessions()
        await sessions.register(model)
        let center = TranscriptionCenter()
        center.editors = sessions
        func revision(_ id: String, text: String) -> TranscriptRevision {
            let range = MediaRange(
                start: MediaTime(seconds: 0.2, timescale: 16_000),
                end: MediaTime(seconds: 0.8, timescale: 16_000))
            return TranscriptRevision(
                id: id, parentRevisionID: nil, sourceMediaID: "media", audioIdentityHash: "audio",
                recogniser: ModelIdentity(
                    catalogueID: "test", repository: "test/model", revision: "1", manifestDigest: "digest",
                    quantisation: "none"),
                aligner: nil, implementationFingerprint: "test", implementation: [:], optionsFingerprint: "test",
                options: TranscriptionOptions(
                    engine: "parakeet", audioSource: .microphone, languageHint: nil, windowSeconds: 120,
                    maxWindowSeconds: 150, tokenBudgetPerWindow: nil, audioRecipe: "test"),
                sourceCoverage: [range],
                segments: [
                    TranscriptSegment(
                        id: "segment-\(id)", sourceRange: range, rangeMeaning: .processingWindow, rawText: text,
                        languageTag: "en", units: [])
                ], status: .complete, warnings: [])
        }
        #expect(
            try await center.commit(revision("first", text: "Hello"), to: model.package, meta: model.meta) == .adopted)
        let cue = try #require(model.edit.subtitles.cues.first)
        model.setCueText(cue.id, "User correction")
        #expect(
            try await center.commit(revision("second", text: "Hello again"), to: model.package, meta: model.meta)
                == .candidate)
        await model.flush()
        #expect(model.edit.subtitles.candidateRevisionID == "second")
        #expect(try model.package.loadEdit()?.subtitles.cues.first?.text == "User correction")
        await sessions.close(model)
    }

    @Test func qwenAdmissionReflectsEditorPlayback() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = EditorSessions()
        await sessions.register(model)
        let center = TranscriptionCenter()
        center.editors = sessions
        let job = TranscriptionCenter.Job(packageURL: model.package.url, engine: .qwen)
        model.clock.isPlaying = true
        #expect(center.holdReason(for: job) == "Paused during playback")
        model.clock.isPlaying = false
        #expect(center.holdReason(for: job) == nil)
        await sessions.close(model)
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

    @Test func webcamFillSwitchingAndColourChangesCoalesceUndo() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let controls = WebcamBackgroundControls(source: model)
        #expect(controls.fillKinds == [.clear, .solid, .gradient, .image])
        #expect(controls.fillKind.wrappedValue == .clear)

        undo.beginUndoGrouping()
        controls.fillKind.wrappedValue = .solid
        // Close the first event's group: later colour updates must coalesce even across event boundaries.
        undo.endUndoGrouping()
        #expect(controls.fillKind.wrappedValue == .solid)
        let fill = model.webcamBackgroundBinding(\.fill, "Webcam Background Fill")
        fill.wrappedValue = .solid(RGBAColor(r: 0.8, g: 0.2, b: 0.1))
        fill.wrappedValue = .solid(RGBAColor(r: 0.2, g: 0.8, b: 0.1))
        undo.undo()
        #expect(model.edit.webcam.background.fill == nil)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(model.edit.webcam.background.fill == .solid(RGBAColor(r: 0.2, g: 0.8, b: 0.1)))

        undo.beginUndoGrouping()
        controls.fillKind.wrappedValue = .gradient
        #expect(controls.fillKind.wrappedValue == .gradient)
        #expect(model.edit.webcam.background.fill == BackgroundSettings().fill)
        controls.fillKind.wrappedValue = .clear
        #expect(model.edit.webcam.background.fill == nil)
        undo.endUndoGrouping()
        await model.close()
    }

    @Test func webcamSlidersGroupEachDragAndKeepSeparateFieldsUndoable() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let original = model.webcamBackground
        let blur = model.webcamBackgroundBinding(\.blurAmount, "Webcam Background Blur")
        let softness = model.webcamBackgroundBinding(\.edgeSoftness, "Webcam Edge Softness")
        undo.beginUndoGrouping()
        model.editingChanged(true)
        blur.wrappedValue = 0.6
        blur.wrappedValue = 0.9
        model.editingChanged(false)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        model.editingChanged(true)
        softness.wrappedValue = 0.5
        softness.wrappedValue = 0.8
        model.editingChanged(false)
        undo.endUndoGrouping()
        undo.undo()
        #expect(model.webcamBackground.blurAmount == 0.9)
        #expect(model.webcamBackground.edgeSoftness == original.edgeSoftness)
        undo.undo()
        #expect(model.webcamBackground == original)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(model.webcamBackground.blurAmount == 0.9)
        await model.close()
    }

    @Test func cueWidthDragIsOneUndoStepAndCanBecomeTheDefault() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cue = SubtitleCue(start: 0, end: 1, text: "Hello there")
        model.update("Add") { $0.subtitles.cues = [cue] }
        let undo = UndoManager()
        model.undoManager = undo

        model.beginContinuousChange()
        model.setCueWidth(cue.id, 0.6)
        model.setCueWidth(cue.id, 0.45)
        model.endContinuousChange()
        #expect(model.edit.subtitles.cues.first?.maxWidth == 0.45)
        undo.undo()
        #expect(model.edit.subtitles.cues.map(\.id) == [cue.id])
        #expect(model.edit.subtitles.cues.first?.maxWidth == nil)

        model.setCueWidth(cue.id, 0.45)
        model.useCueWidthAsDefault(cue.id)
        #expect(model.edit.subtitles.style.maxWidth == 0.45)
        #expect(model.edit.subtitles.cues.first?.maxWidth == nil)
        await model.close()
    }

    @Test func shortCueWidthDragStartsAtWrapConstraint() {
        let gesture = CueWidthDrag(startX: 100, initialWidth: 0.8, edge: 1)
        #expect(gesture.width(at: 100, videoWidth: 500) == 0.8)
        #expect(abs(gesture.width(at: 102, videoWidth: 500) - 0.804) < 1e-9)
        let left = CueWidthDrag(startX: 100, initialWidth: 0.8, edge: -1)
        #expect(abs(left.width(at: 98, videoWidth: 500) - 0.804) < 1e-9)
    }

    @Test func movedCueCutKeepsRemainingShiftedWordTimings() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = timedRevision()
        _ = model.receiveTranscript(revision)
        let id = try #require(model.edit.subtitles.cues.first?.id)
        model.moveCue(id, toStart: 0.5)
        model.selectedWordIDs = ["word-1"]
        model.cutSelectedWords()
        let cue = try #require(model.edit.subtitles.cues.first)
        #expect(cue.text == "one three")
        #expect(cue.words.map(\.text) == ["one", "three"])
        #expect(cue.words.map(\.start) == [0.5, 1.5])
        #expect(cue.unitIDs == ["word-0", "word-2"])
        await model.close()
    }

    @Test func lateWordBackfillSurvivesUndoAndAutosave() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = timedRevision()
        try model.package.saveTranscript(revision)
        _ = model.receiveTranscript(revision)
        model.applyDerived { $0.subtitles.cues[0].words = [] }
        model.transcripts.removeValue(forKey: revision.id)
        let undo = UndoManager()
        model.undoManager = undo
        model.update("Padding") { $0.background.padding = 0.15 }
        model.loadTranscripts()
        for _ in 0..<10_000 where model.edit.subtitles.cues[0].words.isEmpty { await Task.yield() }
        #expect(model.edit.subtitles.cues[0].words.count == 3)
        undo.undo()
        #expect(model.edit.background.padding != 0.15)
        #expect(model.edit.subtitles.cues[0].words.count == 3)
        await model.flush()
        #expect(try model.package.loadEdit()?.subtitles.cues[0].words.count == 3)
        #expect(!model.hasUnsavedChanges)
        model.loadTranscripts()
        #expect(!model.hasUnsavedChanges)
        await model.close()
    }

    @Test func steppedSliderKeyboardAndDragKeepSeparateUndoSteps() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager()
        model.undoManager = undo
        let original = model.edit.background.padding
        let stepped = SteppedSliderValue.binding(
            model.binding(\.background.padding, "Padding"), in: EditLimits.backgroundPadding, step: 0.05)

        // A keyboard change arrives without an editing gesture.
        stepped.wrappedValue = 0.25
        #expect(abs(model.edit.background.padding - 0.25) < 1e-10)
        undo.undo()
        #expect(model.edit.background.padding == original)

        // A drag sends several values between Slider's editing callbacks.
        model.editingChanged(true)
        stepped.wrappedValue = 0.11
        stepped.wrappedValue = 0.16
        stepped.wrappedValue = 0.17
        #expect(abs(model.edit.background.padding - 0.15) < 1e-10)
        model.editingChanged(false)
        undo.undo()
        #expect(model.edit.background.padding == original)
        #expect(!undo.canUndo)
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

    @Test func editorSheetsInstallNavyWindowChromeUnderLightAppearance() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = previousAppearance }

        func checkSheet<Content: View>(_ content: Content) {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: content)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            #expect(window.appearance?.name == .darkAqua)
            #expect(window.backgroundColor == AppTheme.windowBackground)
            #expect(window.titlebarAppearsTransparent)
        }

        checkSheet(PresetNameSheet(model: model))
        checkSheet(ConflictSheet(model: model))
        await model.close()
    }

    @Test func appThemeIgnoresTheRemovedAppearancePreference() {
        let previousAppearance = NSApp.appearance
        let previousPreference = UserDefaults.standard.object(forKey: "shell.appearance")
        defer {
            NSApp.appearance = previousAppearance
            if let previousPreference {
                UserDefaults.standard.set(previousPreference, forKey: "shell.appearance")
            } else {
                UserDefaults.standard.removeObject(forKey: "shell.appearance")
            }
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set("light", forKey: "shell.appearance")

        AppTheme.applyAppearance()

        #expect(NSApp.appearance?.name == .darkAqua)
    }
}
