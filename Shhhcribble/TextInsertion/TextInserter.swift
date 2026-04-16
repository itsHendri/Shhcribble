import AppKit
import ApplicationServices

enum InsertionResult {
    case accessibilityInserted  // direct AX insert — no further action needed
    case pastedViaKeyboard      // Cmd+V simulated — target app should show the text
    case copiedToClipboard      // both methods unavailable — user must ⌘V manually
}

/// Inserts text into the app that was frontmost when recording began.
///
/// Strategy (in order):
/// 1. Always copy to clipboard (universal failsafe).
/// 2. Try Accessibility API direct insert — works in Notes, TextEdit, Xcode, Terminal.
/// 3. Send Cmd+V directly to the target process by PID — works in Slack, Claude,
///    browsers, and any Electron app regardless of AX attribute support.
///    Skipped only when the target is Finder/Desktop (would cause a pop sound).
/// 4. Text is already on clipboard — user can ⌘V manually.
final class TextInserter {

    func insert(text: String, targetPid: pid_t? = nil) -> InsertionResult {
        // Step 1: always put text on clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Step 2: try direct AX insert
        if tryAccessibilityInsert(text: text) {
            print("[Shhhcribble] ✅ Inserted via Accessibility API")
            return .accessibilityInserted
        }

        // Step 3: send Cmd+V to the specific process that was frontmost at record-start.
        // Using postToPid bypasses any focus ambiguity introduced by the floating panel.
        // Only skip Finder — it's the sole app that produces a system pop sound for
        // an unhandled paste (desktop/icon selection with nothing to paste into).
        if let pid = targetPid, !isFinderPid(pid), simulateCmdV(targetPid: pid) {
            print("[Shhhcribble] ✅ Pasted via Cmd+V to PID \(pid)")
            return .pastedViaKeyboard
        }

        print("[Shhhcribble] Text on clipboard — user must press ⌘V manually")
        return .copiedToClipboard
    }

    // MARK: - Accessibility API

    private func tryAccessibilityInsert(text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success, let element = focusedElement else { return false }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element as! AXUIElement,
                                       kAXSelectedTextAttribute as CFString,
                                       &settable)
        guard settable.boolValue else { return false }

        return AXUIElementSetAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    // MARK: - Cmd+V simulation

    @discardableResult
    private func simulateCmdV(targetPid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // V

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags   = .maskCommand
        // Post directly to the target process — no dependency on system focus state
        down.postToPid(targetPid)
        up.postToPid(targetPid)
        return true
    }

    // MARK: - Helpers

    private func isFinderPid(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder"
    }
}
