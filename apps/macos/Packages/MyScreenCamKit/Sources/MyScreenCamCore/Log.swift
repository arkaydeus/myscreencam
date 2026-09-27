import Foundation
import os

/// Unified-logging loggers, one category per area. View with Console.app or
/// `log stream --predicate 'subsystem BEGINSWITH "com.myscreencam.app"'`.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.myscreencam.app"

    public static let app = Logger(subsystem: subsystem, category: "app")

    /// Signposts for Instruments; wrap capture, append, composite and encode work in intervals.
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
