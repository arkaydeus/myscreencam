import AppKit
import CaptureKit
import MyScreenCamCore
import Observation

/// State of the New Recording window while it is visible: sources, thumbnails, devices, permissions, the live
/// camera preview and the mic meter. ``activate()`` starts it when the window appears and ``deactivate()`` stops
/// everything (camera, mic, thumbnail loads, observers) when it goes away, so a closed recorder costs nothing.
///
/// Everything is event-driven: device lists come from `CaptureDevices.changes()`, permissions are re-checked when
/// the app becomes active, displays when the screen configuration changes.
@MainActor
@Observable
final class RecorderWindowModel {
    let controller: RecordingController
    var preferences: RecorderPreferences { controller.preferences }

    private(set) var permissions: [PermissionKind: PermissionStatus] = [:]
    private(set) var displays: [DisplayInfo] = []
    private(set) var windows: [WindowInfo] = []
    private(set) var windowsLoaded = false
    private(set) var windowsError: String?
    private(set) var windowThumbnails: [CGWindowID: NSImage] = [:]
    private(set) var sourcePreview: NSImage?
    private(set) var sourcePreviewError: String?
    private(set) var sourcePreviewLoading = false
    private(set) var cameras: [CameraDevice] = []
    private(set) var microphones: [MicrophoneDevice] = []
    private(set) var micMeterError: String?
    /// Set after a Screen Recording / Input Monitoring request: macOS applies those after a relaunch.
    private(set) var relaunchHint = false

    /// Receives mic levels for the meter's layers (not observed by SwiftUI).
    @ObservationIgnored let meterSink = MicLevelSink()

    @ObservationIgnored private var isActive = false
    /// The mic meter pauses once the capture starts (the recording opens the mic itself).
    @ObservationIgnored private var inputsSuspended = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var devicesTask: Task<Void, Never>?
    @ObservationIgnored private var windowsTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var pendingThumbnails: [CGWindowID] = []
    @ObservationIgnored private var micTask: Task<Void, Never>?
    @ObservationIgnored private var micMonitor: MicLevelMonitor?
    @ObservationIgnored private var micDeviceShown: String?
    @ObservationIgnored private var micGeneration = 0
    @ObservationIgnored private let systemPicker = SystemContentPicker()

    init(controller: RecordingController) {
        self.controller = controller
    }

    // MARK: - Lifecycle

