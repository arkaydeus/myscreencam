import Foundation
import ProjectKit
import SpeechCore
import Testing

@testable import MyScreenCam

private actor SingleModelWorker: SpeechWorker {
    private var loaded: WorkerModelRole?
    private(set) var failures: [WorkerFailure] = []

    func send(_ request: WorkerRequest) async throws -> WorkerResponse {
        switch request {
        case .load(let role, _, _):
            loaded = role
            return .loaded(role: role, seconds: 0)
        case .unload, .shutdown:
            loaded = nil
            return .ok
        case .recognise(_, let window, _, _):
            guard loaded == .qwenRecogniser else {
                failures.append(.noModelLoaded)
                return .failure(.noModelLoaded, message: "recogniser replaced")
            }
            return .recognised(
                RecognisedWindow(
                    window: window, text: "word", languageTag: "en", units: [], termination: .complete,
                    processingSeconds: 0))
        case .align(_, let window, _, _):
            guard loaded == .qwenAligner else {
                failures.append(.noModelLoaded)
                return .failure(.noModelLoaded, message: "aligner replaced")
            }
            return .aligned(AlignedWindow(windowIndex: window.index, items: [], processingSeconds: 0))
        case .handshake:
            return .capabilities(WorkerCapabilities(protocolVersion: 1, implementation: [:], supported: true))
        }
    }
}

@MainActor
struct SubtitleAppTests {
    @Test func speechReplyAndErrorRaceOnlyResumeOnce() async {
        let once = OnceFlag()
        let claims = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 { group.addTask { once.claim() } }
            var results: [Bool] = []
            for await claim in group { results.append(claim) }
            return results
        }
        #expect(claims.filter { $0 }.count == 1)
    }

    @Test func retimeWaitsForTheRunningModelsWholeSession() async throws {
        let gate = SpeechWorkGate()
        let worker = SingleModelWorker()
        let window = WorkWindow(index: 0, owned: SampleRange(start: 0, end: 100), read: SampleRange(start: 0, end: 100))
        await gate.acquire()
        _ = try await worker.send(.load(role: .qwenRecogniser, directory: "", runtimeDirectory: ""))
        let retime = Task {
            await gate.acquire()
            defer { gate.release() }
            _ = try await worker.send(.load(role: .qwenAligner, directory: "", runtimeDirectory: ""))
            let response = try await worker.send(.align(audioPath: "", window: window, text: "word", languageTag: "en"))
            _ = try await worker.send(.unload)
            return response
        }
        let recognition = try await worker.send(
            .recognise(audioPath: "", window: window, languageHint: nil, tokenBudget: nil))
        _ = try await worker.send(.unload)
        gate.release()
        let aligned = try await retime.value
        guard case .recognised = recognition else { Issue.record("Running recognition lost its model"); return }
        guard case .aligned = aligned else { Issue.record("Re-time lost its model"); return }
        #expect(await worker.failures.isEmpty)
    }

    @Test func removingCutWordsFromCueText() {
        #expect(EditorModel.removing(["quick"], from: "A quick tour.") == "A tour.")
        #expect(EditorModel.removing(["quick", "tour"], from: "A quick  tour, today") == "A, today")
        #expect(EditorModel.removing(["art"], from: "screen art.") == "screen.")
        // Whole words only.
        #expect(EditorModel.removing(["art"], from: "start") == nil)
        #expect(EditorModel.removing([], from: "text") == nil)
        #expect(EditorModel.removing(["你", "好"], from: "你好世界") == "世界")
        #expect(EditorModel.removing(["世", "界"], from: "你好世界") == "你好")
    }

    @Test func cueDragAcrossCutUsesEditedTimeline() {
        let timeline = EditTimeline(segments: [Segment(start: 0, end: 2), Segment(start: 5, end: 8)])
        let editedStart = timeline.editedTimeSnapping(forSource: 1.5)
        #expect(CueDragTime.sourceTime(editedStart: editedStart, editedDelta: 1, timeline: timeline) == 5.5)
        #expect(CueDragTime.sourceTime(editedStart: editedStart, editedDelta: -0.5, timeline: timeline) == 1)
    }

    @Test func cueHitTestOrderIsAStableSelectedFirstPartition() {
        let cues = (0..<5).map { SubtitleCue(start: Double($0), end: Double($0 + 1), text: "\($0)") }
        let ids = cues.map(\.id)
        #expect(
            CueHitTest.ordered(cues, selected: [ids[1], ids[3]]).map(\.id) == [ids[1], ids[3], ids[0], ids[2], ids[4]])
        #expect(CueHitTest.ordered(cues, selected: Set(ids)).map(\.id) == ids)
        #expect(CueHitTest.ordered(cues, selected: []).map(\.id) == ids)
        #expect(CueHitTest.ordered([], selected: Set(ids)).isEmpty)
    }

    @Test func timeFieldParsing() {
        #expect(TimeFormat.parse("1:02.50") == 62.5)
        #expect(TimeFormat.parse("1:00:01") == 3601)
        #expect(TimeFormat.parse("3.25") == 3.25)
        #expect(TimeFormat.parse("1.5:00") == nil)
        #expect(TimeFormat.parse("abc") == nil)
    }

    @Test func downloadTextShowsSizesSpeedAndTimeLeft() {
        let text = DownloadText.describe(
            DownloadProgress(completedBytes: 300_000_000, totalBytes: 600_000_000, bytesPerSecond: 10_000_000))
        #expect(text.contains("300 MB of 600 MB"))
        #expect(text.contains("10 MB/s"))
        #expect(text.contains("30s") || text.contains("30 s"))
        let early = DownloadText.describe(DownloadProgress(completedBytes: 1, totalBytes: 10, bytesPerSecond: nil))
        #expect(early.contains("estimating"))
    }

    @Test func speechSettingsPersistAndDefaultToOff() {
        let defaults = UserDefaults(suiteName: "speech-settings-\(UUID().uuidString)")!
        let settings = SpeechSettings(defaults: defaults)
        #expect(settings.engine == nil)
        #expect(settings.autoTranscribe)
        settings.engine = .qwen
        settings.language = "ja"
        let reloaded = SpeechSettings(defaults: defaults)
        #expect(reloaded.engine == .qwen)
        #expect(reloaded.languageHint(for: .qwen) == "ja")
        // Parakeet doesn't know Japanese: automatic instead.
        #expect(reloaded.languageHint(for: .parakeet) == nil)
    }
}
