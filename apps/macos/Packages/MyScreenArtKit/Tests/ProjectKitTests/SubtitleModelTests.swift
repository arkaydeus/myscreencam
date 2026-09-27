import Foundation
import Testing

@testable import ProjectKit

/// Builders for transcript fixtures (16 kHz timescale, like real recognition output).
enum TranscriptFixtures {
    static func t(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds, timescale: 16_000) }

    static func range(_ a: Double, _ b: Double) -> MediaRange { MediaRange(start: t(a), end: t(b)) }

    /// A segment of timed words `[(text, start, end)]` joined by single spaces; `punctuation` characters at the
    /// end of a word become separate punctuation units (like Parakeet) unless `inline`.
    static func segment(
        _ id: String, _ words: [(String, Double, Double)], method: TimingMethod = .tdt, inlinePunctuation: Bool = false
    ) -> TranscriptSegment {
        var raw = ""
        var units: [TranscriptUnit] = []
        for (i, word) in words.enumerated() {
            if i > 0 { raw += " " }
            var text = word.0
            var trailing = ""
            if !inlinePunctuation, let last = text.last, ".,?!".contains(last) {
                trailing = String(last)
                text.removeLast()
            }
            let start = raw.utf8.count
            raw += text
            units.append(
                TranscriptUnit(
                    id: "\(id)-u\(units.count)", utf8Start: start, utf8End: raw.utf8.count, kind: .word,
                    timing: UnitTiming(sourceRange: range(word.1, word.2), method: method, validation: .valid)))
            if !trailing.isEmpty {
                let p = raw.utf8.count
                raw += trailing
                units.append(
                    TranscriptUnit(
                        id: "\(id)-u\(units.count)", utf8Start: p, utf8End: raw.utf8.count, kind: .punctuation,
                        timing: UnitTiming(sourceRange: range(word.2, word.2), method: method, validation: .valid)))
            }
        }
        let start = words.first?.1 ?? 0
        let end = words.last?.2 ?? 0
        return TranscriptSegment(
            id: id, sourceRange: range(start, end), rangeMeaning: .speech, rawText: raw, languageTag: "en", units: units
        )
    }

    static func revision(_ segments: [TranscriptSegment], id: String = "rev1") -> TranscriptRevision {
        TranscriptRevision(
            id: id, parentRevisionID: nil, sourceMediaID: "media", audioIdentityHash: "audio",
            recogniser: ModelIdentity(
                catalogueID: "m", repository: "r", revision: "x", manifestDigest: "d", quantisation: "q"),
            aligner: nil, implementationFingerprint: "i", implementation: [:], optionsFingerprint: "o",
            options: TranscriptionOptions(
                engine: "parakeet", audioSource: .microphone, languageHint: nil, windowSeconds: 120,
                maxWindowSeconds: 150,
                tokenBudgetPerWindow: nil, audioRecipe: "r"),
            sourceCoverage: [range(0, 60)], segments: segments, status: .complete, warnings: [],
            createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }
}

struct TranscriptModelTests {
    @Test func mediaTimeEncodesValueAsDecimalString() throws {
        let time = MediaTime(value: 9_007_199_254_740_993, timescale: 16_000)
        let data = try JSONEncoder().encode(time)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"9007199254740993\""))
        #expect(try JSONDecoder().decode(MediaTime.self, from: data) == time)
    }

    @Test func mediaTimeRejectsMalformedValues() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MediaTime.self, from: Data(#"{"value":"1.5","timescale":16000}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MediaTime.self, from: Data(#"{"value":"10","timescale":0}"#.utf8))
        }
    }

    @Test func mediaTimeComparesAcrossTimescales() {
        #expect(MediaTime(value: 1, timescale: 2) < MediaTime(value: 3, timescale: 4))
        #expect(!(MediaTime(value: 8_000, timescale: 16_000) < MediaTime(value: 1, timescale: 2)))
        #expect((MediaTime(value: 1, timescale: 2) + MediaTime(value: 8_000, timescale: 16_000)).seconds == 1)
    }

    @Test func validationAcceptsWellFormedRevision() throws {
        let revision = TranscriptFixtures.revision([
            TranscriptFixtures.segment("s", [("Hello", 1, 1.4), ("world.", 1.5, 2)])
        ])
        try revision.validate(sourceDuration: 60)
    }

    @Test func validationRejectsBadUTF8RangesAndOutOfSourceTiming() {
        var segment = TranscriptFixtures.segment("s", [("héllo", 1, 1.4)])
        segment.units[0].utf8End = 2  // inside the two-byte "é"
        #expect(throws: TranscriptValidationError.badUTF8Range("s-u0")) {
            try TranscriptFixtures.revision([segment]).validate(sourceDuration: 60)
        }
        let late = TranscriptFixtures.segment("s", [("late", 70, 71)])
        #expect(throws: TranscriptValidationError.self) {
            try TranscriptFixtures.revision([late]).validate(sourceDuration: 60)
        }
    }

    @Test func revisionRoundTripsThroughThePackage() throws {
        let dir = try TempDirectory()
        let package = try Fixtures.package(in: dir.url, meta: Fixtures.meta())
        let revision = TranscriptFixtures.revision([TranscriptFixtures.segment("s", [("Hi", 0.5, 0.9)])], id: "abc-123")
        try package.saveTranscript(revision)
        #expect(try package.loadTranscript(id: "abc-123") == revision)
        #expect(try package.loadTranscript(id: "../meta") == nil)
    }

    @Test func unitTextUsesByteRanges() {
        let segment = TranscriptFixtures.segment("s", [("Über", 0, 1), ("alles", 1, 2)])
        #expect(segment.text(of: segment.units[0]) == "Über")
        #expect(segment.text(of: segment.units[1]) == "alles")
    }
}

