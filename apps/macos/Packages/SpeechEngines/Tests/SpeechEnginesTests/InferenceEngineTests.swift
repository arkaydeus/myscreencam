import FluidAudio
import Foundation
import ProjectKit
import SpeechCore
import Testing

@testable import SpeechEngines

struct InferenceEngineTests {
    @Test func rejectsUnverifiedModelPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "msc-engine-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = InferenceEngine(modelsRoot: root)
        let response = await engine.handle(
            .load(role: .parakeet, directory: root.appending(path: "unverified").path, runtimeDirectory: ""))
        guard case .failure(let failure, _) = response else { Issue.record("Expected path rejection"); return }
        #expect(failure == .pathNotAllowed)
    }

    @Test func recognitionRequiresLoadedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "msc-engine-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try RecordingPackage.create(in: root)
        let cache = package.url(PackageLayout.transcriptionCacheDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let audio = cache.appending(path: "samples.f32")
        try Data(repeating: 0, count: 400).write(to: audio)
        let engine = InferenceEngine(modelsRoot: root.appending(path: "Models"))
        let window = WorkWindow(index: 0, owned: SampleRange(start: 0, end: 100), read: SampleRange(start: 0, end: 100))
        let response = await engine.handle(
            .recognise(audioPath: audio.path, window: window, languageHint: nil, tokenBudget: nil))
        guard case .failure(let failure, _) = response else { Issue.record("Expected no model failure"); return }
        #expect(failure == .noModelLoaded)
    }

    @Test func parakeetTokenOffsetsFollowUtf8TextAndWindowOffset() {
        let tokens = [
            TokenTiming(token: " naï", tokenId: 1, startTime: 0.1, endTime: 0.2, confidence: 0.9),
            TokenTiming(token: "ve", tokenId: 2, startTime: 0.2, endTime: 0.3, confidence: 0.8),
            TokenTiming(token: " world", tokenId: 3, startTime: 0.4, endTime: 0.5, confidence: 0.7),
        ]
        let (text, units, warnings) = ParakeetAdapter.units(
            from: tokens, expectedText: "naïve world", windowStart: 16_000)
        #expect(text == "naïve world")
        #expect(warnings.isEmpty)
        #expect(units.count == 2)
        #expect(units.map(\.utf8Start) == [0, 7])
        #expect(units.map(\.utf8End) == [6, 12])
        #expect(units.map(\.startSample) == [17_600, 22_400])
    }
}
