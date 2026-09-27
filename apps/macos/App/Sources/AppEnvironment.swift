import Foundation
import MyScreenCamCore
import Observation

/// Process-wide facts resolved once at launch.
@Observable
final class AppEnvironment {
    let flavor: AppFlavor
    let recordingsRoot: Result<URL, any Error>

    init(flavor: AppFlavor, recordingsRoot: Result<URL, any Error>) {
        self.flavor = flavor
        self.recordingsRoot = recordingsRoot
    }

    static func live(bundle: Bundle = .main) -> AppEnvironment {
        let flavor = AppFlavor(bundleIdentifier: bundle.bundleIdentifier)
        if let bundleIdentifier = bundle.bundleIdentifier {
            do { try LegacyStateMigration.migrate(bundleIdentifier: bundleIdentifier) } catch {
                Log.app.error("Legacy settings migration failed: \(error, privacy: .public)")
            }
        }
        let root = Result { try RecordingsLocation.prepare(flavor: flavor) }
        switch root {
        case .success(let url): Log.app.info("Recordings root: \(url.path(), privacy: .public)")
        case .failure(let error): Log.app.error("Recordings root unavailable: \(error, privacy: .public)")
        }
        return AppEnvironment(flavor: flavor, recordingsRoot: root)
    }
}
