import AVFoundation
import CoreGraphics
import Foundation

/// A privacy permission the recorder may need.
public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    case screenRecording
    case camera
    case microphone
    /// Input Monitoring: needed for the pointer event tap (custom cursor, click zooms).
    case inputMonitoring

    public var id: String { rawValue }

    /// Deep link into the matching System Settings › Privacy & Security pane.
    public var settingsURL: URL {
        let anchor =
            switch self {
            case .screenRecording: "Privacy_ScreenCapture"
            case .camera: "Privacy_Camera"
            case .microphone: "Privacy_Microphone"
            case .inputMonitoring: "Privacy_ListenEvent"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    /// Never asked. Only camera and microphone can report this: the Core Graphics preflight APIs for screen
    /// recording and input monitoring can't tell "not asked yet" from "denied" and report `.denied`.
    case notDetermined
    /// Blocked by a configuration profile / parental controls.
    case restricted

    public var isGranted: Bool { self == .granted }
}

/// Permission checks and requests. Checks are cheap and never prompt; re-check when the app becomes active
/// (`NSApplication.didBecomeActiveNotification`) rather than polling.
public enum Permissions {
    /// Current status, without prompting.
    public static func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            CGPreflightListenEventAccess() ? .granted : .denied
        case .camera:
            status(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            status(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }

    /// Asks for the permission. Shows the system prompt the first time; afterwards macOS only remembers the
    /// answer, so if this returns anything but `.granted` send the user to ``PermissionKind/settingsURL``.
    ///
    /// Screen recording and input monitoring grants usually take effect only after the app relaunches.
    public static func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            return CGRequestListenEventAccess() ? .granted : .denied
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
            return status(.camera)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return status(.microphone)
        }
    }

    private static func status(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
