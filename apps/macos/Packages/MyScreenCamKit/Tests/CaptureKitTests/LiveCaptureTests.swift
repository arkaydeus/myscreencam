import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
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

struct CaptureWindowPolicyTests {
    @Test func demoModePermitsOwnWindowsButAlwaysExcludesControls() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for excluded in [true, false] {
            #expect(
                CaptureSources.permitsWindow(
                    id: 1, processID: ownPID, excludingOwnApplication: excluded, excludedWindowIDs: [2]) == !excluded)
            #expect(
                CaptureSources.permitsWindow(
                    id: 3, processID: -1, excludingOwnApplication: excluded, excludedWindowIDs: [2]))
            #expect(
                !CaptureSources.permitsWindow(
                    id: 2, processID: ownPID, excludingOwnApplication: excluded, excludedWindowIDs: [2]))
        }
    }
}

@Suite(.enabled(if: CGPreflightScreenCaptureAccess()), .serialized)
@MainActor
struct LiveDemoCaptureTests {
    @Test func ownWindowListingAndDisplayRegionFiltersExcludeControls() async throws {
        guard #available(macOS 15.2, *) else { return }
        let screen = try #require(NSScreen.screens.first { $0.frame.origin == .zero })
        func makeWindow(_ title: String, excluded: Bool) -> NSWindow {
            let window = NSWindow(
                contentRect: CGRect(x: 40, y: screen.frame.maxY - 200, width: 200, height: 120), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = title
            window.sharingType = excluded ? .none : .readOnly
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = (excluded ? NSColor.green : NSColor.red).cgColor
            window.orderFrontRegardless()
            window.displayIfNeeded()
            return window
        }
        let editor = makeWindow("Demo editor", excluded: false)
        let recorder = makeWindow("New Recording", excluded: true)
        defer { editor.close(); recorder.close() }
        let editorID = CGWindowID(editor.windowNumber)
        let recorderID = CGWindowID(recorder.windowNumber)
        let normal = try await CaptureSources.windows()
        let demo = try await CaptureSources.windows(includingOwnApplication: true)
        #expect(!normal.contains { $0.id == editorID || $0.id == recorderID })
        #expect(demo.contains { $0.id == editorID })
        #expect(!demo.contains { $0.id == recorderID })
        for source: ScreenSource in [
            .display(CGMainDisplayID()),
            .region(display: CGMainDisplayID(), rect: CGRect(x: 0, y: 0, width: 400, height: 300)),
        ] {
            for excluded in [true, false] {
                let preview = try await CaptureSources.thumbnail(
                    of: source, maxPixelWidth: 160, excludingOwnApplication: excluded)
                #expect(preview.width <= 160)
                // Both windows overlap here. Demo previews must show the red editor beneath the green
                // recorder; ordinary previews must omit both own-app windows.
                let sourceWidth = source == .display(CGMainDisplayID()) ? screen.frame.width : 400
                let scale = CGFloat(preview.width) / sourceWidth
                let red = try isRed(preview, x: Int(140 * scale), y: Int(140 * scale))
                #expect(red == !excluded)
            }
        }
        await #expect(throws: CaptureError.self) {
            try await ContentResolver.resolve(.window(recorderID), excludingOwnApplication: false)
        }
        await #expect(throws: CaptureError.self) {
            try await ContentResolver.resolve(.window(editorID), excludingOwnApplication: true)
        }
        _ = try await ContentResolver.resolve(.window(editorID), excludingOwnApplication: false)
    }

    private func isRed(_ image: CGImage, x: Int, y: Int) throws -> Bool {
        let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel: [UInt8] = [0, 0, 0, 0]
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(
                CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel[0] > 200 && pixel[1] < 50 && pixel[2] < 50
    }
}