struct SubtitleSettingsTests {
    @Test func oldEditFilesDecodeWithDefaultSubtitles() throws {
        var config = EditConfig(segments: [Segment(start: 0, end: 10)])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        json.removeValue(forKey: "subtitles")
        let decoded = try JSONDecoder().decode(EditConfig.self, from: JSONSerialization.data(withJSONObject: json))
        config.subtitles = SubtitleSettings()
        #expect(decoded == config)
    }

    @Test func subtitlesRoundTrip() throws {
        var config = EditConfig(segments: [Segment(start: 0, end: 10)])
        config.subtitles.cues = [
            SubtitleCue(start: 1, end: 2, text: "Hello", generatedText: "hello", position: NormPoint(x: 0.3, y: 0.2))
        ]
        config.subtitles.style.fontFamily = "Avenir Next"
        config.subtitles.placement = SubtitlePlacement(anchor: .top, margin: 0.1)
        #expect(try JSONDecoder().decode(EditConfig.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func normalisationClampsCuesAndStyle() {
        var config = EditConfig(segments: [Segment(start: 0, end: 10)])
        config.subtitles.style.size = 5
        config.subtitles.style.backgroundOpacity = .nan
        config.subtitles.cues = [
            SubtitleCue(start: 8, end: 20, text: "late"),
            SubtitleCue(start: 3, end: 2, text: "backwards"),
            SubtitleCue(start: 1, end: 2, text: "early", position: NormPoint(x: 2, y: -1)),
        ]
        let normalised = config.normalized(duration: 10)
        #expect(normalised.subtitles.style.size == EditLimits.subtitleSize.upperBound)
        #expect(normalised.subtitles.style.backgroundOpacity == SubtitleStyle().backgroundOpacity)
        #expect(normalised.subtitles.cues.map(\.text) == ["early", "late"])
        #expect(normalised.subtitles.cues[0].position == NormPoint(x: 1, y: 0))
        #expect(normalised.subtitles.cues[1].end == 10)
    }

    @Test func activeCuesSkipDisabledAndEmpty() {
        var settings = SubtitleSettings(cues: [
            SubtitleCue(start: 0, end: 2, text: "one"), SubtitleCue(start: 1, end: 3, text: "  "),
        ])
        #expect(settings.activeCues(at: 1.5).map(\.text) == ["one"])
        #expect(settings.activeCues(at: 2).isEmpty)
        settings.enabled = false
        #expect(settings.activeCues(at: 1).isEmpty)
    }

    @Test func presetsCarrySubtitleStyleButNotCues() {
        var config = EditConfig(segments: [Segment(start: 0, end: 10)])
        config.subtitles.style.bold = false
        config.subtitles.cues = [SubtitleCue(start: 0, end: 1, text: "x")]
        let preset = EditPreset(name: "P", from: config)
        let applied = preset.applied(to: EditConfig(segments: [Segment(start: 0, end: 10)]))
        #expect(applied.subtitles.style.bold == false)
        #expect(applied.subtitles.cues.isEmpty)
    }
}

