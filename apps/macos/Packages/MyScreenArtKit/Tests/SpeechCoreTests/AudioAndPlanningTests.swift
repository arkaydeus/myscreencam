import AVFoundation
import Foundation
import Testing

@testable import ProjectKit
@testable import SpeechCore

/// A temporary directory removed on deinit.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "sc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

enum AudioFixtures {
    /// Writes `seconds` of audio: silence, then a 440 Hz tone from `onset` seconds (all channels, the second one
    /// inverted when `inverted`).
    static func writeTone(
        to url: URL, seconds: Double, onset: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1,
        inverted: Bool = false, aac: Bool = false
    ) throws {
        let processing = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let settings: [String: Any] =
            aac
            ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ]
            : processing.settings
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: frames)!
        buffer.frameLength = frames
        let start = Int(onset * sampleRate)
        for c in 0..<Int(channels) {
            let data = buffer.floatChannelData![c]
            for i in 0..<Int(frames) {
                let v: Float = i >= start ? 0.5 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate)) : 0
                data[i] = (inverted && c == 1) ? -v : v
            }
        }
        try file.write(from: buffer)
    }

    /// Index of the first sample whose magnitude exceeds `threshold`.
    static func onset(_ samples: [Float], threshold: Float = 0.05) -> Int? {
        samples.firstIndex { abs($0) > threshold }
    }

    static func meta(duration: Double, micOffset: Double) -> RecordingMeta {
        RecordingMeta(
            name: "Speech", createdAt: Date(timeIntervalSince1970: 1_790_000_000), duration: duration,
            source: .display(displayID: 1, name: "Display"),
            screen: ScreenStreamInfo(
                pixelWidth: 640, pixelHeight: 360, scale: 1, frameRate: 30, codec: "avc1",
                contentRectPoints: RectPoints(x: 0, y: 0, width: 640, height: 360)),
            microphone: AudioDeviceInfo(deviceID: "mic", name: "Mic"),
            streams: [.microphone: StreamTiming(startOffset: micOffset)])
    }
}

struct AudioPreparationTests {
    @Test func resamplesTo16kWithoutShiftingTime() async throws {
        let dir = try TempDir()
        let source = dir.url.appending(path: "tone.caf")
        try AudioFixtures.writeTone(to: source, seconds: 3, onset: 1.0)
        let out = dir.url.appending(path: "out.f32")
        let decoded = try await AudioPreparation.decode(file: source, to: out, durationHint: 3, progress: nil)
        #expect(abs(decoded.samples - 48_000) <= 16)
        #expect(decoded.firstTime == 0)
        let samples = try PreparedSamples(url: out).read(SampleRange(start: 0, end: 48_000))
        let onset = try #require(AudioFixtures.onset(samples))
        // 1.0 s = sample 16 000; the resampler's filter may smear the edge by a few samples.
        #expect(abs(onset - 16_000) <= 8)
    }

    @Test func phaseInvertedStereoKeepsTheSignal() {
        var interleaved: [Float] = []
        for i in 0..<8_000 {
            let v = 0.5 * sin(2 * Float.pi * 440 * Float(i) / 16_000)
            interleaved += [v, -v]
        }
        let mono = interleaved.withUnsafeBufferPointer {
            AudioPreparation.downmix($0.baseAddress!, frames: 8_000, channels: 2)
        }
        let energy = mono.reduce(0) { $0 + $1 * $1 } / Float(mono.count)
        #expect(energy > 0.1)
        // Ordinary stereo still averages.
        let normal: [Float] = [0.2, 0.4, 0.6, 0.8]
        let averaged = normal.withUnsafeBufferPointer {
            AudioPreparation.downmix($0.baseAddress!, frames: 2, channels: 2)
        }
        #expect(averaged.map { ($0 * 10).rounded() / 10 } == [0.3, 0.7])
    }

