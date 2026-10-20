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

    /// Sends real AppKit mouse events through the timeline, with its current model snapshot.
    private struct CueTimeline {
        let model: EditorModel
        let window: NSWindow
        let view: TimelineNSView

        init(model: EditorModel) {
            self.model = model
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1092, height: 300), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view = TimelineNSView(model: model)
            window.contentView = view
        }

        func send(
            _ type: NSEvent.EventType, at time: Double = 0, flags: NSEvent.ModifierFlags = [],
            gutter: Bool = false, offset: CGFloat = 0
        ) throws {
            view.update(data: TimelineData(model: model), zoom: 1, isPlaying: false, waveformCount: 0)
            let rows = TimelineMetrics.rows(for: model.recordedStreams, subtitles: true)
            let y =
                TimelineMetrics.rulerHeight
                + rows.prefix(while: { $0 != .subtitles }).reduce(CGFloat.zero) {
                    $0 + $1.height + TimelineMetrics.rowGap
                } + TimelineMetrics.Row.subtitles.height / 2
            let pps =
                (view.bounds.width - TimelineMetrics.gutter - TimelineMetrics.trailingPad) / model.timeline.duration
            let point = CGPoint(x: gutter ? 10 : TimelineMetrics.gutter + time * pps + offset, y: y)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: Issue.record("Unsupported timeline test event")
            }
        }

        func close() {
            view.teardown()
            window.close()
        }
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

    @Test func cueSelectionRangesTogglesSelectsAllAndDeletesTogether() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cues = (0..<4).map { SubtitleCue(start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4, text: "\($0)") }
        model.update("Seed") { $0.subtitles.cues = cues }
        let ids = cues.map(\.id)

        model.selectCue(ids[1])
        #expect(model.selectedCue?.id == ids[1])
        model.selectCue(ids[3], .range)
        #expect(model.selectedCueIDs == Set(ids[1...3]))
        #expect(model.selectedCue == nil)
        model.selectCue(ids[2], .toggle)
        #expect(model.selectedCueIDs == [ids[1], ids[3]])
        model.selectCue(ids[0], .toggle)
        #expect(model.selectedCueIDs == [ids[0], ids[1], ids[3]])

        let undo = UndoManager()
        model.undoManager = undo
        model.deleteSelection()
        #expect(model.edit.subtitles.cues.map(\.id) == [ids[2]])
        #expect(model.selection == nil)
        undo.undo()
        #expect(model.edit.subtitles.cues.map(\.id) == ids)

        model.selectAllCues()
        #expect(model.selectedCueIDs == Set(ids))
        model.deleteSelection()
        #expect(model.edit.subtitles.cues.isEmpty)
        await model.close()
    }

    @Test func deletingSomeCuesPreservesTheSurvivingSelection() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cues = (0..<3).map { SubtitleCue(start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4, text: "\($0)") }
        model.update("Seed") { $0.subtitles.cues = cues }
        model.selectCue(cues[0].id)
        model.selectCue(cues[1].id, .toggle)

        model.deleteCues([cues[0].id])
        #expect(model.selection == .cues([cues[1].id]))
        #expect(model.selectedCue?.id == cues[1].id)
        #expect(model.edit.subtitles.cues.map(\.id) == [cues[1].id, cues[2].id])
        // The same pruning must run for edits from sources other than the delete action.
        model.selectCue(cues[2].id, .toggle)
        model.update("Remove Cue") { $0.subtitles.cues.removeAll { $0.id == cues[1].id } }
        #expect(model.selection == .cues([cues[2].id]))
        model.deleteCues([cues[2].id])
        #expect(model.selection == nil)
        await model.close()
    }

    @Test func cueReselectionPreservesWordsAndChangingSelectionClearsThem() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SubtitleCue(start: 0.2, end: 0.6, text: "First")
        let second = SubtitleCue(start: 0.8, end: 1.2, text: "Second")
        model.update("Seed") { $0.subtitles.cues = [first, second] }
        model.selectCue(first.id)
        model.selectedWordIDs = ["word-0", "word-1"]
        model.selectCue(first.id)
        #expect(model.selectedWordIDs == ["word-0", "word-1"])
        model.selectCue(second.id)
        #expect(model.selectedWordIDs.isEmpty)
        model.selectedWordIDs = ["word-2"]
        model.selectCue(first.id, .toggle)
        #expect(model.selectedCueIDs == [first.id, second.id])
        #expect(model.selectedWordIDs.isEmpty)
        model.selectCue(first.id)
        model.selectedWordIDs = ["word-0"]
        model.selectCue(second.id, .range)
        #expect(model.selectedWordIDs.isEmpty)
        model.selectCue(first.id)
        model.selectedWordIDs = ["word-0"]
        model.selectAllCues()
        #expect(model.selectedWordIDs.isEmpty)
        await model.close()
    }

    @Test func timelineCueModifierClicksAndGutterSelectAll() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cues = (0..<4).map {
            SubtitleCue(start: Double($0) * 0.4 + 0.1, end: Double($0) * 0.4 + 0.4, text: "\($0)")
        }
        model.update("Seed") { $0.subtitles.cues = cues }
        let timeline = CueTimeline(model: model)
        defer { timeline.close() }
        func click(_ time: Double, _ flags: NSEvent.ModifierFlags = []) throws {
            try timeline.send(.leftMouseDown, at: time, flags: flags)
            // Modifier gestures must never start a move or resize.
            if !flags.isEmpty { try timeline.send(.leftMouseDragged, at: time + 0.05, flags: flags) }
            try timeline.send(.leftMouseUp, at: time, flags: flags)
        }
        try click(0.65)
        #expect(model.selectedCueIDs == [cues[1].id])
        try click(1.45, .command)
        #expect(model.selectedCueIDs == [cues[1].id, cues[3].id])
        try click(0.65, .command)
        #expect(model.selectedCueIDs == [cues[3].id])
        try click(0.65, .shift)
        #expect(model.selectedCueIDs == Set(cues[1...3].map(\.id)))
        try click(0.25, [.command, .shift])
        #expect(model.selectedCueIDs == Set(cues.map(\.id)))
        #expect(model.edit.subtitles.cues == cues)

        model.selectCue(cues[2].id)
        model.selectedWordIDs = ["word"]
        model.inspectorTab = .zoom
        try timeline.send(.leftMouseDown, gutter: true)
        try timeline.send(.leftMouseUp, gutter: true)
        #expect(model.selectedCueIDs == Set(cues.map(\.id)))
        #expect(model.inspectorTab == .subtitles)
        #expect(model.selectedWordIDs.isEmpty)
        await model.close()
    }

    @Test func timelinePlainCueClickCollapsesBeforeDraggingOnlyThatCue() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cues = [
            SubtitleCue(start: 0.2, end: 0.6, text: "First"), SubtitleCue(start: 0.8, end: 1.2, text: "Second"),
        ]
        model.update("Seed") { $0.subtitles.cues = cues }
        model.selectAllCues()
        let undo = UndoManager()
        model.undoManager = undo
        let timeline = CueTimeline(model: model)
        defer { timeline.close() }
        try timeline.send(.leftMouseDown, at: 1)
        #expect(model.selectedCueIDs == [cues[1].id])
        try timeline.send(.leftMouseDragged, at: 1.1)
        try timeline.send(.leftMouseDragged, at: 1.2)
        try timeline.send(.leftMouseUp, at: 1.2)
        #expect(model.edit.subtitles.cues[0] == cues[0])
        #expect(abs(model.edit.subtitles.cues[1].start - 1) < 1e-9)
        #expect(abs(model.edit.subtitles.cues[1].end - 1.4) < 1e-9)
        undo.undo()
        #expect(model.edit.subtitles.cues == cues)
        #expect(!undo.canUndo)
        await model.close()
    }

    @Test func timelineCueHitTestingKeepsStablePriorityAtSharedEdgesAndOverlaps() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cues = [
            SubtitleCue(start: 0.2, end: 0.8, text: "First"),
            SubtitleCue(start: 0.8, end: 1.4, text: "Second"),
            SubtitleCue(start: 0.9, end: 1.6, text: "Third"),
        ]
        model.update("Seed") { $0.subtitles.cues = cues }
        let timeline = CueTimeline(model: model)
        defer { timeline.close() }
        // Both sides of the junction are within its four-point edge slop.
        for offset in [CGFloat(-3), 0, 3] {
            model.selectAllCues()
            try timeline.send(.leftMouseDown, at: 0.8, offset: offset)
            #expect(model.selectedCueIDs == [cues[0].id])
            try timeline.send(.leftMouseUp, at: 0.8, offset: offset)
            model.selectCue(cues[1].id)
            model.selectCue(cues[2].id, .toggle)
            try timeline.send(.leftMouseDown, at: 0.8, offset: offset)
            #expect(model.selectedCueIDs == [cues[1].id])
            try timeline.send(.leftMouseUp, at: 0.8, offset: offset)
        }
        model.selectAllCues()
        try timeline.send(.leftMouseDown, at: 1.1)
        #expect(model.selectedCueIDs == [cues[1].id])
        try timeline.send(.leftMouseUp, at: 1.1)
        model.selectCue(cues[0].id)
        model.selectCue(cues[2].id, .toggle)
        try timeline.send(.leftMouseDown, at: 1.1)
        #expect(model.selectedCueIDs == [cues[2].id])
        try timeline.send(.leftMouseUp, at: 1.1)
        await model.close()
    }

    @Test func cueRowClicksUseModifiersAndOnlyPlainClicksFocus() async throws {
        let (root, model) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cues = (0..<4).map {
            SubtitleCue(start: Double($0) * 0.4 + 0.1, end: Double($0) * 0.4 + 0.4, text: "\($0)")
        }
        model.update("Seed") { $0.subtitles.cues = cues }
        CueRowClick.handle(cues[1].id, flags: [], isEditing: false, model: model)
        #expect(model.selectedCueIDs == [cues[1].id])
        #expect(abs(model.currentTime - 0.55) < 1e-9)
        model.player.play()
        CueRowClick.handle(cues[3].id, flags: .command, isEditing: false, model: model)
        #expect(model.selectedCueIDs == [cues[1].id, cues[3].id])
        CueRowClick.handle(cues[3].id, flags: .command, isEditing: false, model: model)
        #expect(model.selectedCueIDs == [cues[1].id])
        // Removing the anchor leaves no range origin until the next click establishes one.
        CueRowClick.handle(cues[3].id, flags: .shift, isEditing: false, model: model)
        #expect(model.selectedCueIDs == [cues[3].id])
        CueRowClick.handle(cues[1].id, flags: .shift, isEditing: false, model: model)
        #expect(model.selectedCueIDs == Set(cues[1...3].map(\.id)))
        #expect(model.player.rate != 0)
        #expect(abs(model.currentTime - 0.55) < 1e-9)
        CueRowClick.handle(cues[2].id, flags: [], isEditing: false, model: model)
        #expect(model.selectedCueIDs == [cues[2].id])
        #expect(model.player.rate == 0)
        #expect(abs(model.currentTime - 0.95) < 1e-9)
        model.seek(to: 1.5)
        model.selectedWordIDs = ["word"]
        CueRowClick.handle(cues[2].id, flags: [], isEditing: true, model: model)
        #expect(model.currentTime == 1.5)
        #expect(model.selectedWordIDs == ["word"])
        // Modifiers still work on the row that currently contains the cue editor.
        CueRowClick.handle(cues[2].id, flags: .command, isEditing: true, model: model)
        #expect(model.selection == nil)
        #expect(model.selectedWordIDs.isEmpty)
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