struct CueBuilderTests {
    @Test func breaksAtPausesAndSentenceEnds() {
        let revision = TranscriptFixtures.revision([
            TranscriptFixtures.segment(
                "s",
                [
                    ("Hello", 0, 0.4), ("there.", 0.5, 1.2), ("How", 1.3, 1.5), ("are", 1.6, 1.8), ("you", 1.9, 2.2),
                    ("today", 3.5, 4),
                ])
        ])
        let cues = CueBuilder.cues(from: revision)
        #expect(cues.map(\.text) == ["Hello there.", "How are you", "today"])
        #expect(cues[0].start == 0)
        #expect(cues.allSatisfy { $0.generatedText == $0.text && !$0.isUserEdited })
    }

    @Test func longRunsSplitAfterAClause() {
        var words: [(String, Double, Double)] = []
        for i in 0..<30 {
            let text = i == 9 ? "comma," : "word\(i)"
            words.append((text, Double(i) * 0.2, Double(i) * 0.2 + 0.15))
        }
        let cues = CueBuilder.cues(from: TranscriptFixtures.revision([TranscriptFixtures.segment("s", words)]))
        #expect(cues.count >= 2)
        #expect(cues[0].text.hasSuffix("comma,"))
        #expect(cues.allSatisfy { CueBuilder.weightedLength($0.text) <= 84 })
        #expect(cues.allSatisfy { $0.duration <= 6.0001 })
    }

    @Test func alignerStylePunctuationIsKeptAndEndsSentences() {
        // Aligner units don't include punctuation; it lives only in the raw text.
        let segment = TranscriptFixtures.segment(
            "s", [("Hi", 0, 0.3), ("there.", 0.4, 1.1), ("Bye", 1.2, 1.5), ("now.", 1.6, 2)], method: .forcedAlignment,
            inlinePunctuation: true)
        var fixed = segment
        // Units cover the letters only.
        fixed.units = segment.units.map { unit in
            var u = unit
            if let text = segment.text(of: unit), text.hasSuffix(".") { u.utf8End -= 1 }
            return u
        }
        let cues = CueBuilder.cues(from: TranscriptFixtures.revision([fixed]))
        #expect(cues.map(\.text) == ["Hi there.", "Bye now."])
    }

    @Test func windowOnlySegmentsBecomeOneCoarseCue() {
        let segment = TranscriptSegment(
            id: "w", sourceRange: TranscriptFixtures.range(0, 25), rangeMeaning: .processingWindow,
            rawText: "Some text without timing", languageTag: "ja",
            units: [TranscriptUnit(id: "w-u0", utf8Start: 0, utf8End: 4, kind: .word)])
        let cues = CueBuilder.cues(from: TranscriptFixtures.revision([segment]))
        #expect(cues.count == 1)
        #expect(cues[0].coarse)
        #expect(cues[0].start == 0 && cues[0].end == 25)
    }

    @Test func cjkTextIsJoinedWithoutSpacesAndCountsDouble() {
        #expect(CueBuilder.weightedLength("你好ab") == 6)
        let a = TranscriptFixtures.segment("a", [("你好", 0, 0.5)])
        let b = TranscriptFixtures.segment("b", [("世界", 0.6, 1)])
        let cues = CueBuilder.cues(from: TranscriptFixtures.revision([a, b]))
        #expect(cues.map(\.text) == ["你好世界"])
    }

    @Test func shortCuesAreHeldWithoutOverlappingTheNext() {
        let revision = TranscriptFixtures.revision([
            TranscriptFixtures.segment("s", [("Yes.", 0, 0.2), ("Absolutely", 1.0, 1.6)])
        ])
        let cues = CueBuilder.cues(from: revision)
        #expect(cues.count == 2)
        #expect(cues[0].end == 0.8)
        #expect(cues[0].end <= cues[1].start)
    }
}

struct SubtitleEditingTests {
    @Test func removingSourceSplitsAndDropsSlivers() throws {
        let config = EditConfig(segments: [Segment(start: 0, end: 10)])
        let cut = try config.removingSource(start: 4, end: 5)
        #expect(cut.segments.map { [$0.start, $0.end] } == [[0, 4], [5, 10]])
        #expect(cut.segments[0].id == config.segments[0].id)
        #expect(cut.segments[0].id != cut.segments[1].id)
        let edge = try config.removingSource(start: 0, end: 3)
        #expect(edge.segments.map { [$0.start, $0.end] } == [[3, 10]])
        #expect(throws: SegmentEditError.lastSegment) { try config.removingSource(start: 0, end: 10) }
    }

