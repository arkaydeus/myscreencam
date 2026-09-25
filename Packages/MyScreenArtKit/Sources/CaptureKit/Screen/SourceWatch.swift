import AppKit
import CoreGraphics

/// Notices, without polling, when a capture source goes away: display disconnects (Core Graphics display
/// reconfiguration callback) and the captured window's application quitting (NSWorkspace notification).
final class SourceWatch: @unchecked Sendable {
    private let displayID: CGDirectDisplayID?
    private let windowOwnerPID: pid_t?
    private let onGone: @Sendable (ScreenCaptureStopReason) -> Void
    private var workspaceToken: (any NSObjectProtocol)?
    private var registeredDisplayCallback = false

    private init(
        displayID: CGDirectDisplayID?, windowOwnerPID: pid_t?,
        onGone: @escaping @Sendable (ScreenCaptureStopReason) -> Void
    ) {
        self.displayID = displayID
        self.windowOwnerPID = windowOwnerPID
        self.onGone = onGone
    }

    /// Registers the observers on the main thread (display callbacks are delivered on the main run loop).
    @MainActor
    static func start(
        displayID: CGDirectDisplayID?, windowOwnerPID: pid_t?,
        onGone: @escaping @Sendable (ScreenCaptureStopReason) -> Void
    ) -> SourceWatch {
        let watch = SourceWatch(displayID: displayID, windowOwnerPID: windowOwnerPID, onGone: onGone)
        if displayID != nil {
            let context = Unmanaged.passUnretained(watch).toOpaque()
            watch.registeredDisplayCallback =
                CGDisplayRegisterReconfigurationCallback(displayReconfigured, context) == .success
        }
        if let pid = windowOwnerPID {
            watch.workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.processIdentifier == pid { onGone(.sourceClosed) }
            }
        }
        return watch
    }

    @MainActor
    func cancel() {
        if registeredDisplayCallback {
            CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
            registeredDisplayCallback = false
        }
        if let workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)
            self.workspaceToken = nil
        }
    }

    fileprivate func displayChanged(_ id: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard id == displayID, flags.contains(.removeFlag) || flags.contains(.disabledFlag) else { return }
        onGone(.displayRemoved)
    }
}

private func displayReconfigured(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?
) {
    guard let context, !flags.contains(.beginConfigurationFlag) else { return }
    Unmanaged<SourceWatch>.fromOpaque(context).takeUnretainedValue().displayChanged(display, flags: flags)
}

/// Window Server queries for a single window (cheap: one `CGWindowListCopyWindowInfo` call).
public enum WindowList {
    /// The window's frame in global points (origin top-left of the main display), or nil if it's gone.
    public static func frame(of windowID: CGWindowID) -> CGRect? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]],
            let info = list.first(where: { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == windowID }),
            let bounds = info[kCGWindowBounds] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    public static func exists(_ windowID: CGWindowID) -> Bool { frame(of: windowID) != nil }
}
