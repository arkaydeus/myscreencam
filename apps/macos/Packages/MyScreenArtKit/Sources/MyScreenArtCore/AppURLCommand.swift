import Foundation

/// A command received through the app's URL scheme (`myscreenart://` in release builds,
/// `myscreenart-dev://` in debug builds).
///
/// The action is the URL's host (`myscreenart://record`) or, when there is no host, its first path
/// component (`myscreenart:record`, `myscreenart:///record`). Matching is case-insensitive.
///
/// | Action | Command |
/// |---|---|
/// | `record`, `new-recording` | ``newRecording(source:)`` with no source |
/// | `display`, `record-display` | ``newRecording(source:)`` with ``Source/display`` |
/// | `window`, `record-window` | ``newRecording(source:)`` with ``Source/window`` |
/// | `region`, `record-region` | ``newRecording(source:)`` with ``Source/region`` |
/// | `projects`, `show-projects`, `library` | ``showLibrary`` |
/// | `stop`, `finish` | ``finishRecording`` |
public enum AppURLCommand: Sendable, Equatable {
    /// Which source tab the recorder should show.
    public enum Source: String, Sendable, CaseIterable {
        case display
        case window
        case region
    }

    case newRecording(source: Source?)
    case showLibrary
    case finishRecording

    /// Parses `url`. Returns nil for an unknown action, or when `allowedSchemes` is given and doesn't
    /// contain the URL's scheme (compared case-insensitively).
    public static func parse(_ url: URL, allowedSchemes: Set<String>? = nil) -> AppURLCommand? {
        if let allowedSchemes {
            guard let scheme = url.scheme?.lowercased(),
                allowedSchemes.contains(where: { $0.lowercased() == scheme })
            else { return nil }
        }
        guard let action = action(of: url) else { return nil }
        return command(forAction: action)
    }

    /// Maps a bare action name (see the table above) to a command.
    public static func command(forAction action: String) -> AppURLCommand? {
        switch action.lowercased() {
        case "record", "new-recording": .newRecording(source: nil)
        case "display", "record-display": .newRecording(source: .display)
        case "window", "record-window": .newRecording(source: .window)
        case "region", "record-region": .newRecording(source: .region)
        case "projects", "show-projects", "library": .showLibrary
        case "stop", "finish": .finishRecording
        default: nil
        }
    }

    private static func action(of url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let host = components?.host, !host.isEmpty { return host }
        let path = components?.path ?? url.path
        return path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
    }
}
