import CaptureKit
import MyScreenCamCore
import Observation

/// Owns the one open camera, shared by the recorder's live preview and the recording (so the device isn't
/// opened twice and the preview runs straight into the recording).
///
/// The camera runs while the preview wants it (recorder window visible) or a recording holds it, and stops
/// as soon as neither does. Opening, starting and stopping happen off the main thread, in order.
@MainActor
@Observable
final class CameraHub {
    /// The open camera, for `AVCaptureVideoPreviewLayer(session:)`.
    private(set) var camera: CameraCapture?
    /// Why the preview camera couldn't be opened, for the recorder UI.
    private(set) var failure: String?

    @ObservationIgnored private var previewDeviceID: String?
    @ObservationIgnored private var heldForRecording = false
    /// The device being opened or open (`camera` is set once it has opened).
    @ObservationIgnored private var targetDeviceID: String?
    /// Open/start/stop run in order: `startRunning`/`stopRunning` block on the session queue.
    @ObservationIgnored private var lastTransition: Task<Void, Never>?

    /// The recorder window's wish: preview this device, or nothing (window hidden, "None", no permission).
    func setPreview(deviceID: String?) {
        previewDeviceID = deviceID
        reconcile()
    }

    /// Called when a recording starts: returns the running camera if it is `deviceID`, and keeps it open
    /// until ``releaseFromRecording()`` even if the preview goes away.
    func holdForRecording(deviceID: String?) -> CameraCapture? {
        guard let deviceID, let camera, camera.configuration.deviceID == deviceID else { return nil }
        heldForRecording = true
        return camera
    }

    func releaseFromRecording() {
        guard heldForRecording else { return }
        heldForRecording = false
        reconcile()
    }

    private func reconcile() {
        let wanted = heldForRecording ? targetDeviceID : previewDeviceID
        guard wanted != targetDeviceID else { return }
        targetDeviceID = wanted
        failure = nil
        if let old = camera {
            camera = nil
            transition { await old.stopRunning() }
        }
        guard let wanted else { return }
        transition { [weak self] in
            let result = Result { try CameraCapture(configuration: CameraConfiguration(deviceID: wanted)) }
            let camera = try? result.get()
            let current = await self?.opened(result, deviceID: wanted) ?? false
            if current { await camera?.startRunning() }
        }
    }

    /// Publishes an opened camera; returns false (and drops it) if the wish changed while it was opening.
    private func opened(_ result: Result<CameraCapture, any Error>, deviceID: String) -> Bool {
        guard targetDeviceID == deviceID else { return false }
        switch result {
        case .success(let camera):
            self.camera = camera
            return true
        case .failure(let error):
            failure = error.localizedDescription
            Log.app.error("Camera unavailable: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func transition(_ work: @escaping @Sendable () async -> Void) {
        let previous = lastTransition
        lastTransition = Task.detached(priority: .userInitiated) {
            await previous?.value
            await work()
        }
    }
}
