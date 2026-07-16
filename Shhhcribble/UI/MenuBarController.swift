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

    init(delegate: MenuBarControllerDelegate) {
        self.delegate = delegate
        super.init()
        setupStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateButtonImage(recording: false)
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

        let upload = NSMenuItem(title: "Upload Audio…",
                                action: #selector(uploadAudioClicked), keyEquivalent: "")
        upload.target = self
        menu.addItem(upload)

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

    @objc private func uploadAudioClicked() {
        delegate?.menuBarControllerDidRequestTranscribeFile(self)
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
        updateButtonImage(recording: active)
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

    /// Recording red > update-pending amber > default template tint.
    private func applyTint() {
        guard let button = statusItem.button else { return }
        if isRecording { button.contentTintColor = .systemRed }
        else if updateBadged { button.contentTintColor = .systemOrange }
        else { button.contentTintColor = nil }
    }

    private func updateButtonImage(recording: Bool) {
        guard let button = statusItem.button else { return }

        // Use custom asset if provided, otherwise fall back to the system mic symbol.
        // The asset must be a black-on-transparent PNG/PDF named "MenuBarIcon" in
        // Assets.xcassets — macOS tints template images automatically for light/dark bars.
        let image: NSImage?
        if let custom = NSImage(named: "MenuBarIcon") {
            custom.size = NSSize(width: 18, height: 18)
            image = custom
        } else {
            image = NSImage(systemSymbolName: "mic.fill",
                            accessibilityDescription: "Shhhcribble")
        }
        image?.isTemplate = !recording   // template = macOS handles dark/light tinting
        button.image = image
        applyTint()
    }
}
