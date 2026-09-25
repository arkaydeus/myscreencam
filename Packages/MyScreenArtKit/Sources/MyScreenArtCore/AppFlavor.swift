/// Which build of the app is running. Debug builds use a `.dev` bundle identifier (see `project.yml`),
/// so they keep their own TCC grants, URL scheme and recordings folder.
public enum AppFlavor: Sendable, Equatable {
    case development
    case release

    public init(bundleIdentifier: String?) {
        self = bundleIdentifier?.hasSuffix(".dev") == true ? .development : .release
    }
}
