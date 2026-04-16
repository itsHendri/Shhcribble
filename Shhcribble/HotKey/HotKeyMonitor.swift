import Carbon.HIToolbox
import AppKit

/// Monitors a global push-to-talk hotkey using Carbon's RegisterEventHotKey.
/// - No Input Monitoring permission required
/// - Never auto-disabled by macOS
/// - keyDown fires onKeyDown; keyUp fires onKeyUp (push-to-talk style)
/// - Call updateHotkey() to change the key combo at runtime
final class HotKeyMonitor {

    private let onKeyDown: () async -> Void
    private let onKeyUp:   () async -> Void

    private var hotKeyRef:    EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(onKeyDown: @escaping () async -> Void,
         onKeyUp:   @escaping () async -> Void) {
        self.onKeyDown = onKeyDown
        self.onKeyUp   = onKeyUp
    }

    deinit { stop() }

    // MARK: - Public API

    func start(keyCode: UInt32, modifiers: UInt32) {
        // Install the event handler once
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind:  UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind:  UInt32(kEventHotKeyReleased))
        ]

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventCallback,
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &eventHandler
        )

        guard status == noErr else {
            print("[Shhcribble] ❌ InstallEventHandler failed: \(status)")
            Unmanaged<HotKeyMonitor>.fromOpaque(selfPtr).release()
            return
        }

        registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    /// Re-register with a new key combo (call from main thread).
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    func stop() {
        if let ref = hotKeyRef    { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h   = eventHandler { RemoveEventHandler(h);      eventHandler = nil }
    }

    // MARK: - Private

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = fourCharCode("FWpt")
        hotKeyID.id        = 1

        let regStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0,
            &hotKeyRef
        )

        let option = ModelManager.availableHotkeys.first(where: {
            $0.keyCode == keyCode && $0.modifiers == modifiers
        })
        let label = option?.label ?? "custom"

        if regStatus == noErr {
            print("[Shhcribble] ✅ Hotkey registered: \(label)")
        } else {
            print("[Shhcribble] ❌ RegisterEventHotKey failed (\(regStatus)) for \(label). " +
                  "Another app may own this combo.")
        }
    }

    // MARK: - Internal (called from C callback)

    fileprivate func handleKeyDown() {
        Task { @MainActor in await onKeyDown() }
    }

    fileprivate func handleKeyUp() {
        Task { @MainActor in await onKeyUp() }
    }
}

// MARK: - Carbon event callback

private let hotKeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    switch Int(GetEventKind(event)) {
    case kEventHotKeyPressed:  monitor.handleKeyDown()
    case kEventHotKeyReleased: monitor.handleKeyUp()
    default: break
    }
    return noErr
}

// MARK: - Helpers

private func fourCharCode(_ s: StaticString) -> FourCharCode {
    let bytes = s.utf8Start
    return FourCharCode(bytes[0]) << 24
         | FourCharCode(bytes[1]) << 16
         | FourCharCode(bytes[2]) << 8
         | FourCharCode(bytes[3])
}
