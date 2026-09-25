import AVFoundation
import CaptureKit
import CoreMedia
import Foundation
import ProjectKit
import Testing

@testable import RecordingKit

/// End-to-end writer tests: synthetic capture buffers → `RecordingPipeline` → files read back with AVFoundation.
@Suite(.serialized)
struct WriterTests {
    @Test func emptyScreenCannotBeReportedAsSaved() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TestPackages.configuration(in: root, width: 320, height: 180)
        let pipeline = try RecordingPipeline(configuration: configuration) { _, _ in }
        await #expect(throws: RecordingError.self) {
            _ = try await pipeline.finish(cursorIndex: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: configuration.package.url(PackageLayout.meta).path))
        #expect(!FileManager.default.fileExists(atPath: configuration.package.url(for: .screen).path))
    }

    @Test func failedScreenAppendKeepsFragmentsButDoesNotSaveMetadata() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TestPackages.configuration(in: root, width: 320, height: 180)
        let pipeline = try RecordingPipeline(configuration: configuration) { _, _ in }
        let video = try SyntheticVideo(width: 320, height: 180)
        let t0 = HostClock.now()
        for index in 0..<5 {
            pipeline.appendScreen(try video.frame(at: t0 + Double(index) * 0.1))
            try await Task.sleep(for: .milliseconds(8))
        }
        pipeline.appendScreen(try SyntheticAudio.buffer(at: t0 + 0.6))
        pipeline.stopClock(atHostTime: t0 + 0.7)
        await #expect(throws: RecordingError.self) {
            _ = try await pipeline.finish(cursorIndex: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: configuration.package.url(PackageLayout.meta).path))
        #expect(FileManager.default.fileExists(atPath: configuration.package.url(for: .screen).path))
    }

    /// Irregular (VFR) screen frame times in seconds after the first frame, with a pause from 1.1 to 1.6.
    static let frameTimes = [0, 0.016, 0.033, 0.2, 0.21, 0.5, 1.0, 1.2, 1.3, 1.7, 2.0]
    static let pauseStart = 1.1
    static let pauseEnd = 1.6
    static let stopAt = 2.2
    /// Session times of the frames that survive (1.2 and 1.3 fall inside the pause).
    static let expectedSessionTimes = [0, 0.016, 0.033, 0.2, 0.21, 0.5, 1.0, 1.2, 1.5]

    @Test(arguments: [VideoCodec.hevc, .h264, .proRes422Proxy])
    func screenFileIsVFREvenAndPauseAware(codec: VideoCodec) async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        // An odd requested size (641.5 × 361 points @1×) rounds down to even pixels.
        let pixels = CaptureGeometry.evenPixelSize(points: CGSize(width: 641.5, height: 361), scale: 1)
        #expect(pixels.width == 640 && pixels.height == 360)
        let configuration = try TestPackages.configuration(
            in: root, width: pixels.width, height: pixels.height, codec: codec)
        let pipeline = try RecordingPipeline(configuration: configuration) { kind, message in
            Issue.record("\(kind) failed: \(message)")
        }
        let video = try SyntheticVideo(width: pixels.width, height: pixels.height)
        let t0 = HostClock.now()
        var paused = false
        var resumed = false
        for time in Self.frameTimes {
            if !paused, time > Self.pauseStart {
                #expect(pipeline.pause(atHostTime: t0 + Self.pauseStart))
                paused = true
            }
            if !resumed, time > Self.pauseEnd {
                #expect(pipeline.resume(atHostTime: t0 + Self.pauseEnd))
                resumed = true
            }
            pipeline.appendScreen(try video.frame(at: t0 + time))
            try await Task.sleep(for: .milliseconds(15))  // real-time pacing for the encoder
        }
        pipeline.stopClock(atHostTime: t0 + Self.stopAt)
        let meta = try await pipeline.finish(cursorIndex: nil)

        // meta.json
        let package = configuration.package
        var loaded = try package.loadMeta()
        #expect(abs(loaded.createdAt.timeIntervalSince(meta.createdAt)) < 0.001)  // ISO 8601 keeps milliseconds
        loaded.createdAt = meta.createdAt
        #expect(loaded == meta)
        #expect(abs(meta.duration - 1.7) < 1e-6)
        #expect(meta.pauses.count == 1)
        #expect(abs(meta.pauses[0].at - 1.1) < 1e-6 && abs(meta.pauses[0].skipped - 0.5) < 1e-6)
        #expect(meta.streams[.screen]?.startOffset == 0)
        #expect(meta.streams.keys.sorted { $0.rawValue < $1.rawValue } == [.screen])
        #expect(pipeline.streamStatistics[.screen] == .init(appended: 9, dropped: 0))
        #expect(meta.screen.codec == codec.fourCC)

        // screen.mov
        let url = package.url(for: .screen)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 640, height: 360))
        let format = try #require(try await track.load(.formatDescriptions).first)
        let expectedCodec: CMVideoCodecType =
            switch codec {
            case .hevc: kCMVideoCodecType_HEVC
            case .h264: kCMVideoCodecType_H264
            case .proRes422Proxy: kCMVideoCodecType_AppleProRes422Proxy
            }
        #expect(format.mediaSubType.rawValue == expectedCodec)

        // VFR: exactly the captured frames at their (pause-compressed) times, no duplicates.
        let times = try samplePresentationTimes(of: track, in: asset).sorted()
        #expect(times.count == Self.expectedSessionTimes.count)
        for (actual, expected) in zip(times, Self.expectedSessionTimes) {
            #expect(abs(actual - expected) < 0.002, "frame at \(actual), expected \(expected)")
        }
        // The last frame is held until the stop time.
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.7) < 0.02)
    }

    /// While recording, the movie is written as fragments (every 2 s of media), so a crash leaves a playable file.
    @Test func screenFileIsFragmentedWhileRecording() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TestPackages.configuration(in: root, width: 320, height: 180)
        let pipeline = try RecordingPipeline(configuration: configuration) { kind, message in
            Issue.record("\(kind) failed: \(message)")
        }
        let video = try SyntheticVideo(width: 320, height: 180)
        let t0 = HostClock.now()
        for index in 0..<50 {  // 5 s of media at 10 fps
            pipeline.appendScreen(try video.frame(at: t0 + Double(index) * 0.1))
            try await Task.sleep(for: .milliseconds(4))
        }
        try await Task.sleep(for: .milliseconds(300))
        let url = configuration.package.url(for: .screen)
        let whileWriting = try topLevelBoxes(of: url)
        #expect(whileWriting.contains("moof"), "boxes: \(whileWriting)")
        #expect(whileWriting.contains("moov"))

        // A crashed recording (file as it is on disk now) already opens and has video.
        let snapshot = root.appending(path: "crashed.mov")
        try FileManager.default.copyItem(at: url, to: snapshot)
        let crashed = AVURLAsset(url: snapshot)
        #expect(try await crashed.loadTracks(withMediaType: .video).count == 1)
        #expect(try await crashed.load(.duration).seconds >= 2)

        pipeline.stopClock(atHostTime: t0 + 5)
        _ = try await pipeline.finish(cursorIndex: nil)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 5) < 0.02)
    }

    @Test func audioStreamsAreAACWithStartOffsets() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TestPackages.configuration(
            in: root, width: 320, height: 180, systemAudio: true, microphone: true)
        let pipeline = try RecordingPipeline(configuration: configuration) { kind, message in
            Issue.record("\(kind) failed: \(message)")
        }
        let video = try SyntheticVideo(width: 320, height: 180)
        let t0 = HostClock.now()
        // Audio before the first screen frame is dropped (the session hasn't started).
        pipeline.append(try SyntheticAudio.buffer(at: t0 - 0.1), to: .systemAudio)
        pipeline.appendScreen(try video.frame(at: t0))
        let bufferDuration = 1024.0 / 48_000
        for index in 0..<47 {  // ~1 s
            let time = t0 + 0.05 + Double(index) * bufferDuration
            pipeline.append(try SyntheticAudio.buffer(at: time, channels: 2), to: .systemAudio)
            pipeline.append(try SyntheticAudio.buffer(at: time + 0.02, channels: 1), to: .microphone)
            if index % 10 == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        pipeline.appendScreen(try video.frame(at: t0 + 0.5))
        pipeline.stopClock(atHostTime: t0 + 1.1)
        let meta = try await pipeline.finish(cursorIndex: nil)

        #expect(abs((meta.streams[.systemAudio]?.startOffset ?? -1) - 0.05) < 1e-6)
        #expect(abs((meta.streams[.microphone]?.startOffset ?? -1) - 0.07) < 1e-6)
        #expect(meta.capturedSystemAudio)
        #expect(meta.microphone?.deviceID == "test-mic")

        for (kind, channels) in [(StreamKind.systemAudio, 2), (.microphone, 1)] {
            let asset = AVURLAsset(url: configuration.package.url(for: kind))
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let format = try #require(try await track.load(.formatDescriptions).first)
            let asbd = try #require(format.audioStreamBasicDescription)
            #expect(asbd.mFormatID == kAudioFormatMPEG4AAC, "\(kind)")
            #expect(asbd.mSampleRate == 48_000, "\(kind)")
            #expect(Int(asbd.mChannelsPerFrame) == channels, "\(kind)")
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 1.0) < 0.06, "\(kind) duration \(duration)")
            #expect(pipeline.streamStatistics[kind]?.dropped == 0)
        }
    }

    @Test func streamsWithoutSamplesLeaveNoFile() async throws {
        let root = try TestPackages.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try TestPackages.configuration(in: root, width: 320, height: 180, microphone: true)
        let pipeline = try RecordingPipeline(configuration: configuration) { _, _ in }
        let video = try SyntheticVideo(width: 320, height: 180)
        let t0 = HostClock.now()
        pipeline.appendScreen(try video.frame(at: t0))
        pipeline.stopClock(atHostTime: t0 + 0.5)
        let meta = try await pipeline.finish(cursorIndex: nil)
        #expect(configuration.package.availableStreams() == [.screen])
        #expect(meta.microphone == nil)
        #expect(meta.streams[.microphone] == nil)
        // A single frame of a static screen still spans the whole recording.
        let duration = try await AVURLAsset(url: configuration.package.url(for: .screen)).load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.02)
    }
}
