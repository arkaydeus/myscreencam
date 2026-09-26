import CoreGraphics
import CoreMedia
import Darwin
import Testing

@testable import CaptureKit

struct HostClockTests {
    @Test func hostClockMatchesCoreMediaHostClock() {
        let ours = HostClock.now()
        let coreMedia = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        #expect(abs(ours - coreMedia) < 0.01)
    }

    @Test func calibratesToMachTicks() {
        let now = mach_absolute_time()
        var converter = EventTimestampConverter()
        let seconds = converter.hostSeconds(eventTimestamp: now - 1000, nowTicks: now)
        #expect(converter.unit == .machTicks)
        #expect(abs(seconds - HostClock.seconds(machTicks: now - 1000)) < 1e-9)
    }

    @Test func calibratesToNanoseconds() {
        let now = mach_absolute_time()
        let nowNanos = UInt64(HostClock.seconds(machTicks: now) * 1_000_000_000)
        var converter = EventTimestampConverter()
        let seconds = converter.hostSeconds(eventTimestamp: nowNanos - 2_000_000, nowTicks: now)
        #expect(converter.unit == .nanoseconds)
        #expect(abs(seconds - (HostClock.seconds(machTicks: now) - 0.002)) < 1e-6)
    }

    @Test func calibrationIsLockedAfterFirstEvent() {
        let now = mach_absolute_time()
        var converter = EventTimestampConverter()
        _ = converter.hostSeconds(eventTimestamp: now, nowTicks: now)
        // A later, much older event must still be read in ticks.
        let old = converter.hostSeconds(eventTimestamp: now / 2, nowTicks: now)
        #expect(converter.unit == .machTicks)
        #expect(abs(old - HostClock.seconds(machTicks: now / 2)) < 1e-9)
    }

    @Test func zeroTimestampMeansNow() {
        let now = mach_absolute_time()
        var converter = EventTimestampConverter()
        #expect(converter.hostSeconds(eventTimestamp: 0, nowTicks: now) == HostClock.seconds(machTicks: now))
        #expect(converter.unit == nil)
    }

    @Test func retimedSampleBufferSharesDataAndShiftsTime() throws {
        let buffer = try makeTimedSampleBuffer(pts: CMTime(value: 10, timescale: 1))
        let shifted = try #require(buffer.shifted(by: CMTime(value: -4, timescale: 1)))
        #expect(shifted.presentationTimeStamp == CMTime(value: 6, timescale: 1))
        #expect(shifted.dataBuffer === buffer.dataBuffer)
    }

    private func makeTimedSampleBuffer(pts: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: 16, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: 16, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var size = 16
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return try #require(sample)
    }
}

struct CaptureGeometryTests {
    @Test(arguments: [
        (CGSize(width: 1512, height: 982), 2.0, 3024, 1964),
        (CGSize(width: 1028, height: 664.5), 2.0, 2056, 1328),  // 1329 px → 1328
        (CGSize(width: 641, height: 361), 1.0, 640, 360),
        (CGSize(width: 1511.9999999, height: 945.0000001), 2.0, 3024, 1890),  // float noise
        (CGSize(width: 0.4, height: 0.4), 1.0, 2, 2),
    ])
    func evenPixelSize(points: CGSize, scale: Double, width: Int, height: Int) {
        let size = CaptureGeometry.evenPixelSize(points: points, scale: scale)
        #expect(size.width == width)
        #expect(size.height == height)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
    }

    @Test func regionIsClippedToDisplay() {
        let display = CGSize(width: 1512, height: 982)
        #expect(
            CaptureGeometry.clampedRegion(CGRect(x: -10, y: 900, width: 200.4, height: 200), displaySize: display)
                == CGRect(x: 0, y: 900, width: 191, height: 82))
        #expect(
            CaptureGeometry.clampedRegion(CGRect(x: 2000, y: 0, width: 10, height: 10), displaySize: display)
                == .zero)
    }

    @Test func frameIntervalFollowsFrameRate() {
        #expect(ScreenCaptureConfiguration(source: .display(1), frameRate: 60).minimumFrameInterval.seconds == 1.0 / 60)
        #expect(ScreenCaptureConfiguration(source: .display(1), frameRate: 30).minimumFrameInterval.seconds == 1.0 / 30)
    }
}

struct CameraFormatSelectorTests {
    let formats = [
        CameraFormatCandidate(width: 640, height: 480, maxFrameRate: 30),
        CameraFormatCandidate(width: 1280, height: 720, maxFrameRate: 30),
        CameraFormatCandidate(width: 1920, height: 1080, maxFrameRate: 30),
        CameraFormatCandidate(width: 1280, height: 720, maxFrameRate: 15),
        CameraFormatCandidate(width: 1760, height: 1328, maxFrameRate: 30),
    ]

    @Test func picksExactMatch() {
        #expect(CameraFormatSelector.bestIndex(of: formats, width: 1280, height: 720, frameRate: 30) == 1)
    }

    @Test func prefersFormatsReachingTheRate() {
        let slowFirst = [formats[3], formats[2]]
        #expect(CameraFormatSelector.bestIndex(of: slowFirst, width: 1280, height: 720, frameRate: 30) == 1)
    }

    @Test func prefersMatchingAspectOverArea() {
        let candidates = [formats[4], formats[2]]  // 4:3-ish 2.3 MP vs 16:9 2.1 MP
        #expect(CameraFormatSelector.bestIndex(of: candidates, width: 1920, height: 1080, frameRate: 30) == 1)
    }

    @Test func emptyListHasNoChoice() {
        #expect(CameraFormatSelector.bestIndex(of: [], width: 1280, height: 720, frameRate: 30) == nil)
    }
}

struct PermissionTests {
    @Test func settingsURLsPointAtPrivacyPanes() {
        for kind in PermissionKind.allCases {
            #expect(kind.settingsURL.scheme == "x-apple.systempreferences")
            #expect(kind.settingsURL.absoluteString.contains("Privacy_"))
        }
    }

    @Test func statusNeverPrompts() {
        // Only preflight APIs run here; this must not trigger a TCC prompt.
        for kind in PermissionKind.allCases { _ = Permissions.status(kind) }
    }
}