    @Test func preparedPackageAudioCarriesTheStreamOffsetAndIsReused() async throws {
        let dir = try TempDir()
        let package = try RecordingPackage.create(in: dir.url)
        let meta = AudioFixtures.meta(duration: 4, micOffset: 0.25)
        try package.saveMeta(meta)
        try AudioFixtures.writeTone(to: package.url(for: .microphone), seconds: 3.5, onset: 1.0, aac: true)
        let cache = package.url(PackageLayout.transcriptionCacheDirectory)
        let prepared = try await AudioPreparation.prepare(
            package: package, meta: meta, stream: .microphone, directory: cache)
        #expect(prepared.originSample == 4_000)  // 0.25 s × 16 kHz
        let samples = try PreparedSamples(url: cache.appending(path: prepared.samplesFileName))
        let onset = try #require(AudioFixtures.onset(samples.read(SampleRange(start: 0, end: samples.count))))
        // AAC priming must be trimmed by the reader: the tone still starts at 1.0 s in the file…
        #expect(abs(onset - 16_000) <= 160)
        // …which is 1.25 s on the session timeline.
        #expect(abs(prepared.sourceTime(sample: Int64(onset)).seconds - 1.25) <= 0.01)
        let again = try await AudioPreparation.prepare(
            package: package, meta: meta, stream: .microphone, directory: cache)
        #expect(again == prepared)
    }

    @Test func sourceRangesNeverExtendIntoPadding() {
        let prepared = PreparedAudio(
            identity: "k", sourceMediaID: "m", stream: .microphone, sourceChannelCount: 1, sourceSampleRate: 48_000,
            originSample: 1_600, sampleCount: 16_000, filledGaps: 0, recipe: "r", samplesFileName: "k.f32")
        let range = prepared.sourceRange(SampleRange(start: 8_000, end: 40_000))
        #expect(range.startSeconds == 0.6)
        #expect(range.endSeconds == 1.1)
    }
}

struct WindowPlannerTests {
    /// 20 ms energies: loud everywhere except a 300 ms pause centred on each given second.
    func energies(seconds: Double, quietAt: [Double]) -> [Float] {
        var e = [Float](repeating: 0.3, count: Int(seconds * 50))
        for q in quietAt { for i in (Int(q * 50) - 7)...(Int(q * 50) + 7) { e[i] = 0.001 } }
        return e
    }

    @Test func aBriefDipBetweenSyllablesLosesToARealPause() {
        var e = [Float](repeating: 0.3, count: 40 * 50)
        e[22 * 50] = 0  // one silent frame inside speech
        for i in (26 * 50 - 7)...(26 * 50 + 7) { e[i] = 0.02 }  // a real (quiet, not silent) pause
        let windows = WindowPlanner.plan(range: SampleRange(start: 0, end: 40 * 16_000), energies: e, policy: .qwen)
        #expect(abs(Double(windows[0].owned.end) / 16_000 - 26) < 0.1)
    }

