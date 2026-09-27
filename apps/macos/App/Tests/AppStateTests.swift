import AVFoundation
import AppKit
import ExportKit
import Foundation
import ProjectKit
import RenderKit
import SpeechCore
import SwiftUI
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
