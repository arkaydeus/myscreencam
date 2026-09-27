import Foundation
import MyScreenArtCore
import Observation
import ProjectKit
import SwiftUI

/// The defaults for new recordings (Settings › Defaults), persisted as JSON in `UserDefaults`.
///
/// A recording takes them when its first edit is made: when it's first opened, exported from the Library or given
/// subtitles before it has an `edit.json`. Readers that only need the current value call ``load(from:)``.
@MainActor
@Observable
final class ProjectDefaultsStore {
    static let key = "projectDefaults"
    /// The "Create zooms from clicks" preference from before Settings › Defaults, read once as a migration.
    static let legacyAutoZoomKey = "autoZoomFromClicks"

    @ObservationIgnored private let userDefaults: UserDefaults

    var defaults: ProjectDefaults {
        didSet {
            guard defaults != oldValue else { return }
            Self.save(defaults, to: userDefaults)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        defaults = Self.load(from: userDefaults)
    }

    func resetToBuiltIn() {
        defaults = ProjectDefaults()
    }

    static func load(from userDefaults: UserDefaults = .standard) -> ProjectDefaults {
        if let data = userDefaults.data(forKey: key) {
            do {
                return try JSONDecoder().decode(ProjectDefaults.self, from: data)
            } catch {
                Log.app.error("Couldn't read the defaults for new recordings: \(error)")
            }
        }
        var defaults = ProjectDefaults()
        if let autoZoom = userDefaults.object(forKey: legacyAutoZoomKey) as? Bool { defaults.autoZoom = autoZoom }
        return defaults
    }

    private static func save(_ defaults: ProjectDefaults, to userDefaults: UserDefaults) {
        do {
            userDefaults.set(try JSONEncoder().encode(defaults), forKey: key)
        } catch {
            Log.app.error("Couldn't save the defaults for new recordings: \(error)")
        }
    }
}

extension ProjectDefaultsStore: SubtitleStyleSource {
    var subtitleSettings: SubtitleSettings { defaults.subtitles }
    var subtitleCues: [SubtitleCue] { [] }

    func subtitleBinding<V: Equatable>(_ keyPath: WritableKeyPath<SubtitleSettings, V>, _ action: String) -> Binding<V>
    {
        Binding(
            get: { self.defaults.subtitles[keyPath: keyPath] },
            set: { self.defaults.subtitles[keyPath: keyPath] = $0 })
    }

    func subtitleColorBinding(
        _ keyPath: WritableKeyPath<SubtitleSettings, RGBAColor>, _ action: String
    ) -> Binding<Color> {
        Binding(
            get: { self.defaults.subtitles[keyPath: keyPath].color },
            set: { color in
                let value = RGBAColor(color)
                guard value.hex != self.defaults.subtitles[keyPath: keyPath].hex else { return }
                self.defaults.subtitles[keyPath: keyPath] = value
            })
    }

    func editingChanged(_ editing: Bool) {}
}