    @Test func cutsAtTheQuietestFrameWithinBounds() {
        let sr = Int64(PreparedAudio.sampleRate)
        let total = 70 * sr
        let windows = WindowPlanner.plan(
            range: SampleRange(start: 0, end: total), energies: energies(seconds: 70, quietAt: [23, 51]),
            policy: .qwen)
        #expect(windows.count == 3)
        #expect(abs(Double(windows[0].owned.end) / Double(sr) - 23) < 0.1)  // inside the 300 ms pause
        #expect(abs(Double(windows[1].owned.end) / Double(sr) - 51) < 0.1)
        // Contiguous, non-overlapping ownership covering everything.
        #expect(windows.first?.owned.start == 0)
        #expect(windows.last?.owned.end == total)
        for (a, b) in zip(windows, windows.dropFirst()) { #expect(a.owned.end == b.owned.start) }
        #expect(windows.allSatisfy { $0.read == $0.owned })
    }

    @Test func mergesAShortTailAndAddsContextForParakeet() {
        let sr = Int64(PreparedAudio.sampleRate)
        let total = 125 * sr
        let windows = WindowPlanner.plan(
            range: SampleRange(start: 0, end: total), energies: energies(seconds: 125, quietAt: [119]),
            policy: .parakeet)
        #expect(windows.count == 1)
        #expect(windows[0].owned == SampleRange(start: 0, end: total))

        let longer = WindowPlanner.plan(
            range: SampleRange(start: 0, end: 200 * sr), energies: energies(seconds: 200, quietAt: [100]),
            policy: .parakeet)
        #expect(longer.count == 2)
        #expect(longer[1].read.start == longer[1].owned.start - sr / 2)
        #expect(longer[0].read.end == longer[0].owned.end + sr / 2)
    }

    @Test func neverExceedsTheHardCap() {
        let sr = Int64(PreparedAudio.sampleRate)
        let windows = WindowPlanner.plan(
            range: SampleRange(start: 0, end: 600 * sr), energies: [Float](repeating: 0.2, count: 600 * 50),
            policy: .qwen)
        #expect(windows.allSatisfy { Double($0.owned.count) / Double(sr) <= WindowPolicy.qwen.hardCap })
    }
}

struct AlignmentMapperTests {
    @Test func tokenisesLikeTheAligner() {
        let tokens = AlignmentMapper.tokens("Hello, world! It's 42 你好", chineseMode: false)
        #expect(tokens.map(\.text) == ["Hello", "world", "It's", "42", "你", "好"])
        let text = "Hello, world! It's 42 你好"
        let bytes = Array(text.utf8)
        for token in tokens {
            #expect(
                String(bytes: bytes[token.utf8Start..<token.utf8End], encoding: .utf8)?.contains(token.text) == true)
        }
        // Space mode drops inner punctuation without splitting; Chinese mode splits on it.
        #expect(AlignmentMapper.tokens("a-b c", chineseMode: false).map(\.text) == ["ab", "c"])
        #expect(AlignmentMapper.tokens("a-b c", chineseMode: true).map(\.text) == ["a", "b", "c"])
    }

    @Test func mapsItemsMonotonicallyWithRepeatedWords() {
        let items = ["the", "cat", "the", "hat"].enumerated().map { i, t in
            AlignedItem(text: t, startSample: Int64(i * 100), endSample: Int64(i * 100 + 50))
        }
        let result = AlignmentMapper.map(items: items, rawText: "The cat, the hat.", chineseMode: false)
        // "The" ≠ "the": the first item is a mismatch, but later words aren't attached to the wrong occurrence.
        #expect(result.timings.map { $0?.start } == [nil, 100, 200, 300])
        #expect(result.mismatched == 2)
    }

    @Test func exactMatchHasNoMismatches() {
        let items = ["Hello", "world"].enumerated().map { i, t in
            AlignedItem(text: t, startSample: Int64(i * 10), endSample: Int64(i * 10 + 5))
        }
        let result = AlignmentMapper.map(items: items, rawText: "Hello world.", chineseMode: false)
        #expect(result.mismatched == 0)
        #expect(result.timings.compactMap { $0 }.count == 2)
    }
}

struct TranscriptAssemblerTests {
    let prepared = PreparedAudio(
        identity: "audio", sourceMediaID: "media", stream: .microphone, sourceChannelCount: 1, sourceSampleRate: 48_000,
        originSample: 4_000, sampleCount: 160_000, filledGaps: 0, recipe: "r", samplesFileName: "audio.f32")

    func input(_ windows: [RecognisedWindow], engine: SpeechEngine = .parakeet, alignments: [Int: AlignedWindow] = [:])
        -> TranscriptAssembler.Input
    {
        TranscriptAssembler.Input(
            revisionID: "rev-1", parentRevisionID: nil, prepared: prepared, sourceDuration: 11, engine: engine,
            recogniser: ModelIdentity(
                catalogueID: "m", repository: "r", revision: "x", manifestDigest: "d", quantisation: "q"),
            aligner: nil, implementation: ["a": "1"],
            options: TranscriptionOptions(
                engine: engine.rawValue, audioSource: .microphone, languageHint: nil, windowSeconds: 1,
                maxWindowSeconds: 1, tokenBudgetPerWindow: nil, audioRecipe: "r"),
            windows: windows, alignments: alignments)
    }

