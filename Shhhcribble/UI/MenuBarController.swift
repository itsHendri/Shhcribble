import AppKit

@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarControllerDidRequestSettings(_ controller: MenuBarController)
    func menuBarControllerDidRequestCheckForUpdates(_ controller: MenuBarController)
    func menuBarControllerDidRequestQuit(_ controller: MenuBarController)
    func menuBarControllerDidRequestRepaste(_ controller: MenuBarController, text: String)
    func menuBarControllerDidRequestTranscribeFile(_ controller: MenuBarController)
    func menuBarControllerDidRequestOpenTranscriptions(_ controller: MenuBarController)
}

/// Owns the NSStatusItem (menu-bar icon). Clicking the icon (left or right)
/// opens the main Transcriptions window — every action (settings, quit, recent,
/// engine status, transcribe file) lives in that window now, so there is no
/// dropdown menu to maintain.
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
        delegate?.menuBarControllerDidRequestOpenTranscriptions(self)
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
