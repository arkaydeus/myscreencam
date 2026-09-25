import Foundation

/// Errors thrown by CaptureKit.
public enum CaptureError: Error, Sendable, Equatable, LocalizedError {
    /// The display or window no longer exists (or isn't shareable).
    case sourceNotFound(String)
    /// The region is empty after clipping to its display.
    case emptyRegion
    /// No capture device with that `uniqueID`.
    case deviceNotFound(String)
    /// The device exists but couldn't be opened (in use, permission denied, …).
    case deviceUnavailable(String)
    /// The stream started but delivered no frame in time.
    case startTimedOut
    /// The event tap couldn't be created.
    case eventTapUnavailable
    /// A framework call failed.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let what): "The capture source is no longer available (\(what))."
        case .emptyRegion: "The selected region is empty."
        case .deviceNotFound(let id): "The device \(id) isn't connected."
        case .deviceUnavailable(let reason): "The device couldn't be opened: \(reason)"
        case .startTimedOut: "Capture didn't start in time."
        case .eventTapUnavailable: "Pointer events can't be recorded (Input Monitoring)."
        case .failed(let message): message
        }
    }
}
