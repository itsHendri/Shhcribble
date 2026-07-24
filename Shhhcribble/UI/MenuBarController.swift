import AppKit

@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarControllerDidRequestSettings(_ controller: MenuBarController)
    func menuBarControllerDidRequestCheckForUpdates(_ controller: MenuBarController)
    func menuBarControllerDidRequestQuit(_ controller: MenuBarController)
    func menuBarControllerDidRequestRepaste(_ controller: MenuBarController, text: String)
    func menuBarControllerDidRequestTranscribeFile(_ controller: MenuBarController)
    func menuBarControllerDidRequestOpenTranscriptions(_ controller: MenuBarController)
    /// The stored transform styles + which id is currently active — used to build
    /// the right-click "Style" submenu on demand.
    func menuBarControllerStyleMenu(_ controller: MenuBarController) -> (activeID: String, styles: [Style])
    /// The user picked a style (or Off / Default clean-up) from the submenu.
    func menuBarController(_ controller: MenuBarController, didSelectStyleID id: String)
    /// Whether the Sparkle updater is available — gates the "Check for Updates…"
    /// item so it's hidden when Sparkle isn't attached to the build.
    func menuBarControllerUpdaterAvailable(_ controller: MenuBarController) -> Bool
    /// Whether a call capture is running — gates the "Stop Call Transcript" item.
    func menuBarControllerIsCallCapturing(_ controller: MenuBarController) -> Bool
    /// The user chose "Stop Call Transcript" from the right-click menu.
    func menuBarControllerDidRequestStopCallCapture(_ controller: MenuBarController)
    /// The app name of a pending call-transcription offer, or nil — gates the
    /// "Transcribe <App> Call" fallback item (the in-app banner is the primary
    /// surface; this is reachable if it's missed or auto-dismissed).
    func menuBarControllerPendingCallOffer(_ controller: MenuBarController) -> String?
    /// The user accepted a pending call offer from the right-click menu.
    func menuBarControllerDidAcceptCallOffer(_ controller: MenuBarController)
    /// The user chose "New Note" from the right-click menu — create a blank
    /// sticky ready for typing.
    func menuBarControllerDidRequestNewNote(_ controller: MenuBarController)
}

