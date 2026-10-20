import AVFoundation
import CaptureKit
import CoreGraphics
import Foundation
import MyScreenCamCore
import ProjectKit

/// One recording: screen (+ system audio, microphone, webcam, pointer events and cursor images) into a new
/// `.mscam` package.
///
/// ```swift
/// let session = RecordingSession(options: options, camera: previewCamera)
/// Task { for await event in session.events { … } }
/// try await session.start()        // returns once the first frame is recorded
/// session.pause(); session.resume()
/// let package = try await session.stop()
/// ```
///
/// Why a `final class` with locks rather than an actor: sample buffers arrive synchronously on capture queues
/// at up to 60 fps per stream and must be routed without an executor hop per buffer (and `CMSampleBuffer`
/// isn't `Sendable`). The hot path touches only a lock-protected clock and hands buffers to per-writer serial
/// queues. Lifecycle calls are serialised by an explicit state machine, and ``elapsed``/``state`` are
/// synchronous so the UI can read them from a display-link or timer without `await`.
///
/// Single use: after ``stop()`` (or a failed ``start()``), create a new session.
public final class RecordingSession: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case starting
        case recording
        case paused
        case stopping
        case finished
        case failed
    }

    public let options: RecordingOptions
    /// Lifecycle events. Single consumer; finishes after ``RecordingEvent/finished(_:)`` or a failed start.
    public let events: AsyncStream<RecordingEvent>

    private let continuation: AsyncStream<RecordingEvent>.Continuation
    private let sharedCamera: CameraCapture?
    private let lock = NSLock()
    private var currentState: State = .idle
    private var recordingPackage: RecordingPackage?
    private var pipeline: RecordingPipeline?
    private var screen: ScreenCapture?
    private var camera: CameraCapture?
    private var ownsCamera = false
    private var microphone: MicrophoneCapture?
    private var tap: InputEventTap?
    private var cursors: CursorImageTracker?
    private var activity: (any NSObjectProtocol)?
    private var stopTask: Task<RecordingPackage, any Error>?
    private var firstFrameGate: FirstFrameGate?
    private var startupFailure: RecordingError?

    /// - Parameters:
    ///   - camera: a running preview camera to reuse for recording (it keeps running afterwards). If nil, or for a
    ///     different device than `options.cameraDeviceID`, the session opens its own.
    public init(options: RecordingOptions, camera: CameraCapture? = nil) {
        self.options = options
        self.sharedCamera = camera
        (events, continuation) = AsyncStream.makeStream(of: RecordingEvent.self)
    }

    public var state: State { lock.withLock { currentState } }

    /// The package being written (set once ``start()`` has created it).
    public var package: RecordingPackage? { lock.withLock { recordingPackage } }

    /// Session time in seconds: excludes pauses, frozen while paused, 0 before the first frame.
    public var elapsed: TimeInterval {
        lock.withLock { pipeline }?.elapsed(atHostTime: HostClock.now()) ?? 0
    }

    public var statistics: RecordingStatistics {
        let (pipeline, screen, camera) = lock.withLock { (self.pipeline, self.screen, self.camera) }
        return RecordingStatistics(
            streams: pipeline?.streamStatistics ?? [:], eventsWritten: pipeline?.eventsWritten ?? 0,
            idleFramesSkipped: screen?.statistics.idleFramesSkipped ?? 0,
            cameraFramesDiscarded: camera?.droppedFrames ?? 0)
    }

    // MARK: - Lifecycle

    /// Creates the package, starts every stream and returns once the first screen frame has been recorded.
    /// On failure everything started is torn down, the empty package is removed and the error is rethrown.
    public func start() async throws {
        try lock.withLock {
            guard currentState == .idle else { throw RecordingError.invalidState("start while \(currentState)") }
            currentState = .starting
        }
        do {
            try await startStreams()
            try lock.withLock {
                if let startupFailure { throw startupFailure }
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording the screen")
                currentState = .recording
            }
        } catch {
            await stopStreams()
            _ = await lock.withLock({ cursors })?.finish()
            if let package = lock.withLock({ recordingPackage }) {
                try? FileManager.default.removeItem(at: package.url)
            }
            lock.withLock {
                currentState = .failed
                recordingPackage = nil
                firstFrameGate = nil
            }
            continuation.finish()
            throw (error as? RecordingError) ?? RecordingError.captureFailed(error.localizedDescription)
        }
        continuation.yield(.started)
    }

    /// Pauses: samples are dropped until ``resume()``. Returns false if not recording.
    @discardableResult
    public func pause() -> Bool {
        let paused = lock.withLock {
            guard currentState == .recording, pipeline?.pause(atHostTime: HostClock.now()) == true else { return false }
            currentState = .paused
            return true
        }
        if paused { continuation.yield(.paused) }
        return paused
    }

    /// Resumes after ``pause()``. Returns false if not paused.
    @discardableResult
    public func resume() -> Bool {
        let resumed = lock.withLock {
            guard currentState == .paused, pipeline?.resume(atHostTime: HostClock.now()) == true else { return false }
            currentState = .recording
            return true
        }
        if resumed { continuation.yield(.resumed) }
        return resumed
    }

    /// Stops every stream, finalises the files and writes `meta.json` and `cursors/index.json` (not
    /// `edit.json`, which the editor creates). Concurrent or repeated calls share one result.
    public func stop() async throws -> RecordingPackage {
        let task: Task<RecordingPackage, any Error> = try lock.withLock {
            if let stopTask { return stopTask }
            guard currentState == .recording || currentState == .paused else {
                throw RecordingError.invalidState("stop while \(currentState)")
            }
            currentState = .stopping
            let task = Task { try await self.finalize() }
            stopTask = task
            return task
        }
        return try await task.value
    }

    // MARK: - Start

    private func startStreams() async throws {
        let options = options
        let listenAccess = CGPreflightListenEventAccess()
        let recordsPointer = options.recordsInputEvents && listenAccess
        let hidesCursor = options.hideSystemCursor && listenAccess
        if options.hideSystemCursor && !listenAccess {
            Log.app.notice("Input Monitoring not granted: keeping the system cursor in the capture")
        }

        let screen = ScreenCapture(
            configuration: ScreenCaptureConfiguration(
                source: options.source, frameRate: options.frameRate, showsCursor: !hidesCursor,
                capturesSystemAudio: options.captureSystemAudio,
                microphoneDeviceID: options.microphoneBackend == .screenCaptureKit ? options.microphoneDeviceID : nil,
                excludesOwnApplication: options.excludesOwnApplication))
        lock.withLock { self.screen = screen }
        let geometry: ScreenCaptureGeometry
        do { geometry = try await screen.prepare() } catch {
            throw RecordingError.captureFailed(error.localizedDescription)
        }

        let camera = try openCamera()
        let microphone =
            try options.microphoneBackend == .captureSession
            ? options.microphoneDeviceID.map { try MicrophoneCapture(deviceID: $0) } : nil
        lock.withLock { self.microphone = microphone }

        let createdAt = Date()
        let id = UUID()
        let package: RecordingPackage
        do { package = try RecordingPackage.create(in: options.recordingsRoot, date: createdAt, id: id) } catch {
            throw RecordingError.packageFailed(error.localizedDescription)
        }
        lock.withLock { recordingPackage = package }

        let configuration = RecordingPipelineConfiguration(
            package: package, id: id, name: options.name ?? RecordingOptions.defaultName(for: createdAt),
            createdAt: createdAt, source: await captureSource(geometry: geometry),
            screen: ScreenStreamInfo(
                pixelWidth: geometry.pixelWidth, pixelHeight: geometry.pixelHeight, scale: geometry.scale,
                frameRate: options.frameRate, codec: options.videoCodec.fourCC,
                contentRectPoints: RectPoints(geometry.contentRect)),
            webcam: camera.map {
                WebcamStreamInfo(
                    deviceID: $0.format.deviceID, name: $0.format.name, pixelWidth: $0.format.width,
                    pixelHeight: $0.format.height, frameRate: $0.format.frameRate)
            },
            microphone: options.microphoneDeviceID.map { AudioDeviceInfo(deviceID: $0, name: Self.microphoneName($0)) },
            capturesSystemAudio: options.captureSystemAudio, systemCursorHidden: hidesCursor,
            codec: options.videoCodec, recordsEvents: recordsPointer,
            appVersion: RecordingMetaBuilder.appVersion())
        let pipeline = try RecordingPipeline(configuration: configuration) { [weak self] kind, message in
            self?.streamFailed(kind, message)
        }
        lock.withLock { self.pipeline = pipeline }

        if recordsPointer { await startPointerTracking(package: package, geometry: geometry, pipeline: pipeline) }

        if let camera {
            camera.setSampleHandler { pipeline.append($0, to: .webcam) }
            if !camera.isRunning { await camera.startRunning() }
        }
        if let microphone { await microphone.start { pipeline.append($0, to: .microphone) } }

        let firstFrame = FirstFrameGate()
        lock.withLock { firstFrameGate = firstFrame }
        pipeline.onFirstFrame { firstFrame.open() }
        do {
            try await screen.start(
                onSample: { buffer, output in
                    switch output {
                    case .video: pipeline.appendScreen(buffer)
                    case .systemAudio: pipeline.append(buffer, to: .systemAudio)
                    case .microphone: pipeline.append(buffer, to: .microphone)
                    }
                },
                onStop: { [weak self] reason in self?.autoStop(AutoStopReason(reason)) })
        } catch {
            throw RecordingError.captureFailed(error.localizedDescription)
        }
        try await firstFrame.wait(timeout: 5, timeoutError: RecordingError.noFirstFrame)
        lock.withLock { firstFrameGate = nil }
    }

    private func openCamera() throws -> CameraCapture? {
        guard let deviceID = options.cameraDeviceID else { return nil }
        if let shared = sharedCamera, shared.configuration.deviceID == deviceID {
            lock.withLock { camera = shared }
            return shared
        }
        let camera: CameraCapture
        do {
            camera = try CameraCapture(
                configuration: CameraConfiguration(
                    deviceID: deviceID, width: options.cameraWidth, height: options.cameraHeight,
                    frameRate: options.cameraFrameRate))
        } catch {
            throw RecordingError.captureFailed(error.localizedDescription)
        }
        lock.withLock {
            self.camera = camera
            ownsCamera = true
        }
        return camera
    }

    private func startPointerTracking(
        package: RecordingPackage, geometry: ScreenCaptureGeometry, pipeline: RecordingPipeline
    ) async {
        let cursors = CursorImageTracker(
            directory: package.url(PackageLayout.cursorsDirectory), scale: geometry.scale)
        await cursors.start()
        lock.withLock { self.cursors = cursors }
        let tracking: ContentRectTracker.Mode =
            if case .window(let id) = options.source { .window(id) } else { .fixed }
        let tap = InputEventTap(tracking: tracking, contentRect: geometry.contentRect)
        do {
            try tap.start(
                onEvent: { pointer in
                    if pointer.kind != .scroll { cursors.noteActivity() }
                    pipeline.record(pointer, cursor: cursors.currentCursorID)
                },
                onSourceGone: { [weak self] in self?.autoStop(.sourceClosed) })
            lock.withLock { self.tap = tap }
        } catch {
            Log.app.error("Pointer events not recorded: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The `meta.json` source description.
    private func captureSource(geometry: ScreenCaptureGeometry) async -> CaptureSource {
        switch options.source {
        case .display(let id):
            let name = (try? await CaptureSources.displays())?.first { $0.id == id }?.name ?? "Display \(id)"
            return .display(displayID: id, name: name)
        case .region(let id, let rect):
            let region = CaptureGeometry.clampedRegion(rect, displaySize: CGDisplayBounds(id).size)
            return .region(
                displayID: id, x: Double(region.minX), y: Double(region.minY), width: Double(region.width),
                height: Double(region.height))
        case .window(let id):
            let window = (try? await CaptureSources.windows(includingOwnApplication: true))?.first { $0.id == id }
            return .window(windowID: id, title: window?.title, appName: window?.appName, bundleID: window?.bundleID)
        }
    }

    private static func microphoneName(_ id: String) -> String {
        AVCaptureDevice(uniqueID: id)?.localizedName ?? id
    }

    // MARK: - Stop

    private func finalize() async throws -> RecordingPackage {
        let (pipeline, package) = lock.withLock { (self.pipeline, recordingPackage) }
        guard let pipeline, let package else { throw RecordingError.invalidState("nothing to stop") }
        pipeline.stopClock(atHostTime: HostClock.now())
        await stopStreams()
        let cursorIndex = await lock.withLock({ cursors })?.finish()
        do {
            _ = try await pipeline.finish(cursorIndex: cursorIndex)
        } catch {
            let recordingError = (error as? RecordingError) ?? .packageFailed(error.localizedDescription)
            end(state: .failed)
            continuation.yield(.failed(recordingError))
            continuation.finish()
            throw recordingError
        }
        end(state: .finished)
        continuation.yield(.finished(package))
        continuation.finish()
        return package
    }

    private func end(state: State) {
        let activity = lock.withLock {
            currentState = state
            defer { self.activity = nil }
            return self.activity
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Stops every capture source (safe to call with any subset started).
    private func stopStreams() async {
        let (tap, screen, camera, ownsCamera, microphone) = lock.withLock {
            (self.tap, self.screen, self.camera, self.ownsCamera, self.microphone)
        }
        tap?.stop()
        await screen?.stop()
        camera?.setSampleHandler(nil)
        if ownsCamera { await camera?.stopRunning() }
        await microphone?.stop()
    }

    private func autoStop(_ reason: AutoStopReason) {
        let (running, gate) = lock.withLock { () -> (Bool, FirstFrameGate?) in
            if currentState == .starting {
                startupFailure = .captureFailed("Capture stopped while starting: \(reason)")
                return (false, firstFrameGate)
            }
            return (currentState == .recording || currentState == .paused, nil)
        }
        gate?.fail(RecordingError.captureFailed("Capture stopped while starting: \(reason)"))
        guard running else { return }
        Log.app.notice("Recording auto-stopped: \(String(describing: reason), privacy: .public)")
        continuation.yield(.autoStopped(reason))
        Task { _ = try? await stop() }
    }

    private func streamFailed(_ kind: StreamKind, _ message: String) {
        guard kind == .screen else {
            continuation.yield(.streamFailed(kind, message))
            return
        }
        // Without the screen there's no recording: finalise what we have.
        let error = RecordingError.writerFailed(kind, message)
        let (running, gate) = lock.withLock { () -> (Bool, FirstFrameGate?) in
            if currentState == .starting {
                startupFailure = error
                return (false, firstFrameGate)
            }
            return (currentState == .recording || currentState == .paused, nil)
        }
        gate?.fail(error)
        guard running else { return }
        continuation.yield(.failed(error))
        Task { _ = try? await stop() }
    }
}

extension RectPoints {
    init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }
}
