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
        try migrateLegacyRecordings(
            to: url, flavor: flavor,
            homeDirectory: homeDirectory, fileManager: fileManager)
        return url
    }
    /// Move legacy packages into the selected root. Existing files always win, so a retry is safe after a crash.
    public static func migrateLegacyRecordings(
        to destination: URL, flavor: AppFlavor,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let movies = homeDirectory.appending(path: "Movies", directoryHint: .isDirectory)
        let legacyRoot: URL
        switch flavor {
        case .release:
            guard destination == movies.appending(path: "My Screen Cam", directoryHint: .isDirectory) else { return }
            legacyRoot = movies.appending(path: "MyScreenArt", directoryHint: .isDirectory)
        case .development:
            // run.sh uses the same worktree hash for both names. A plain Dev launch uses `default`.
            let expectedParent = movies.appending(path: "My Screen Cam Dev", directoryHint: .isDirectory)
            guard destination.deletingLastPathComponent() == expectedParent else { return }
            legacyRoot = movies.appending(path: "MyScreenArt Dev", directoryHint: .isDirectory)
                .appending(path: destination.lastPathComponent, directoryHint: .isDirectory)
        }
        guard legacyRoot.standardizedFileURL != destination.standardizedFileURL,
            fileManager.fileExists(atPath: legacyRoot.path)
        else { return }
        let entries = try fileManager.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil)
        for source in entries where ["msarec", "mscam"].contains(source.pathExtension.lowercased()) {
            let target = destination.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.moveItem(at: source, to: target)
        }
    }
}