/// Owns the NSStatusItem (menu-bar icon). **Left-click** opens the main
/// Transcriptions window (where every action lives). **Right-click** pops a
/// small menu with the two things worth reaching without the window open —
/// Upload Audio (file transcription) and Quit — which also gives Quit a home
/// outside the (now collapsible) window rail.
@MainActor
final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    weak var delegate: MenuBarControllerDelegate?
    private var isRecording = false
    private var updateBadged = false
    /// App name of a pending call-transcription offer (drives the amber tint +
    /// the right-click "Transcribe <App> Call" item), or nil when none.
    private var callOfferAppName: String?

    init(delegate: MenuBarControllerDelegate) {
        self.delegate = delegate
        super.init()
        setupStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        applyTint()
        if let button = statusItem.button {
            button.action = #selector(iconClicked)
            button.target = self
            // Respond to either mouse button — one click, one action.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func iconClicked() {
        // Right-click → small menu; any other click → open the window.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            delegate?.menuBarControllerDidRequestOpenTranscriptions(self)
        }
    }

    private func showRightClickMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        // A running call capture needs a stop affordance reachable without the
        // window — this is it (the capture shows no pill by design).
        if delegate?.menuBarControllerIsCallCapturing(self) == true {
            let stopCall = NSMenuItem(title: "Stop Call Transcript",
                                      action: #selector(stopCallCaptureClicked), keyEquivalent: "")
            stopCall.target = self
            menu.addItem(stopCall)
            menu.addItem(.separator())
        } else if let appName = delegate?.menuBarControllerPendingCallOffer(self) {
            // A detected-call offer is on screen — a reachable way to accept it
            // if the top-right banner was missed or has auto-dismissed.
            let accept = NSMenuItem(title: "Transcribe \(appName) Call",
                                    action: #selector(acceptCallOfferClicked), keyEquivalent: "")
            accept.target = self
            menu.addItem(accept)
            menu.addItem(.separator())
        }

        let upload = NSMenuItem(title: "Upload Audio…",
                                action: #selector(uploadAudioClicked), keyEquivalent: "")
        upload.target = self
        menu.addItem(upload)

        let newNote = NSMenuItem(title: "New Note",
                                 action: #selector(newNoteClicked), keyEquivalent: "")
        newNote.target = self
        menu.addItem(newNote)

        if let styleItem = makeStyleMenuItem() {
            menu.addItem(styleItem)
        }

        menu.addItem(.separator())

        if delegate?.menuBarControllerUpdaterAvailable(self) == true {
            let updates = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(checkForUpdatesClicked), keyEquivalent: "")
            updates.target = self
            menu.addItem(updates)
        }

        let quit = NSMenuItem(title: "Quit Shhhcribble",
                              action: #selector(quitClicked), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        // popUp(...) shows the menu without permanently assigning statusItem.menu,
        // so left-click keeps firing `iconClicked` (assigning a menu would steal it).
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    /// Build the "Style ▸" submenu (Off / Default clean-up / each stored style,
    /// checkmark on the active one). Returns nil if the delegate is gone.
    private func makeStyleMenuItem() -> NSMenuItem? {
        guard let (activeID, styles) = delegate?.menuBarControllerStyleMenu(self) else { return nil }

        let submenu = NSMenu()
        func add(_ title: String, _ id: String) {
            let item = NSMenuItem(title: title, action: #selector(styleSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (id == activeID) ? .on : .off
            submenu.addItem(item)
        }
        add("Default", ActiveStyle.defaultCleanupID)
        if !styles.isEmpty { submenu.addItem(.separator()) }
        for style in styles { add(style.name, style.id.uuidString) }

        let item = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func styleSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.menuBarController(self, didSelectStyleID: id)
    }

    @objc private func checkForUpdatesClicked() {
        delegate?.menuBarControllerDidRequestCheckForUpdates(self)
    }

    @objc private func stopCallCaptureClicked() {
        delegate?.menuBarControllerDidRequestStopCallCapture(self)
    }

    @objc private func acceptCallOfferClicked() {
        delegate?.menuBarControllerDidAcceptCallOffer(self)
    }

    /// Set (or clear) the pending call-offer indicator — amber tint + the
    /// right-click accept item. Passing nil clears it.
    func setCallOffer(pending appName: String?) {
        callOfferAppName = appName
        applyTint()
    }

    @objc private func uploadAudioClicked() {
        delegate?.menuBarControllerDidRequestTranscribeFile(self)
    }

    @objc private func newNoteClicked() {
        delegate?.menuBarControllerDidRequestNewNote(self)
    }

    @objc private func quitClicked() {
        delegate?.menuBarControllerDidRequestQuit(self)
    }

    // MARK: - Recording indicator

    /// Briefly tints the menu bar icon orange to signal "not ready yet".
    func flashNotReady() {
        guard let button = statusItem.button else { return }
        button.contentTintColor = .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isRecording else { return }
            self.applyTint()
        }
    }

    func setRecordingIndicator(active: Bool) {
        isRecording = active
        applyTint()
    }

    // MARK: - Update badge (Sparkle gentle reminder)

    /// Persistent amber tint while an update is waiting — the menu-bar-app
    /// version of a dock badge (see Sparkle "gentle reminders"; a background
    /// LSUIElement app has no dock icon or window to badge, so a silent
    /// scheduled-update alert would go unnoticed). Recording red wins while
    /// active; the badge tint resurfaces when recording ends.
    func setUpdateBadge(visible: Bool) {
        updateBadged = visible
        applyTint()
    }

    /// The status the icon currently reflects. Priority: recording > pending
    /// call offer > update waiting > idle.
    private enum IconStatus {
        case idle, recording, callOffer, updateWaiting

        /// **Symbol, not just tint.** Colour alone fails anyone who can't
        /// separate red from amber, and the menu bar gives us no text — so each
        /// status changes the glyph as well.
        var symbol: String? {
            switch self {
            case .idle:          return nil          // the app's own icon
            case .recording:     return "mic.fill"
            case .callOffer:     return "phone.fill"
            case .updateWaiting: return "arrow.down.circle.fill"
            }
        }

        var tint: NSColor? {
            switch self {
            case .idle:          return nil
            case .recording:     return .systemRed
            case .callOffer:     return .systemBlue
            case .updateWaiting: return .systemOrange
            }
        }

        var describedAs: String {
            switch self {
            case .idle:          return "Shhhcribble"
            case .recording:     return "Shhhcribble — recording"
            case .callOffer:     return "Shhhcribble — call detected, transcript offered"
            case .updateWaiting: return "Shhhcribble — update available"
            }
        }
    }

    private var currentStatus: IconStatus {
        if isRecording { return .recording }
        if callOfferAppName != nil { return .callOffer }
        if updateBadged { return .updateWaiting }
        return .idle
    }

    private func applyTint() {
        guard let button = statusItem.button else { return }
        let status = currentStatus
        button.contentTintColor = status.tint
        button.image = image(for: status)
        // The icon is the app's only always-visible surface; without this
        // VoiceOver announces nothing useful about what state it's in.
        button.setAccessibilityLabel(status.describedAs)
    }

    /// The glyph for a status — the status symbol when there is one, otherwise
    /// the app's own menu-bar icon (or the system mic as a fallback).
    private func image(for status: IconStatus) -> NSImage? {
        if let symbol = status.symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.describedAs)
            // Status symbols are tinted, so they must NOT be templates —
            // a template image is recoloured by the menu bar, not by us.
            image?.isTemplate = false
            return image
        }
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(
            systemSymbolName: "mic.fill", accessibilityDescription: status.describedAs)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true   // let macOS handle light/dark tinting
        return image
    }

}
