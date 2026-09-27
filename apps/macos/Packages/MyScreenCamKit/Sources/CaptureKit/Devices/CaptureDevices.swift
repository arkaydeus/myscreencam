import AVFoundation
import CoreAudio
import Foundation

/// A video capture device.
public struct CameraDevice: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case builtIn
        case external
        case continuity
        case other
    }

    /// `AVCaptureDevice.uniqueID`: stable across launches and reconnects.
    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// An audio input device.
public struct MicrophoneDevice: Sendable, Hashable, Identifiable {
    /// `AVCaptureDevice.uniqueID` (also accepted by `SCStreamConfiguration.microphoneCaptureDeviceID`).
    public var id: String
    public var name: String
    /// The system default input.
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// A snapshot of the connected capture devices.
public struct CaptureDeviceList: Sendable, Equatable {
    public var cameras: [CameraDevice]
    public var microphones: [MicrophoneDevice]

    public init(cameras: [CameraDevice], microphones: [MicrophoneDevice]) {
        self.cameras = cameras
        self.microphones = microphones
    }
}

/// Camera and microphone discovery. Listing never prompts for permission.
public enum CaptureDevices {
    static let cameraTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]

    public static func cameras() -> [CameraDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: cameraTypes, mediaType: .video, position: .unspecified)
            .devices.map { device in
                let kind: CameraDevice.Kind =
                    switch device.deviceType {
                    case .builtInWideAngleCamera: .builtIn
                    case .external: .external
                    case .continuityCamera: .continuity
                    default: .other
                    }
                return CameraDevice(id: device.uniqueID, name: device.localizedName, kind: kind)
            }
    }

    public static func microphones() -> [MicrophoneDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        )
        .devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID) }
    }

    public static func current() -> CaptureDeviceList {
        CaptureDeviceList(cameras: cameras(), microphones: microphones())
    }

    /// The current list, then a new list whenever a device connects or disconnects or the default input
    /// changes. Notification-driven (no polling); observers are removed when the consumer stops iterating.
    public static func changes() -> AsyncStream<CaptureDeviceList> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: CaptureDeviceList.self, bufferingPolicy: .bufferingNewest(1))
        let observer = DeviceChangeObserver { continuation.yield(current()) }
        continuation.yield(current())
        continuation.onTermination = { _ in observer.invalidate() }
        return stream
    }
}

/// Watches AVFoundation connect/disconnect notifications and the Core Audio default-input property.
private final class DeviceChangeObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []
    private var audioListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.myscreencam.capture.devices", qos: .utility)
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(onChange: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        let names = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in onChange() }
        }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        lock.withLock {
            self.tokens = tokens
            self.audioListener = status == noErr ? listener : nil
        }
    }

    func invalidate() {
        let (tokens, listener) = lock.withLock {
            defer {
                self.tokens = []
                self.audioListener = nil
            }
            return (self.tokens, self.audioListener)
        }
        tokens.forEach(NotificationCenter.default.removeObserver)
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }
}
