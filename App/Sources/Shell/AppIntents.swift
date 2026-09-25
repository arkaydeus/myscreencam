import AppIntents

// App Intents for Shortcuts, Spotlight and Siri. They reach the app through the `AppModel` registered with
// `AppDependencyManager` in `MyScreenArtApp.init`, and use only `AppRouter` and the `RecordingController`
// skeleton API.

enum RecordingSourceOption: String, AppEnum {
    case display
    case window
    case region

    nonisolated static let typeDisplayRepresentation: TypeDisplayRepresentation = "Recording Source"
    nonisolated static let caseDisplayRepresentations: [RecordingSourceOption: DisplayRepresentation] = [
        .display: DisplayRepresentation(title: "Display", image: .init(systemName: "display")),
        .window: DisplayRepresentation(title: "Window", image: .init(systemName: "macwindow")),
        .region: DisplayRepresentation(title: "Region", image: .init(systemName: "rectangle.dashed")),
    ]

    var recorderSource: RecorderSourceKind {
        switch self {
        case .display: .display
        case .window: .window
        case .region: .region
        }
    }
}

struct NewRecordingIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "New Recording"
    nonisolated static let description = IntentDescription(
        "Opens the MyScreenArt recorder, optionally on a display, window or region.")
    nonisolated static let openAppWhenRun = true

    @Parameter(title: "Source")
    var source: RecordingSourceOption?

    @Dependency private var model: AppModel

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("New recording of \(\.$source)")
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard !model.recording.isActive else {
            throw IntentError.alreadyRecording
        }
        model.router.showRecorder(source: source?.recorderSource)
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Stop Recording"
    nonisolated static let description = IntentDescription(
        "Finishes the current MyScreenArt recording and opens it in the editor.")

    @Dependency private var model: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        guard model.recording.isActive else { throw IntentError.notRecording }
        await model.recording.stop()
        return .result()
    }
}

struct OpenLibraryIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Open Library"
    nonisolated static let description = IntentDescription("Shows the MyScreenArt recording library.")
    nonisolated static let openAppWhenRun = true

    @Dependency private var model: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        model.router.showLibrary()
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case alreadyRecording
    case notRecording

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .alreadyRecording: "MyScreenArt is already recording."
        case .notRecording: "MyScreenArt isn't recording."
        }
    }
}

struct MyScreenArtShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewRecordingIntent(),
            phrases: [
                "Start a recording in \(.applicationName)",
                "New \(.applicationName) recording",
                "Record \(\.$source) with \(.applicationName)",
            ],
            shortTitle: "New Recording",
            systemImageName: "record.circle")
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Finish \(.applicationName) recording",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle")
        AppShortcut(
            intent: OpenLibraryIntent(),
            phrases: [
                "Open \(.applicationName) library",
                "Show my \(.applicationName) recordings",
            ],
            shortTitle: "Open Library",
            systemImageName: "rectangle.grid.2x2")
    }
}
