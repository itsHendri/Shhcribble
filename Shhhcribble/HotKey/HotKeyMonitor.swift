import Carbon.HIToolbox
import AppKit

/// Monitors a global push-to-talk hotkey using Carbon's RegisterEventHotKey.
/// - No Input Monitoring permission required
/// - Never auto-disabled by macOS
/// - keyDown fires onKeyDown; keyUp fires onKeyUp (push-to-talk style)
/// - Call updateHotkey() to change the key combo at runtime
///
/// **Both callbacks receive the Carbon event's own timestamp** (`GetEventTime`,
/// seconds since boot) — the moment the key was physically pressed or released.
/// This is load-bearing for the hold-vs-tap decision: the handlers are delivered
/// as `Task { @MainActor }`, so a keyUp cannot run until the keyDown's work
/// finishes. The recording start blocks the main actor (synchronous AppleScript
/// music-pause, then a cold-route `engine.start()`), so measuring elapsed time
/// with `DispatchTime.now()` *inside* the keyUp handler measured "how long until
/// the main actor freed up", not how long the key was held — a quick tap on a
/// cold route was misread as a 500 ms+ push-to-talk hold and stopped the
/// recording instantly ("No speech detected"). Event times are immune to that.
final class HotKeyMonitor {

    private let onKeyDown: (Double) async -> Void
    private let onKeyUp:   (Double) async -> Void

    private var hotKeyRef:    EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(onKeyDown: @escaping (Double) async -> Void,
         onKeyUp:   @escaping (Double) async -> Void) {
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
            print("[Shhhcribble] ❌ InstallEventHandler failed: \(status)")
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
            print("[Shhhcribble] ✅ Hotkey registered: \(label)")
        } else {
            print("[Shhhcribble] ❌ RegisterEventHotKey failed (\(regStatus)) for \(label). " +
                  "Another app may own this combo.")
        }
    }

    // MARK: - Internal (called from C callback)

    fileprivate func handleKeyDown(at eventTime: Double) {
        Task { @MainActor in await onKeyDown(eventTime) }
    }

    fileprivate func handleKeyUp(at eventTime: Double) {
        Task { @MainActor in await onKeyUp(eventTime) }
    }
}

// MARK: - Carbon event callback

private let hotKeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    // The time the event OCCURRED — captured here in the Carbon callback, before
    // the work is hopped onto the (possibly blocked) main actor. See the type doc.
    let eventTime = Double(GetEventTime(event))
    switch Int(GetEventKind(event)) {
    case kEventHotKeyPressed:  monitor.handleKeyDown(at: eventTime)
    case kEventHotKeyReleased: monitor.handleKeyUp(at: eventTime)
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