    @Test func wordCutsNeedContiguousFineTiming() throws {
        let segment = TranscriptFixtures.segment("s", [("one", 0, 0.5), ("two", 0.6, 1), ("three", 1.1, 1.6)])
        let revision = TranscriptFixtures.revision([segment])
        let ids = segment.units.map(\.id)
        let range = try TranscriptCuts.sourceRange(of: [ids[1], ids[0]], in: revision)
        #expect(range.start == 0 && range.end == 1)
        #expect(throws: TranscriptCutError.notContiguous) {
            try TranscriptCuts.sourceRange(of: [ids[0], ids[2]], in: revision)
        }
        var coarse = segment
        coarse.units[1].timing?.validation = .needsReview
        #expect(throws: TranscriptCutError.noFineTiming) {
            try TranscriptCuts.sourceRange(of: ids, in: TranscriptFixtures.revision([coarse]))
        }
    }

    @Test func searchIsCaseAndDiacriticInsensitive() {
        let cues = [SubtitleCue(start: 0, end: 1, text: "Café au lait"), SubtitleCue(start: 1, end: 2, text: "tea")]
        #expect(TranscriptSearch.matches("CAFE", in: cues) == [cues[0].id])
        #expect(TranscriptSearch.matches("  ", in: cues).isEmpty)
    }

    @Test func srtUsesEditedTimeAndSplitsAtCuts() {
        let timeline = EditTimeline(segments: [Segment(start: 0, end: 4), Segment(start: 6, end: 10)])
        let cues = [
            SubtitleCue(start: 1, end: 2, text: "First"),
            SubtitleCue(start: 3, end: 7, text: "Across\n\nthe cut"),
            SubtitleCue(start: 4.5, end: 5.5, text: "Cut away"),
        ]
        let srt = SubtitleExport.srt(cues: cues, timeline: timeline)
        #expect(
            srt
                == """
                1
                00:00:01,000 --> 00:00:02,000
                First

                2
                00:00:03,000 --> 00:00:04,000
                Across
                the cut

                3
                00:00:04,000 --> 00:00:05,000
                Across
                the cut


                """)
    }

    @Test func mergeReappliesUnambiguousCorrectionsAndReportsConflicts() {
        let old = TranscriptFixtures.segment("o", [("hello", 0, 0.5), ("wurld", 0.6, 1), ("bye", 3, 3.5)])
        let oldRevision = TranscriptFixtures.revision([old], id: "old")
        var cues = CueBuilder.cues(from: oldRevision)
        #expect(cues.map(\.text) == ["hello wurld", "bye"])
        cues[0].text = "Hello, world!"  // correction
        cues[1].text = "Goodbye"  // correction

        // New revision: same words in the first span, different words in the second.
        let new = TranscriptFixtures.segment("n", [("hello", 0, 0.5), ("wurld", 0.6, 1), ("buy", 3, 3.5)])
        let result = SubtitleMerge.merge(current: cues, newRevision: TranscriptFixtures.revision([new], id: "new"))
        #expect(result.reapplied == 1)
        #expect(result.conflicts.map(\.mine.text) == ["Goodbye"])
        #expect(result.cues.map(\.text) == ["Hello, world!", "buy"])

        let kept = SubtitleMerge.merge(
            current: cues, newRevision: TranscriptFixtures.revision([new], id: "new"), keep: [cues[1].id])
        #expect(kept.conflicts.isEmpty)
        #expect(kept.cues.map(\.text) == ["Hello, world!", "Goodbye"])
    }
}

struct SubtitleReceiveTests {
    @Test func receiveAdoptsWhenUneditedAndWaitsWhenEdited() {
        let first = TranscriptFixtures.revision([TranscriptFixtures.segment("a", [("one", 0, 0.5)])], id: "r1")
        var settings = SubtitleSettings()
        #expect(settings.receive(first) == .adopted)
        #expect(settings.revisionID == "r1")
        #expect(settings.cues.map(\.text) == ["one"])

        settings.cues[0].text = "One!"
        let second = TranscriptFixtures.revision([TranscriptFixtures.segment("b", [("one", 0, 0.5)])], id: "r2")
        #expect(settings.receive(second) == .candidate)
        #expect(settings.candidateRevisionID == "r2")
        #expect(settings.cues.map(\.text) == ["One!"])

        let result = settings.adopt(second)
        #expect(result.reapplied == 1)
        #expect(settings.revisionID == "r2" && settings.candidateRevisionID == nil)
        #expect(settings.cues.map(\.text) == ["One!"])
    }
}
