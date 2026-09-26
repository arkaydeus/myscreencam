import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import CaptureKit

struct DeviceListingTests {
    /// Listing devices needs no permission and never prompts.
    @Test func listsDevicesAndStreamsTheCurrentList() async {
        let current = CaptureDevices.current()
        #expect(Set(current.cameras.map(\.id)).count == current.cameras.count)
        #expect(current.microphones.filter(\.isDefault).count <= 1)
        var iterator = CaptureDevices.changes().makeAsyncIterator()
        #expect(await iterator.next() == current)
    }
}

/// Live ScreenCaptureKit tests: run only where this process already has Screen Recording permission.
@Suite(.enabled(if: CGPreflightScreenCaptureAccess()))
struct LiveScreenCaptureTests {
    @Test func listsDisplaysAndWindows() async throws {
        let displays = try await CaptureSources.displays()
        let main = try #require(displays.first)
        #expect(main.isMain)
        #expect(main.pixelWidth == Int((Double(main.frame.width) * main.scale).rounded()))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        #expect(try await CaptureSources.windows().allSatisfy { $0.processID != ownPID && !$0.title.isEmpty })
    }

    @Test func thumbnailIsSmall() async throws {
        let image = try await CaptureSources.thumbnail(of: .display(CGMainDisplayID()), maxPixelWidth: 320)
        #expect(image.width <= 320)
    }

    @Test func deliversEven420vFramesOnTheHostClock() async throws {
        let capture = ScreenCapture(configuration: ScreenCaptureConfiguration(source: .display(CGMainDisplayID())))
        let geometry = try await capture.prepare()
        #expect(geometry.pixelWidth % 2 == 0 && geometry.pixelHeight % 2 == 0)
        final class Frames: @unchecked Sendable {
            let lock = NSLock()
            var formats: [OSType] = []
            var times: [Double] = []
        }
        let frames = Frames()
        try await capture.start(
            onSample: { buffer, output in
                guard output == .video, let image = buffer.imageBuffer else { return }
                frames.lock.withLock {
                    frames.formats.append(CVPixelBufferGetPixelFormatType(image))
                    frames.times.append(buffer.presentationTimeStamp.seconds)
                }
            }, onStop: { _ in })
        try await Task.sleep(for: .milliseconds(500))
        await capture.stop()
        let (formats, times) = frames.lock.withLock { (frames.formats, frames.times) }
        #expect(!formats.isEmpty)
        #expect(formats.allSatisfy { $0 == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange })
        #expect(abs((times.last ?? 0) - HostClock.now()) < 1)
    }
}
