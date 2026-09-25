import ProjectKit

/// Diagnostics counters.
public struct RecordingStatistics: Sendable, Equatable {
    public struct Stream: Sendable, Equatable {
        /// Buffers handed to the encoder.
        public var appended: Int
        /// Buffers dropped because the encoder wasn't ready, arrived out of order, or the writer had failed.
        public var dropped: Int
    }

    /// Per stream file.
    public var streams: [StreamKind: Stream]
    public var eventsWritten: Int
    /// Idle (unchanged) screen frames ScreenCaptureKit reported and we skipped.
    public var idleFramesSkipped: Int
    /// Frames the camera discarded before we saw them.
    public var cameraFramesDiscarded: Int
}
