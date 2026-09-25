import CaptureKit
import CoreGraphics
import Foundation
import Observation
import RecordingKit

/// The recorder's saved choices (UserDefaults, `recorder.*` keys). Every property writes through on change.
@MainActor
@Observable
final class RecorderPreferences {
    /// A saved region: display-local points, origin top-left (what `ScreenSource.region` expects).
    struct Region: Equatable {
        var displayID: CGDirectDisplayID
        var rect: CGRect
    }

    var sourceKind: RecorderSourceKind { didSet { defaults.set(sourceKind.rawValue, forKey: Key.sourceKind) } }
    var displayID: CGDirectDisplayID? { didSet { store(displayID.map { Int($0) }, Key.displayID) } }
    var windowID: CGWindowID? { didSet { store(windowID.map { Int($0) }, Key.windowID) } }
    var region: Region? { didSet { storeRegion() } }
    /// `AVCaptureDevice.uniqueID`, nil = no camera.
    var cameraID: String? { didSet { store(cameraID, Key.cameraID) } }
    /// Name of the saved camera, used to find it again when its uniqueID changes (e.g. Continuity Camera).
    var cameraName: String? { didSet { store(cameraName, Key.cameraName) } }
    /// `AVCaptureDevice.uniqueID`, nil = no microphone.
    var microphoneID: String? { didSet { store(microphoneID, Key.microphoneID) } }
    var microphoneName: String? { didSet { store(microphoneName, Key.microphoneName) } }
    var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: Key.systemAudio) } }
    /// Hide the system cursor in the capture; the editor draws the recorded one.
    var customCursor: Bool { didSet { defaults.set(customCursor, forKey: Key.customCursor) } }
    var frameRate: Int { didSet { defaults.set(frameRate, forKey: Key.frameRate) } }
    var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Key.codec) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceKind = defaults.string(forKey: Key.sourceKind).flatMap(RecorderSourceKind.init(rawValue:)) ?? .display
        displayID = (defaults.object(forKey: Key.displayID) as? Int).map { CGDirectDisplayID(truncatingIfNeeded: $0) }
        windowID = (defaults.object(forKey: Key.windowID) as? Int).map { CGWindowID(truncatingIfNeeded: $0) }
        region = Self.loadRegion(defaults)
        cameraID = defaults.string(forKey: Key.cameraID)
        cameraName = defaults.string(forKey: Key.cameraName)
        microphoneID = defaults.string(forKey: Key.microphoneID)
        microphoneName = defaults.string(forKey: Key.microphoneName)
        captureSystemAudio = defaults.object(forKey: Key.systemAudio) as? Bool ?? true
        customCursor = defaults.object(forKey: Key.customCursor) as? Bool ?? true
        let rate = defaults.integer(forKey: Key.frameRate)
        frameRate = rate == 30 ? 30 : 60
        codec = defaults.string(forKey: Key.codec).flatMap(VideoCodec.init(rawValue:)) ?? .hevc
    }

    func selectCamera(_ device: CameraDevice?) {
        cameraID = device?.id
        cameraName = device?.name
    }

    func selectMicrophone(_ device: MicrophoneDevice?) {
        microphoneID = device?.id
        microphoneName = device?.name
    }

    /// The source for the current tab, if one is chosen.
    var selectedSource: ScreenSource? {
        switch sourceKind {
        case .display: displayID.map { .display($0) }
        case .window: windowID.map { .window($0) }
        case .region: region.map { .region(display: $0.displayID, rect: $0.rect) }
        }
    }

    // MARK: - Storage

    private enum Key {
        static let sourceKind = "recorder.sourceKind"
        static let displayID = "recorder.displayID"
        static let windowID = "recorder.windowID"
        static let region = "recorder.region"
        static let cameraID = "recorder.cameraID"
        static let cameraName = "recorder.cameraName"
        static let microphoneID = "recorder.microphoneID"
        static let microphoneName = "recorder.microphoneName"
        static let systemAudio = "recorder.systemAudio"
        static let customCursor = "recorder.customCursor"
        static let frameRate = "recorder.frameRate"
        static let codec = "recorder.codec"
    }

    private func store(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func storeRegion() {
        guard let region else {
            defaults.removeObject(forKey: Key.region)
            return
        }
        let rect = region.rect
        defaults.set(
            [Double(region.displayID), rect.minX, rect.minY, rect.width, rect.height].map { Double($0) },
            forKey: Key.region)
    }

    private static func loadRegion(_ defaults: UserDefaults) -> Region? {
        guard let values = defaults.array(forKey: Key.region) as? [Double], values.count == 5 else { return nil }
        return Region(
            displayID: CGDirectDisplayID(values[0]),
            rect: CGRect(x: values[1], y: values[2], width: values[3], height: values[4]))
    }
}

extension VideoCodec {
    var displayName: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .proRes422Proxy: "ProRes 422 Proxy"
        }
    }
}

extension RecorderSourceKind {
    var title: String {
        switch self {
        case .display: "Display"
        case .window: "Window"
        case .region: "Region"
        }
    }

    var systemImage: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .region: "rectangle.dashed"
        }
    }
}
