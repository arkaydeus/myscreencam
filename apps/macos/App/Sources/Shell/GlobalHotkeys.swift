import Carbon.HIToolbox
import MyScreenArtCore

/// System-wide hotkeys through Carbon's `RegisterEventHotKey`, which needs no Accessibility or Input
/// Monitoring permission. The event handler runs on the main thread (application event target).
///
/// - ⌥⌘↩ opens the recorder (`AppRouter.showRecorder()`).
/// - ⌥⇧⌘R finishes the active recording.
@MainActor
final class GlobalHotkeys {
    struct Hotkey {
        let id: UInt32
        let keyCode: Int
        let modifiers: Int
        let action: @MainActor () -> Void
    }

    private static let signature: OSType = 0x4D53_4148  // 'MSAH'

    private let hotkeys: [Hotkey]
    private var registrations: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init(actions: ShellActions) {
        hotkeys = [
            Hotkey(id: 1, keyCode: kVK_Return, modifiers: optionKey | cmdKey) { actions.newRecording() },
            Hotkey(id: 2, keyCode: kVK_ANSI_R, modifiers: optionKey | shiftKey | cmdKey) {
                actions.finishRecording()
            },
        ]
    }

    var isRegistered: Bool { handler != nil }

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotkeyEventHandler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            Log.app.error("Global hotkeys: InstallEventHandler failed (\(status))")
            return
        }
        for hotkey in hotkeys {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: hotkey.id)
            let result = RegisterEventHotKey(
                UInt32(hotkey.keyCode), UInt32(hotkey.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref {
                registrations.append(ref)
            } else {
                // Another app already owns the combination; the menu shortcut still works while we're active.
                Log.app.error("Global hotkey \(hotkey.id) unavailable (\(result))")
            }
        }
        Log.app.info("Global hotkeys registered: \(self.registrations.count)")
    }

    private func unregister() {
        for ref in registrations { UnregisterEventHotKey(ref) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    fileprivate func handle(id: UInt32) {
        hotkeys.first { $0.id == id }?.action()
    }
}

/// Carbon callback. Hotkey events are delivered on the main thread.
nonisolated private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == 0x4D53_4148 else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    let address = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
        Unmanaged<GlobalHotkeys>.fromOpaque(pointer).takeUnretainedValue().handle(id: id)
    }
    return noErr
}
