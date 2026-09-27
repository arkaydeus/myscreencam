import Foundation

/// Resolves the folder that holds recording packages.
///
/// - `MYSCREENCAM_RECORDINGS_DIR` (absolute path) wins. `mise run run` sets it per worktree.
/// - Release builds use `~/Movies/My Screen Cam`.
/// - Development builds without an override use `~/Movies/My Screen Cam Dev/default`.
public enum RecordingsLocation {
    public static let overrideKey = "MYSCREENCAM_RECORDINGS_DIR"

    public enum ResolutionError: Error, Equatable {
        case relativeOverride(String)
    }

    public static func resolve(
        flavor: AppFlavor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        if let override = environment[overrideKey], !override.isEmpty {
            guard override.hasPrefix("/") else { throw ResolutionError.relativeOverride(override) }
            return URL(filePath: override, directoryHint: .isDirectory).standardizedFileURL
        }

        let movies = homeDirectory.appending(path: "Movies", directoryHint: .isDirectory)
        switch flavor {
        case .release:
            return movies.appending(path: "My Screen Cam", directoryHint: .isDirectory)
        case .development:
            return movies.appending(path: "My Screen Cam Dev/default", directoryHint: .isDirectory)
        }
    }

    /// Resolves the folder and creates it if needed.
    public static func prepare(
        flavor: AppFlavor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = try resolve(flavor: flavor, environment: environment, homeDirectory: homeDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
