import CoreGraphics
import Foundation

/// A listen-only `CGEventTap` for pointer events (move, drag, down/up for every button, scroll) on a dedicated
/// thread with its own `CFRunLoop`. Event-driven: the thread sleeps until the Window Server delivers an event.
///
/// Positions are normalised to a content rect (fixed, or a tracked window's live frame). Timestamps are host
/// seconds. If macOS disables the tap for being slow it is re-enabled immediately.
///
/// Needs Input Monitoring (``Permissions/status(_:)`` for `.inputMonitoring`); without it the tap may be
/// created but receive nothing.
public final class InputEventTap: @unchecked Sendable {
    public typealias EventHandler = @Sendable (PointerEvent) -> Void
    public typealias SourceGoneHandler = @Sendable () -> Void

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
            .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    private let lock = NSLock()
    private var processor: InputEventProcessor
    private let frameProvider: @Sendable (CGWindowID) -> CGRect?
    private var onEvent: EventHandler?
    private var onSourceGone: SourceGoneHandler?
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var retainedSelf: Unmanaged<InputEventTap>?
    private var received = 0

    /// - Parameters:
    ///   - tracking: `.fixed` for display/region capture, `.window(id)` to follow a window's frame.
    ///   - contentRect: the content rect in global points at start.
    ///   - frameProvider: window frame lookup (injectable for tests).
    public init(
        tracking: ContentRectTracker.Mode, contentRect: CGRect, minimumMoveInterval: Double = 1.0 / 240,
        frameProvider: @escaping @Sendable (CGWindowID) -> CGRect? = { WindowList.frame(of: $0) }
    ) {
        processor = InputEventProcessor(
            tracker: ContentRectTracker(mode: tracking, rect: contentRect), minimumMoveInterval: minimumMoveInterval)
        self.frameProvider = frameProvider
    }

    deinit {
        stop()
    }

    /// Events seen by the tap (including coalesced moves).
    public var eventsReceived: Int { lock.withLock { received } }

    /// The current content rect.
    public var contentRect: CGRect { lock.withLock { processor.tracker.rect } }

    /// Updates the content rect live (e.g. the region changed).
    public func setContentRect(_ rect: CGRect) {
        lock.withLock { processor.setContentRect(rect) }
    }

    /// Creates the tap and starts its thread. Handlers run on the tap thread; keep them short.
    /// - Throws: ``CaptureError/eventTapUnavailable`` if the tap can't be created.
    public func start(onEvent: @escaping EventHandler, onSourceGone: SourceGoneHandler? = nil) throws {
        guard lock.withLock({ port == nil }) else { return }
        let retained = Unmanaged.passRetained(self)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: Self.eventMask, callback: inputEventTapCallback, userInfo: retained.toOpaque())
        else {
            retained.release()
            throw CaptureError.eventTapUnavailable
        }
        let ready = DispatchSemaphore(value: 0)
        let sendablePort = UncheckedSendable(port)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()!
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, sendablePort.value, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: sendablePort.value, enable: true)
            self?.lock.withLock { self?.runLoop = runLoop }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.myscreenart.capture.eventtap"
        thread.qualityOfService = .userInteractive
        lock.withLock {
            self.port = port
            self.thread = thread
            self.retainedSelf = retained
            self.onEvent = onEvent
            self.onSourceGone = onSourceGone
        }
        thread.start()
        ready.wait()
        CaptureLog.input.info("Event tap started")
    }

    /// Stops the tap and its thread. Safe to call more than once.
    public func stop() {
        let (port, runLoop, retained) = lock.withLock {
            defer {
                self.port = nil
                self.runLoop = nil
                self.thread = nil
                self.retainedSelf = nil
                self.onEvent = nil
                self.onSourceGone = nil
            }
            return (self.port, self.runLoop, self.retainedSelf)
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        retained?.release()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ port }) {
                CGEvent.tapEnable(tap: port, enable: true)
                CaptureLog.input.notice("Event tap re-enabled after \(type.rawValue)")
            }
            return
        }
        let frameProvider = frameProvider
        let (outputs, onEvent, onGone) = lock.withLock {
            received += 1
            return (processor.process(type: type, event: event, frameProvider: frameProvider), onEvent, onSourceGone)
        }
        for output in outputs {
            switch output {
            case .event(let pointer): onEvent?(pointer)
            case .sourceGone: onGone?()
            }
        }
    }
}

private func inputEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<InputEventTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
