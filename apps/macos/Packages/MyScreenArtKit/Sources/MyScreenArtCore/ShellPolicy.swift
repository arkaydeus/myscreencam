import Foundation

/// Whether the app shows a Dock icon. Mirrors `NSApplication.ActivationPolicy.regular` / `.accessory`.
public enum DockIconPolicy: Sendable, Equatable {
    case regular
    case accessory

    /// "Hide Dock icon when idle": the icon goes away only when the preference is on, no window is
    /// visible (minimised windows count as visible) and nothing is recording.
    public static func resolve(hideWhenIdle: Bool, hasVisibleWindows: Bool, isRecording: Bool) -> DockIconPolicy {
        hideWhenIdle && !hasVisibleWindows && !isRecording ? .accessory : .regular
    }
}

/// What must be resolved before the app may quit. A recording takes precedence over a running export.
public enum QuitGuard: Sendable, Equatable {
    case none
    case recording
    case exporting

    public static func resolve(isRecording: Bool, isExporting: Bool) -> QuitGuard {
        if isRecording { return .recording }
        if isExporting { return .exporting }
        return .none
    }
}

/// Sparkle update configuration checks.
public enum UpdateConfiguration {
    /// Placeholder value of `SPARKLE_PUBLIC_ED_KEY` in `project.yml` until a real key is generated.
    public static let publicKeyPlaceholder = "SPARKLE_PUBLIC_ED_KEY_NOT_SET"

    /// True when `key` is a base64 Ed25519 public key (32 bytes). Sparkle refuses to start without one,
    /// so the app only starts its updater when this holds.
    public static func isValidEdDSAPublicKey(_ key: String?) -> Bool {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
            key != publicKeyPlaceholder, let data = Data(base64Encoded: key)
        else { return false }
        return data.count == 32
    }
}