    func activate() {
        guard !isActive else { return }
        Log.app.debug("Recorder window active")
        isActive = true
        inputsSuspended = false
        refreshPermissions()
        refreshDisplays()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.appBecameActive() }
            },
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDisplays() } },
        ]
        devicesTask = Task { [weak self] in
            for await list in CaptureDevices.changes() {
                self?.devicesChanged(list)
            }
        }
        if preferences.sourceKind == .window { refreshWindows() }
        refreshSourcePreview()
    }

    func deactivate() {
        guard isActive else { return }
        Log.app.debug("Recorder window inactive")
        isActive = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        devicesTask?.cancel()
        devicesTask = nil
        windowsTask?.cancel()
        windowsTask = nil
        previewTask?.cancel()
        previewTask = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        pendingThumbnails = []
        windowThumbnails = [:]
        sourcePreview = nil
        updateCameraPreview()
        updateMicMeter()
    }

    /// Called once the capture is starting: the mic meter lets go of the microphone.
    func suspendLiveInputs() {
        guard !inputsSuspended else { return }
        inputsSuspended = true
        updateMicMeter()
    }

    func resumeLiveInputs() {
        guard inputsSuspended else { return }
        inputsSuspended = false
        updateMicMeter()
    }

    private func appBecameActive() {
        let before = permissions
        refreshPermissions()
        guard permissions != before else { return }
        if permissions[.screenRecording] != before[.screenRecording] {
            if preferences.sourceKind == .window { refreshWindows() }
            refreshSourcePreview()
        }
        updateCameraPreview()
        updateMicMeter()
    }

    // MARK: - Permissions

    func status(_ kind: PermissionKind) -> PermissionStatus { permissions[kind] ?? .denied }
    func isGranted(_ kind: PermissionKind) -> Bool { status(kind).isGranted }

    var missingPermissions: [PermissionKind] { PermissionKind.allCases.filter { !isGranted($0) } }

    func refreshPermissions() {
        var statuses: [PermissionKind: PermissionStatus] = [:]
        for kind in PermissionKind.allCases { statuses[kind] = Permissions.status(kind) }
        if statuses != permissions { permissions = statuses }
    }

    /// Asks for a permission (shows the system prompt the first time), then re-checks.
    func request(_ kind: PermissionKind) async {
        let result = await Permissions.request(kind)
        Log.app.info("Permission \(kind.rawValue, privacy: .public) request: \(result.rawValue, privacy: .public)")
        if kind == .screenRecording || kind == .inputMonitoring, !result.isGranted { relaunchHint = true }
        appBecameActive()
    }

    func openSettings(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    // MARK: - Sources

    func selectSourceKind(_ kind: RecorderSourceKind) {
        guard preferences.sourceKind != kind else { return }
        preferences.sourceKind = kind
        controller.router.recorderSourceRequest = kind
        if kind == .window, !windowsLoaded { refreshWindows() }
        refreshSourcePreview()
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        preferences.displayID = id
        refreshSourcePreview()
    }

    func selectWindow(_ id: CGWindowID) {
        preferences.windowID = id
        refreshSourcePreview()
    }

    func setRegion(_ region: RecorderPreferences.Region) {
        preferences.region = region
        refreshSourcePreview()
    }

    var selectedWindow: WindowInfo? {
        guard let id = preferences.windowID else { return nil }
        return windows.first { $0.id == id }
    }

    /// Whether Start can be pressed, and if not, why.
    var startBlocker: String? {
        guard isGranted(.screenRecording) else { return "Screen Recording permission is needed." }
        switch preferences.sourceKind {
        case .display:
            guard let id = preferences.displayID, displays.contains(where: { $0.id == id }) else {
                return "Choose a display."
            }
        case .window:
            guard selectedWindow != nil else { return "Choose a window." }
        case .region:
            guard let region = preferences.region, displays.contains(where: { $0.id == region.displayID }) else {
                return "Select a region."
            }
        }
        return nil
    }

    func startRecording() {
        controller.startRecording(windowFrame: preferences.sourceKind == .window ? selectedWindow?.frame : nil)
    }

    private func refreshDisplays() {
        displays = ScreenGeometry.displays()
        if preferences.displayID.map({ id in !displays.contains { $0.id == id } }) ?? true {
            if let main = displays.first { preferences.displayID = main.id }
        }
    }

    /// Reloads the window list (needs Screen Recording; never called without it, so it can't prompt).
    func refreshWindows() {
        guard isActive, isGranted(.screenRecording) else { return }
        windowsTask?.cancel()
        windowThumbnails = [:]
        pendingThumbnails = []
        windowsTask = Task { [weak self] in
            do {
                let windows = try await CaptureSources.windows()
                guard let self, !Task.isCancelled else { return }
                self.windows = windows
                self.windowsError = nil
                self.windowsLoaded = true
                if self.preferences.sourceKind == .window { self.refreshSourcePreview() }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.windowsError = error.localizedDescription
                Log.app.error("Window list failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Queues a small thumbnail for a window row (loaded one at a time, off the main thread).
    func requestThumbnail(for id: CGWindowID) {
        guard isActive, isGranted(.screenRecording), windowThumbnails[id] == nil, !pendingThumbnails.contains(id)
        else { return }
        pendingThumbnails.append(id)
        guard thumbnailTask == nil else { return }
        thumbnailTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pendingThumbnails.isEmpty {
                let id = self.pendingThumbnails.removeFirst()
                if let image = try? await CaptureSources.thumbnail(of: .window(id), maxPixelWidth: 160),
                    !Task.isCancelled
                {
                    self.windowThumbnails[id] = NSImage(cgImage: image, size: .zero)
                }
            }
            self?.thumbnailTask = nil
        }
    }

    /// Takes a new still of the selected source.
    func refreshSourcePreview() {
        previewTask?.cancel()
        guard isActive, isGranted(.screenRecording), let source = preferences.selectedSource else {
            sourcePreview = nil
            sourcePreviewLoading = false
            return
        }
        if case .window(let id) = source, windowsLoaded, !windows.contains(where: { $0.id == id }) {
            sourcePreview = nil
            return
        }
        sourcePreviewLoading = true
        previewTask = Task { [weak self] in
            do {
                let image = try await CaptureSources.thumbnail(of: source, maxPixelWidth: 720)
                guard let self, !Task.isCancelled else { return }
                self.sourcePreview = NSImage(cgImage: image, size: .zero)
                self.sourcePreviewError = nil
                self.sourcePreviewLoading = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.sourcePreview = nil
                self.sourcePreviewError = error.localizedDescription
                self.sourcePreviewLoading = false
            }
        }
    }

    func chooseWithSystemPicker() {
        systemPicker.present { [weak self] source in
            guard let self, let source else { return }
            switch source {
            case .display(let id):
                self.selectSourceKind(.display)
                self.selectDisplay(id)
            case .window(let id):
                self.selectSourceKind(.window)
                self.preferences.windowID = id
                self.refreshWindows()
            case .region:
                break
            }
        }
    }

    func selectRegion(startRecordingWhenDone: Bool = false) {
        RegionSelectionOverlay.present(initial: preferences.region) { [weak self] outcome in
            guard let self, case .selected(let region, let start) = outcome else { return }
            self.selectSourceKind(.region)
            self.setRegion(region)
            if start || startRecordingWhenDone { self.startRecording() }
        }
    }

    // MARK: - Devices

    /// The saved camera, if it is connected.
    var selectedCamera: CameraDevice? {
        preferences.cameraID.flatMap { id in cameras.first { $0.id == id } }
    }

    var selectedMicrophone: MicrophoneDevice? {
        preferences.microphoneID.flatMap { id in microphones.first { $0.id == id } }
    }

    /// The saved camera's name when it isn't connected.
    var disconnectedCamera: String? {
        guard preferences.cameraID != nil, selectedCamera == nil else { return nil }
        return preferences.cameraName ?? "The selected camera"
    }

    var disconnectedMicrophone: String? {
        guard preferences.microphoneID != nil, selectedMicrophone == nil else { return nil }
        return preferences.microphoneName ?? "The selected microphone"
    }

    func selectCamera(_ id: String?) {
        preferences.selectCamera(id.flatMap { id in cameras.first { $0.id == id } })
        updateCameraPreview()
    }

    func selectMicrophone(_ id: String?) {
        preferences.selectMicrophone(id.flatMap { id in microphones.first { $0.id == id } })
        updateMicMeter()
    }

    private func devicesChanged(_ list: CaptureDeviceList) {
        cameras = list.cameras
        microphones = list.microphones
        // A device can come back with a new uniqueID (e.g. Continuity Camera): find it by name.
        if let id = preferences.cameraID, !cameras.contains(where: { $0.id == id }),
            let name = preferences.cameraName, let match = cameras.first(where: { $0.name == name })
        {
            preferences.selectCamera(match)
        }
        if let id = preferences.microphoneID, !microphones.contains(where: { $0.id == id }),
            let name = preferences.microphoneName, let match = microphones.first(where: { $0.name == name })
        {
            preferences.selectMicrophone(match)
        }
        updateCameraPreview()
        updateMicMeter()
    }

    private func updateCameraPreview() {
        let wanted = isActive && isGranted(.camera) ? selectedCamera?.id : nil
        controller.cameraHub.setPreview(deviceID: wanted)
    }

    // MARK: - Mic meter

    private func updateMicMeter() {
        let wanted = isActive && !inputsSuspended && isGranted(.microphone) ? selectedMicrophone?.id : nil
        guard wanted != micDeviceShown else { return }
        micDeviceShown = wanted
        micGeneration += 1
        let generation = micGeneration
        let old = micMonitor
        micMonitor = nil
        micMeterError = nil
        meterSink.reset()
        micTask?.cancel()
        micTask = Task { [weak self] in
            if let old { await old.stop() }
            guard let wanted else { return }
            let monitor: MicLevelMonitor
            do { monitor = try await Self.openMonitor(wanted) } catch {
                guard let self, self.micGeneration == generation else { return }
                self.micMeterError = error.localizedDescription
                return
            }
            guard let self, self.micGeneration == generation, !Task.isCancelled else {
                await monitor.stop()
                return
            }
            self.micMonitor = monitor
            let levels = await monitor.start()
            guard self.micGeneration == generation else {
                await monitor.stop()
                return
            }
            for await level in levels { self.meterSink.update(level) }
        }
    }

    /// Opening the device blocks for a moment: do it off the main thread.
    @concurrent
    nonisolated private static func openMonitor(_ deviceID: String) async throws -> MicLevelMonitor {
        try MicLevelMonitor(deviceID: deviceID)
    }
}
