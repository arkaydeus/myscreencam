import AVFoundation
import CaptureKit
import CoreGraphics
import Foundation
import ProjectKit
import Testing

@testable import RecordingKit

@Test func ownApplicationExclusionDefaultsAndReachesScreenConfiguration() {
    let root = URL(filePath: "/tmp")
    #expect(RecordingOptions(source: .display(1), recordingsRoot: root).excludesOwnApplication)
    #expect(ScreenCaptureConfiguration(source: .display(1)).excludesOwnApplication)
    for source: ScreenSource in [
        .display(1), .region(display: 1, rect: CGRect(x: 0, y: 0, width: 20, height: 20)), .window(2),
    ] {
        for excluded in [true, false] {
            let options = RecordingOptions(source: source, recordingsRoot: root, excludesOwnApplication: excluded)
            let configuration = options.screenConfiguration(hasInputMonitoring: false)
            #expect(configuration.excludesOwnApplication == excluded)
            #expect(configuration.source == source)
        }
    }
}

@Test func firstFrameGatePropagatesStartupFailure() async throws {
    let gate = FirstFrameGate()
    gate.fail(RecordingError.writerFailed(.screen, "encoder stopped"))
    await #expect(throws: RecordingError.self) {
        try await gate.wait(timeout: 1, timeoutError: RecordingError.noFirstFrame)
    }
}

struct EventLogTests {
    @Test func buffersInMemoryAndFlushesOnClose() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: PackageLayout.events)
        let writer = try EventLogWriter(url: url)
        for index in 0..<100 {
            writer.append(InputEvent(t: Double(index) / 100, kind: .move, x: 0.5, y: 0.5, cursor: 0))
        }
        try await Task.sleep(for: .milliseconds(50))
        // 100 short lines are well under the flush threshold: nothing has been written yet (no per-event I/O).
        #expect(try Data(contentsOf: url).isEmpty)
        try await writer.close()
        let events = InputEventLog.decode(try Data(contentsOf: url))
        #expect(events.count == 100)
        #expect(events.last?.t == 0.99)
        #expect(writer.count == 100)
    }

    @Test func largeVolumesFlushInChunks() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: PackageLayout.events)
        let writer = try EventLogWriter(url: url)
        for index in 0..<5_000 {
            writer.append(InputEvent(t: Double(index), kind: .move, x: 0.25, y: 0.75))
        }
        try await Task.sleep(for: .milliseconds(200))
        let partial = try Data(contentsOf: url)
        #expect(!partial.isEmpty)  // flushed past the threshold without waiting for close
        try await writer.close()
        #expect(InputEventLog.decode(try Data(contentsOf: url)).count == 5_000)
    }

    @Test func pipelinePlacesEventsOnTheSessionTimeline() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TestPackages.configuration(in: root, width: 320, height: 180, events: true)
        let pipeline = try RecordingPipeline(configuration: configuration) { _, _ in }
        let video = try SyntheticVideo(width: 320, height: 180)
        let t0 = HostClock.now()
        func pointer(_ t: Double, _ kind: InputEvent.Kind = .move) -> PointerEvent {
            PointerEvent(
                hostTime: t0 + t, kind: kind, location: .zero, x: t, y: 0.5, button: kind == .move ? nil : 0)
        }
        pipeline.record(pointer(-0.1), cursor: 0)  // before the first frame: dropped
        pipeline.appendScreen(try video.frame(at: t0))
        pipeline.record(pointer(0.1), cursor: 0)
        pipeline.record(pointer(0.2, .down), cursor: 1)
        _ = pipeline.pause(atHostTime: t0 + 0.3)
        pipeline.record(pointer(0.4), cursor: 1)  // paused: dropped
        _ = pipeline.resume(atHostTime: t0 + 0.8)
        pipeline.record(pointer(0.9, .up), cursor: 2)
        pipeline.stopClock(atHostTime: t0 + 1)
        let meta = try await pipeline.finish(cursorIndex: CursorIndex())

        let events = try configuration.package.loadEvents()
        #expect(events.map(\.kind) == [.move, .down, .up])
        let times = events.map(\.t)
        #expect(abs(times[0] - 0.1) < 1e-6 && abs(times[1] - 0.2) < 1e-6 && abs(times[2] - 0.4) < 1e-6)
        #expect(events.map(\.cursor) == [0, 1, 2])
        #expect(events[1].isLeftClick)
        #expect(abs(meta.duration - 0.5) < 1e-6)
        #expect(try configuration.package.loadCursorIndex() == CursorIndex())
        // The editor creates edit.json, never the recorder.
        #expect(try configuration.package.loadEdit() == nil)
    }
}

