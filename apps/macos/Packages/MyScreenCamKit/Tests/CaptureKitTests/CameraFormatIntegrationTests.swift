import AVFoundation
import CoreMedia
import Testing

@testable import CaptureKit

private func cameraDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
    ).devices
}

struct CameraFormatIntegrationTests {
    /// Exercise the AVFoundation boundary on every attached camera. A machine without a camera cannot run
    /// this hardware check; the selector's synthetic UVC and continuous-range cases still run everywhere.
    @Test(.enabled(if: !cameraDevices().isEmpty))
    func appliesSupportedDurationsAndReportsTheActiveRate() throws {
        for device in cameraDevices() {
            let originalFormat = device.activeFormat
            let originalMin = device.activeVideoMinFrameDuration
            let originalMax = device.activeVideoMaxFrameDuration
            defer {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = originalFormat
                    device.activeVideoMinFrameDuration = originalMin
                    device.activeVideoMaxFrameDuration = originalMax
                    device.unlockForConfiguration()
                } catch {
                    Issue.record("Could not restore camera configuration: \(error)")
                }
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(originalFormat.formatDescription)
            for requestedRate in [24, 30, 60] {
                let info = try CameraCapture.applyFormat(
                    device: device,
                    configuration: CameraConfiguration(
                        deviceID: device.uniqueID, width: Int(dimensions.width),
                        height: Int(dimensions.height), frameRate: requestedRate))

                let activeDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                #expect(info.deviceID == device.uniqueID)
                #expect(info.name == device.localizedName)
                #expect(info.width == Int(activeDimensions.width))
                #expect(info.height == Int(activeDimensions.height))

                let ranges = device.activeFormat.videoSupportedFrameRateRanges
                let expectedDuration = try #require(
                    CameraFormatSelector.frameDuration(
                        for: requestedRate,
                        in: ranges.map { CameraFrameDurationRange(min: $0.minFrameDuration, max: $0.maxFrameDuration) })
                )
                let minDuration = device.activeVideoMinFrameDuration
                let maxDuration = device.activeVideoMaxFrameDuration
                #expect(CMTimeCompare(minDuration, expectedDuration) == 0)
                #expect(CMTimeCompare(maxDuration, expectedDuration) == 0)
                #expect(
                    ranges.contains {
                        CMTimeCompare(minDuration, $0.minFrameDuration) >= 0
                            && CMTimeCompare(minDuration, $0.maxFrameDuration) <= 0
                    })
                #expect(info.frameRate == Int((1 / minDuration.seconds).rounded()))

                // A discrete UVC rate must use the device's exact rational duration.
                if let discrete = ranges.first(where: {
                    CMTimeCompare($0.minFrameDuration, $0.maxFrameDuration) == 0
                        && abs($0.maxFrameRate - Double(requestedRate)) < 0.01
                }) {
                    #expect(CMTimeCompare(minDuration, discrete.minFrameDuration) == 0)
                }
            }
        }
    }
}
