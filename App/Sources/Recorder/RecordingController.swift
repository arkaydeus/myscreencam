import AppKit
import CaptureKit
import Foundation
import MyScreenArtCore
import Observation
import ProjectKit
import RecordingKit

extension Notification.Name {
    /// Posted on the main thread when a recording has been saved; `object` is the package URL.
    static let recordingFinished = Notification.Name("MyScreenArtRecordingFinished")
}

/// Recording lifecycle for the whole app: countdown → `RecordingSession` → finish (open the editor) or
/// discard. Also owns the HUD, the countdown overlay and the camera shared with the recorder's preview.
///
/// Other areas rely only on: `state`, `isActive`, `stop()`, `togglePause()`.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        /// `remaining` 3, 2, 1 during the countdown; 0 while the capture starts (until the first frame).
        case countingDown(remaining: Int)
        case recording(startedAt: Date, paused: Bool)
        case stopping
    }

    static let countdownSeconds = 3

    private(set) var state: State = .idle
    let environment: AppEnvironment
    let router: AppRouter
    let preferences = RecorderPreferences()
    /// The camera shared by the recorder preview and the recording.
    let cameraHub = CameraHub()
    /// Whole seconds recorded so far (pauses excluded). Ticks once a second while recording, and not at all
    /// while paused or idle; it drives the menu-bar label and the HUD.
    private(set) var elapsedSeconds = 0

    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// Problems reported during the recording, shown once it has been saved.
    @ObservationIgnored private var notices: [String] = []
    @ObservationIgnored private lazy var hud = RecordingHUD(controller: self)
    @ObservationIgnored private let countdownOverlay = CountdownOverlay()

    init(environment: AppEnvironment, router: AppRouter) {
        self.environment = environment
        self.router = router
        // The recorder opens on the last-used tab unless a menu, URL or intent asks for another.
        router.recorderSourceRequest = preferences.sourceKind
    }

    /// Counting down, recording or stopping.
    var isActive: Bool { state != .idle }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isPaused: Bool {
        if case .recording(_, let paused) = state { return paused }
        return false
    }

    /// Precise session time (pauses excluded). A cheap lock read; call it when needed rather than observing.
    var elapsed: TimeInterval { session?.elapsed ?? 0 }

    // MARK: - Start

    /// Starts the 3-2-1 countdown, then records `preferences.selectedSource`.
    /// - Parameter windowFrame: the chosen window's frame (global points), to centre the countdown on its screen.
    func startRecording(windowFrame: CGRect? = nil) {
        guard state == .idle else { return }
        guard let source = preferences.selectedSource else {
            presentAlert(title: "Choose something to record", message: "Pick a display, a window or a region first.")
            return
        }
        guard Permissions.status(.screenRecording).isGranted else {
            presentPermissionAlert(.screenRecording)
            return
        }
        let root: URL
        switch environment.recordingsRoot {
        case .success(let url): root = url
        case .failure(let error):
            presentAlert(title: "The recordings folder is unavailable", message: error.localizedDescription)
            return
        }

        let options = makeOptions(source: source, root: root)
        let screen = ScreenGeometry.screen(for: source, windowFrame: windowFrame) ?? NSScreen.main
        notices = []
        state = .countingDown(remaining: Self.countdownSeconds)
        countdownOverlay.show(Self.countdownSeconds, on: screen)
        countdownTask = Task { [weak self] in
            for remaining in stride(from: Self.countdownSeconds, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.state = .countingDown(remaining: remaining)
                self.countdownOverlay.update(remaining)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.countdownOverlay.hide()
            self.state = .countingDown(remaining: 0)
            await self.begin(options)
        }
    }

    /// Cancels the countdown (not a capture that is already starting).
    func cancelCountdown() {
        guard case .countingDown(let remaining) = state, remaining > 0 else { return }
        countdownTask?.cancel()
        countdownTask = nil
        countdownOverlay.hide()
        state = .idle
        Log.app.info("Recording countdown cancelled")
    }

    private func makeOptions(source: ScreenSource, root: URL) -> RecordingOptions {
        let devices = CaptureDevices.current()
        let cameraID = preferences.cameraID.flatMap { id in
            Permissions.status(.camera).isGranted && devices.cameras.contains { $0.id == id } ? id : nil
        }
        let microphoneID = preferences.microphoneID.flatMap { id in
            Permissions.status(.microphone).isGranted && devices.microphones.contains { $0.id == id } ? id : nil
        }
        return RecordingOptions(
            source: source, recordingsRoot: root, frameRate: preferences.frameRate,
            hideSystemCursor: preferences.customCursor, captureSystemAudio: preferences.captureSystemAudio,
            microphoneDeviceID: microphoneID, cameraDeviceID: cameraID, videoCodec: preferences.codec,
            recordsInputEvents: true)
    }

    private func begin(_ options: RecordingOptions) async {
        let camera = cameraHub.holdForRecording(deviceID: options.cameraDeviceID)
        let session = RecordingSession(options: options, camera: camera)
        self.session = session
        eventsTask = Task { [weak self] in
            for await event in session.events { self?.handle(event, from: session) }
        }
        do {
            try await session.start()
        } catch {
            Log.app.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            self.session = nil
            eventsTask?.cancel()
            eventsTask = nil
            countdownTask = nil
            cameraHub.releaseFromRecording()
            state = .idle
            presentAlert(title: "The recording couldn't start", message: error.localizedDescription)
            return
        }
        countdownTask = nil
        state = .recording(startedAt: Date(), paused: false)
        elapsedSeconds = 0
        startClock()
        hud.show()
        Log.app.info("Recording started: \(String(describing: options.source), privacy: .public)")
    }

    // MARK: - Pause

    func togglePause() {
        guard case .recording(let startedAt, let paused) = state, let session else { return }
        if paused {
            guard session.resume() else { return }
            state = .recording(startedAt: startedAt, paused: false)
            startClock()
        } else {
            guard session.pause() else { return }
            stopClock()
            elapsedSeconds = Int(session.elapsed)
            state = .recording(startedAt: startedAt, paused: true)
        }
    }

    // MARK: - Stop

    /// Finishes the current recording and opens it in the editor. During the countdown it cancels instead; while
    /// the capture is starting it waits for it and then finishes.
    func stop() async {
        switch state {
        case .idle:
            return
        case .countingDown(let remaining) where remaining > 0:
            cancelCountdown()
            return
        case .countingDown:
            await countdownTask?.value
            guard isRecording else { return }
        case .stopping:
            await finishTask?.value
            return
        case .recording:
            break
        }
        await finish(discard: false)
    }

    /// Stops and moves the new recording to the Trash.
    func discard() async {
        guard isRecording else { return }
        await finish(discard: true)
    }

    private func finish(discard: Bool) async {
        if let finishTask {
            await finishTask.value
            return
        }
        guard let session else { return }
        state = .stopping
        stopClock()
        hud.hide()
        let task = Task { await self.complete(session, discard: discard) }
        finishTask = task
        await task.value
    }

    private func complete(_ session: RecordingSession, discard: Bool) async {
        let result: Result<RecordingPackage, any Error>
        do { result = .success(try await session.stop()) } catch { result = .failure(error) }
        self.session = nil
        finishTask = nil
        eventsTask = nil
        cameraHub.releaseFromRecording()
        elapsedSeconds = 0
        state = .idle
        let notices = notices
        self.notices = []

        switch result {
        case .success(let package) where discard:
            do {
                try RecordingLibrary(root: package.url.deletingLastPathComponent()).delete(package)
                Log.app.info("Recording discarded: \(package.url.lastPathComponent, privacy: .public)")
            } catch {
                presentAlert(title: "The recording couldn't be moved to the Trash", message: error.localizedDescription)
            }
        case .success(let package):
            Log.app.info("Recording saved: \(package.url.path(percentEncoded: false), privacy: .public)")
            NotificationCenter.default.post(name: .recordingFinished, object: package.url)
            router.openEditor(for: package.url)
            if !notices.isEmpty {
                presentAlert(title: "The recording had problems", message: notices.joined(separator: "\n"))
            }
        case .failure(let error):
            Log.app.error("Recording failed to save: \(error.localizedDescription, privacy: .public)")
            let detail = ([error.localizedDescription] + notices).joined(separator: "\n")
            presentAlert(title: "The recording couldn't be saved", message: detail)
        }
    }

    // MARK: - Session events

    private func handle(_ event: RecordingEvent, from session: RecordingSession) {
        guard session === self.session else { return }
        switch event {
        case .started, .finished:
            break
        case .paused, .resumed:
            break  // `togglePause()` already updated the state.
        case .autoStopped(let reason):
            if let notice = Self.notice(for: reason) { notices.append(notice) }
            Task { await self.finish(discard: false) }
        case .streamFailed(let kind, let message):
            Log.app.error("Stream \(kind.fileName, privacy: .public) failed: \(message, privacy: .public)")
            notices.append("\(Self.name(of: kind)) stopped recording: \(message)")
        case .failed(let error):
            notices.append(error.localizedDescription)
            Task { await self.finish(discard: false) }
        }
    }

    private static func notice(for reason: AutoStopReason) -> String? {
        switch reason {
        case .sourceClosed, .stoppedByUser: nil
        case .displayRemoved: "The recording stopped because the display was disconnected."
        case .stoppedBySystem: "macOS stopped the screen capture."
        case .captureFailed(let message): "The screen capture stopped: \(message)"
        }
    }

    private static func name(of kind: StreamKind) -> String {
        switch kind {
        case .screen: "The screen"
        case .webcam: "The camera"
        case .systemAudio: "System audio"
        case .microphone: "The microphone"
        }
    }

    // MARK: - Clock

    /// Updates `elapsedSeconds` on each whole second of session time.
    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = self.elapsed
                let whole = Int(elapsed)
                if whole != self.elapsedSeconds { self.elapsedSeconds = whole }
                let wait = Double(whole + 1) - elapsed + 0.01
                do { try await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(50)) } catch { return }
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }

    // MARK: - Alerts

    private func presentAlert(title: String, message: String) {
        // After the current turn, so an editor window opened just before can order in first.
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            NSApp.activate()
            alert.runModal()
        }
    }

    func presentPermissionAlert(_ kind: PermissionKind) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(kind.title) permission is needed"
            alert.informativeText = kind.explanation
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(kind.settingsURL) }
        }
    }
}

extension PermissionKind {
    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var explanation: String {
        switch self {
        case .screenRecording: "Needed to capture your screen, windows and system audio."
        case .camera: "Needed to record your webcam."
        case .microphone: "Needed to record your voice."
        case .inputMonitoring: "Needed for the custom cursor and click zooms (records pointer movement and clicks)."
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .camera: "video"
        case .microphone: "mic"
        case .inputMonitoring: "cursorarrow.motionlines"
        }
    }
}
