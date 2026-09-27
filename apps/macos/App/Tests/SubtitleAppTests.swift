import Foundation
import SpeechCore
import Testing

@testable import MyScreenArt_Dev

@MainActor
struct SubtitleAppTests {
    @Test func removingCutWordsFromCueText() {
        #expect(EditorModel.removing(["quick"], from: "A quick tour.") == "A tour.")
        #expect(EditorModel.removing(["quick", "tour"], from: "A quick  tour, today") == "A, today")
        #expect(EditorModel.removing(["art"], from: "screen art.") == "screen.")
        // Whole words only.
        #expect(EditorModel.removing(["art"], from: "start") == nil)
        #expect(EditorModel.removing([], from: "text") == nil)
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