    @Test func aWordHeardByBothWindowsAtASeamIsKeptOnce() throws {
        // Window 0 owns 0–5 s and reads 0.5 s past it; window 1 owns 5–10 s. Both heard "today" at ~4.98/5.0 s.
        let w0 = WorkWindow(
            index: 0, owned: SampleRange(start: 0, end: 80_000), read: SampleRange(start: 0, end: 88_000))
        let w1 = WorkWindow(
            index: 1, owned: SampleRange(start: 80_000, end: 160_000), read: SampleRange(start: 72_000, end: 160_000))
        let a = RecognisedWindow(
            window: w0, text: "part one today", languageTag: "en",
            units: [
                RecognisedUnit(
                    utf8Start: 0, utf8End: 4, kind: .word, startSample: 16_000, endSample: 20_000, method: .tdt),
                RecognisedUnit(
                    utf8Start: 5, utf8End: 8, kind: .word, startSample: 24_000, endSample: 28_000, method: .tdt),
                RecognisedUnit(
                    utf8Start: 9, utf8End: 14, kind: .word, startSample: 79_700, endSample: 84_000, method: .tdt),
            ], termination: .complete, processingSeconds: 0)
        let b = RecognisedWindow(
            window: w1, text: "Today we go today", languageTag: "en",
            units: [
                RecognisedUnit(
                    utf8Start: 0, utf8End: 5, kind: .word, startSample: 80_000, endSample: 86_000, method: .tdt),
                RecognisedUnit(
                    utf8Start: 6, utf8End: 8, kind: .word, startSample: 88_000, endSample: 90_000, method: .tdt),
                RecognisedUnit(
                    utf8Start: 9, utf8End: 11, kind: .word, startSample: 92_000, endSample: 94_000, method: .tdt),
                // The same word much later is a genuine repeat and stays.
                RecognisedUnit(
                    utf8Start: 12, utf8End: 17, kind: .word, startSample: 150_000, endSample: 155_000, method: .tdt),
            ], termination: .complete, processingSeconds: 0)
        let revision = try TranscriptAssembler.assemble(input([a, b]))
        #expect(revision.segments.map(\.rawText) == ["part one", "Today we go today"])
    }

    @Test func aWordOnlyTheNextWindowHeardBeforeTheCutIsKept() throws {
        // The cut (5 s) fell just after "part" started; only window 1 recognised it (from its context audio).
        let w0 = WorkWindow(
            index: 0, owned: SampleRange(start: 0, end: 80_000), read: SampleRange(start: 0, end: 88_000))
        let w1 = WorkWindow(
            index: 1, owned: SampleRange(start: 80_000, end: 160_000), read: SampleRange(start: 72_000, end: 160_000))
        let a = RecognisedWindow(
            window: w0, text: "on screen", languageTag: "en",
            units: [
                RecognisedUnit(
                    utf8Start: 0, utf8End: 2, kind: .word, startSample: 70_000, endSample: 72_000, method: .tdt),
                RecognisedUnit(
                    utf8Start: 3, utf8End: 9, kind: .word, startSample: 73_000, endSample: 76_000, method: .tdt),
            ], termination: .complete, processingSeconds: 0)
        let b = RecognisedWindow(
            window: w1, text: "screen part two", languageTag: "en",
            units: [
                // A cut-off copy of A's last word at the very start of B's audio: not a new word.
                RecognisedUnit(
                    utf8Start: 0, utf8End: 6, kind: .word, startSample: 72_100, endSample: 76_500, method: .tdt),
                RecognisedUnit(
                    utf8Start: 7, utf8End: 11, kind: .word, startSample: 78_400, endSample: 81_000, method: .tdt),
                RecognisedUnit(
                    utf8Start: 12, utf8End: 15, kind: .word, startSample: 82_000, endSample: 84_000, method: .tdt),
            ], termination: .complete, processingSeconds: 0)
        let revision = try TranscriptAssembler.assemble(input([a, b]))
        #expect(revision.segments.map(\.rawText) == ["on screen", "part two"])
    }

