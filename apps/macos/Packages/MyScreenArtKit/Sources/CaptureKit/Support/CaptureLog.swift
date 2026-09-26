import MyScreenArtCore
import os

/// Loggers for the capture layer. Hot paths use `Log.signposter` intervals so Instruments can measure them.
enum CaptureLog {
    static let capture = Logger(subsystem: Log.subsystem, category: "capture")
    static let input = Logger(subsystem: Log.subsystem, category: "input")
    static let cursor = Logger(subsystem: Log.subsystem, category: "cursor")
    static let devices = Logger(subsystem: Log.subsystem, category: "devices")
}
