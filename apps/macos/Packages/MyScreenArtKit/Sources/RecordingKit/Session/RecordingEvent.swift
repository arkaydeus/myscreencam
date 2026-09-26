import CaptureKit
import Foundation
import ProjectKit

/// Lifecycle notifications from a ``RecordingSession``. Elapsed time is not streamed; read
/// ``RecordingSession/elapsed`` when the UI needs it.
public enum RecordingEvent: Sendable {
    /// The first screen frame arrived; the session clock is at 0.
    case started
    case paused
    case resumed
    /// The source went away (window closed, display unplugged, sharing stopped). The session is being finalised;
    /// ``finished(_:)`` follows.
    case autoStopped(AutoStopReason)
    /// A non-screen stream failed (e.g. microphone encoder); recording continues without it.
    case streamFailed(StreamKind, String)
    /// The recording can't continue. If a package was created it is still finalised; ``finished(_:)`` follows.
    case failed(RecordingError)
    /// Files are closed and `meta.json` is written. Always the last event.
    case finished(RecordingPackage)
}

/// Why a recording stopped on its own.
public enum AutoStopReason: Sendable, Equatable {
    case sourceClosed
    case displayRemoved
    case stoppedByUser
    case stoppedBySystem
    case captureFailed(String)

    init(_ reason: ScreenCaptureStopReason) {
        switch reason {
        case .sourceClosed: self = .sourceClosed
        case .displayRemoved: self = .displayRemoved
        case .stoppedByUser: self = .stoppedByUser
        case .stoppedBySystem: self = .stoppedBySystem
        case .failed(let message): self = .captureFailed(message)
        }
    }
}

/// Errors from RecordingKit.
public enum RecordingError: Error, Sendable, Equatable, LocalizedError {
    /// The call isn't valid in the session's current state.
    case invalidState(String)
    /// Capture couldn't start (permission, source gone, device busy…).
    case captureFailed(String)
    /// No screen frame arrived after starting.
    case noFirstFrame
    case writerFailed(StreamKind, String)
    case packageFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidState(let detail): "Recording can't do that now (\(detail))."
        case .captureFailed(let message): "Capture failed: \(message)"
        case .noFirstFrame: "The screen capture didn't deliver any frames."
        case .writerFailed(let kind, let message): "Writing \(kind.fileName) failed: \(message)"
        case .packageFailed(let message): "Saving the recording failed: \(message)"
        }
    }
}