    @Test func parakeetUnitsAreOwnedByStartAndOffsetOnce() throws {
        let window = WorkWindow(
            index: 0, owned: SampleRange(start: 0, end: 80_000), read: SampleRange(start: 0, end: 88_000))
        let text = "hello there world"
        let units = [
            RecognisedUnit(utf8Start: 0, utf8End: 5, kind: .word, startSample: 16_000, endSample: 24_000, method: .tdt),
            RecognisedUnit(
                utf8Start: 6, utf8End: 11, kind: .word, startSample: 32_000, endSample: 40_000, method: .tdt),
            // Starts beyond the owned span: belongs to the next window.
            RecognisedUnit(
                utf8Start: 12, utf8End: 17, kind: .word, startSample: 80_500, endSample: 86_000, method: .tdt),
        ]
        let revision = try TranscriptAssembler.assemble(
            input([
                RecognisedWindow(
                    window: window, text: text, languageTag: "en", units: units, termination: .complete,
                    processingSeconds: 0)
            ]))
        let segment = try #require(revision.segments.first)
        #expect(segment.rawText == "hello there")
        #expect(segment.units.count == 2)
        // (4 000 + 16 000) / 16 000 = 1.25 s.
        #expect(segment.units[0].timing?.sourceRange.startSeconds == 1.25)
        #expect(revision.status == .complete)
        #expect(revision.sourceCoverage.first?.startSeconds == 0.25)
    }

    @Test func truncatedWindowsMakeThePartialStatus() throws {
        let window = WorkWindow(
            index: 0, owned: SampleRange(start: 0, end: 16_000), read: SampleRange(start: 0, end: 16_000))
        let revision = try TranscriptAssembler.assemble(
            input(
                [
                    RecognisedWindow(
                        window: window, text: "some text", languageTag: "en", units: [],
                        termination: .tokenBudgetExhausted,
                        generatedTokens: 256, tokenBudget: 256, processingSeconds: 0)
                ], engine: .qwen))
        #expect(revision.status == .partial)
        #expect(revision.sourceCoverage.isEmpty)
        #expect(revision.segments.first?.rangeMeaning == .processingWindow)
        #expect(revision.segments.first?.units.allSatisfy { $0.timing == nil } == true)
    }

    @Test func alignedWindowsGetForcedAlignmentTiming() throws {
        let window = WorkWindow(
            index: 0, owned: SampleRange(start: 16_000, end: 48_000), read: SampleRange(start: 16_000, end: 48_000))
        let aligned = AlignedWindow(
            windowIndex: 0,
            items: [
                AlignedItem(text: "Hello", startSample: 1_600, endSample: 8_000),
                AlignedItem(text: "world", startSample: 9_600, endSample: 16_000),
            ], processingSeconds: 0)
        let revision = try TranscriptAssembler.assemble(
            input(
                [
                    RecognisedWindow(
                        window: window, text: "Hello world.", languageTag: "en", units: [], termination: .complete,
                        processingSeconds: 0)
                ],
                engine: .qwen, alignments: [0: aligned]))
        let segment = try #require(revision.segments.first)
        #expect(segment.rangeMeaning == .speech)
        #expect(segment.units.map { $0.timing?.method } == [.forcedAlignment, .forcedAlignment])
        // (4 000 + 16 000 + 1 600) / 16 000 = 1.35 s.
        #expect(segment.units[0].timing?.sourceRange.startSeconds == 1.35)
    }
}