struct EncoderSettingsTests {
    @Test func bitrateScalesWithPixelsAndFrameRate() {
        let uhd60 = EncoderSettings.averageBitRate(
            codec: .hevc, width: 3024, height: 1964, frameRate: 60, isCamera: false)
        let uhd30 = EncoderSettings.averageBitRate(
            codec: .hevc, width: 3024, height: 1964, frameRate: 30, isCamera: false)
        #expect(uhd60 > uhd30)
        #expect((15_000_000...25_000_000).contains(uhd60))
        #expect(
            EncoderSettings.averageBitRate(codec: .h264, width: 3024, height: 1964, frameRate: 60, isCamera: false)
                > uhd60)
        #expect(
            EncoderSettings.averageBitRate(codec: .hevc, width: 320, height: 180, frameRate: 30, isCamera: false)
                == 2_000_000)
        #expect(
            EncoderSettings.averageBitRate(codec: .hevc, width: 7680, height: 4320, frameRate: 60, isCamera: false)
                == 80_000_000)
    }

    @Test func realTimeHardwareSettingsAreAccepted() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings = EncoderSettings.video(codec: .hevc, width: 1920, height: 1080, frameRate: 60, isCamera: false)
        let validated = EncoderSettings.validated(settings, for: writer)
        #expect(writer.canApply(outputSettings: validated, forMediaType: .video))
        let compression = try #require(validated[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(compression[AVVideoMaxKeyFrameIntervalDurationKey] as? Double == 1)
        #expect(compression[AVVideoAllowFrameReorderingKey] as? Bool == false)
        #expect(compression[AVVideoExpectedSourceFrameRateKey] as? Int == 60)
    }

    @Test func aacIsMonoOrStereo48k() {
        #expect(EncoderSettings.aac(sourceChannels: 1)[AVNumberOfChannelsKey] as? Int == 1)
        #expect(EncoderSettings.aac(sourceChannels: 2)[AVNumberOfChannelsKey] as? Int == 2)
        #expect(EncoderSettings.aac(sourceChannels: 6)[AVNumberOfChannelsKey] as? Int == 2)
        #expect(EncoderSettings.aac(sourceChannels: 2)[AVSampleRateKey] as? Int == 48_000)
    }

    @Test func codecFourCCs() {
        #expect(VideoCodec.allCases.map(\.fourCC) == ["hvc1", "avc1", "apco"])
    }
}

struct RecordingSessionStateTests {
    let options = RecordingOptions(
        source: .display(CGMainDisplayID()), recordingsRoot: FileManager.default.temporaryDirectory)

    @Test func controlsAreRejectedBeforeStart() async {
        let session = RecordingSession(options: options)
        #expect(session.state == .idle)
        #expect(session.elapsed == 0)
        #expect(!session.pause())
        #expect(!session.resume())
        await #expect(throws: RecordingError.self) { _ = try await session.stop() }
        #expect(session.package == nil)
    }

    @Test func defaultsMatchTheSpec() {
        #expect(options.frameRate == 60)
        #expect(options.videoCodec == .hevc)
        #expect(options.captureSystemAudio)
        #expect(options.cameraWidth == 1280 && options.cameraHeight == 720 && options.cameraFrameRate == 30)
        #expect(RecordingOptions.defaultName(for: Date()).hasPrefix("Recording "))
    }
}

/// Live capture: runs only where this process already has Screen Recording permission (never prompts).
@Suite(.enabled(if: CGPreflightScreenCaptureAccess()))
struct LiveRecordingTests {
    @Test func recordsTheMainDisplayWithAPause() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(
            options: RecordingOptions(
                source: .display(CGMainDisplayID()), recordingsRoot: root, captureSystemAudio: false))
        try await session.start()
        #expect(session.state == .recording)
        try await Task.sleep(for: .milliseconds(700))
        #expect(session.pause())
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.resume())
        try await Task.sleep(for: .milliseconds(500))
        let package = try await session.stop()
        let meta = try package.loadMeta()
        #expect(meta.pauses.count == 1)
        #expect(abs(meta.duration - 1.2) < 0.2)
        #expect(meta.screen.pixelWidth % 2 == 0 && meta.screen.pixelHeight % 2 == 0)
        #expect(package.availableStreams().contains(.screen))
        let track = try #require(
            try await AVURLAsset(url: package.url(for: .screen)).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize).width == CGFloat(meta.screen.pixelWidth))
        #expect(session.statistics.streams[.screen]?.appended ?? 0 >= 1)
    }
}
