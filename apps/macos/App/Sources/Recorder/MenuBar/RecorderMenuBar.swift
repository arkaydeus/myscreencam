import AppKit
import SwiftUI

/// The menu-bar extra's menu.
struct RecorderMenuBarContent: View {
    @Environment(AppModel.self) private var model

    private var recording: RecordingController { model.recording }

    var body: some View {
        switch recording.state {
        case .idle:
            Button("New Recording…") { model.router.showRecorder() }
            Divider()
            Button("Record Display") { model.router.showRecorder(source: .display) }
            Button("Record Window") { model.router.showRecorder(source: .window) }
            Button("Record Region") { model.router.showRecorder(source: .region) }
        case .countingDown(let remaining):
            Text(remaining > 0 ? "Recording in \(remaining)…" : "Starting…")
            if remaining > 0 {
                Button("Cancel Countdown") { recording.cancelCountdown() }
            }
        case .recording(_, let paused):
            Text("\(paused ? "Paused" : "Recording") — \(formatElapsed(recording.elapsedSeconds))")
            Button(paused ? "Resume Recording" : "Pause Recording") { recording.togglePause() }
            Button("Finish Recording") { Task { await recording.stop() } }
        case .stopping:
            Text("Saving recording…")
        }
        Divider()
        Button("Show Library") { model.router.showLibrary() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit My Screen Cam") { NSApp.terminate(nil) }
    }
}

/// The menu-bar icon: the app's record icon when idle; a red record dot and the elapsed time while recording
/// (orange pause icon while paused). The time comes from `RecordingController.elapsedSeconds`, which only ticks
/// once a second while recording.
struct RecorderMenuBarLabel: View {
    let recording: RecordingController

    var body: some View {
        switch recording.state {
        case .recording(_, let paused):
            HStack(spacing: 4) {
                Image(nsImage: paused ? Self.pausedImage : Self.recordingImage)
                Text(formatElapsed(recording.elapsedSeconds)).monospacedDigit()
            }
            .accessibilityLabel(paused ? "My Screen Cam — Paused" : "My Screen Cam — Recording")
        case .countingDown, .stopping:
            Image(nsImage: Self.recordingImage)
                .accessibilityLabel("My Screen Cam — Recording")
        case .idle:
            Image(systemName: "record.circle")
                .accessibilityLabel("My Screen Cam")
        }
    }

    /// Coloured symbols: non-template images keep their colour in the menu bar.
    private static let recordingImage = coloredSymbol("record.circle.fill", color: .systemRed)
    private static let pausedImage = coloredSymbol("pause.circle.fill", color: .systemOrange)

    private static func coloredSymbol(_ name: String, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image =
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}
