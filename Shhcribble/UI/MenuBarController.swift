import AppKit
import Combine

@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarControllerDidRequestSettings(_ controller: MenuBarController)
    func menuBarControllerDidRequestQuit(_ controller: MenuBarController)
    func menuBarControllerDidRequestRepaste(_ controller: MenuBarController, text: String)
}

/// Owns the NSStatusItem (menu bar icon) and rebuilds the menu whenever
/// the TranscriptionEngine's loading state changes.
@MainActor
final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private let transcriptionEngine: TranscriptionEngine
    weak var delegate: MenuBarControllerDelegate?

    private var cancellables = Set<AnyCancellable>()
    private var isRecording = false

    init(transcriptionEngine: TranscriptionEngine, delegate: MenuBarControllerDelegate) {
        self.transcriptionEngine = transcriptionEngine
        self.delegate = delegate
        super.init()
        setupStatusItem()

        // Rebuild menu whenever the engine status changes
        transcriptionEngine.$loadingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateButtonImage(recording: false)
        rebuildMenu()
    }

    // MARK: - Menu

    func rebuildMenu() {
        let menu = NSMenu()

        // Header
        let header = NSMenuItem(title: "Shhcribble", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Engine status
        let status = NSMenuItem(title: transcriptionEngine.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        // Usage hint (uses the currently selected hotkey symbol + activation mode)
        if transcriptionEngine.isReady {
            let symbol = ModelManager.selectedHotkey.symbol
            let hintString: String
            switch ModelManager.activationMode {
            case .pushToTalk:
                hintString = "Hold \(symbol) → speak → release to paste"
            case .toggle:
                hintString = "Tap \(symbol) to start · tap again to paste"
            }
            let hint = NSMenuItem(title: hintString, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            hint.attributedTitle = NSAttributedString(
                string: hintString,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        // Recent Transcriptions submenu
        if !ModelManager.history.isEmpty {
            let historyItem = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
            let historyMenu = NSMenu()

            // Title header
            let titleItem = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
            titleItem.isEnabled = false
            titleItem.attributedTitle = NSAttributedString(
                string: "Recent Transcriptions",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                             .foregroundColor: NSColor.labelColor])
            historyMenu.addItem(titleItem)

            // Description
            let descItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            descItem.isEnabled = false
            descItem.attributedTitle = NSAttributedString(
                string: "Saves your last 20 transcriptions.\nClick any item to copy & paste it.",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor])
            historyMenu.addItem(descItem)

            historyMenu.addItem(.separator())

            // History entries with clipboard icon
            let clipIcon = NSImage(systemSymbolName: "doc.on.clipboard",
                                   accessibilityDescription: "Paste")
            for entry in ModelManager.history.prefix(10) {
                let item = NSMenuItem(title: entry.menuTitle,
                                     action: #selector(repaste(_:)),
                                     keyEquivalent: "")
                item.representedObject = entry.text
                item.image = clipIcon
                item.target = self
                historyMenu.addItem(item)
            }

            historyMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear History",
                                       action: #selector(clearHistory),
                                       keyEquivalent: "")
            clearItem.target = self
            historyMenu.addItem(clearItem)

            historyItem.submenu = historyMenu
            menu.addItem(historyItem)
            menu.addItem(.separator())
        }

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Shhcribble",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Recording indicator

    /// Briefly tints the menu bar icon orange to signal "not ready yet"
    func flashNotReady() {
        guard let button = statusItem.button else { return }
        button.contentTintColor = .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isRecording else { return }
            button.contentTintColor = nil
        }
    }

    func setRecordingIndicator(active: Bool) {
        isRecording = active
        updateButtonImage(recording: active)
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
                            accessibilityDescription: "Shhcribble")
        }
        image?.isTemplate = !recording   // template = macOS handles dark/light tinting
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Actions

    @objc private func openSettings() {
        delegate?.menuBarControllerDidRequestSettings(self)
    }

    @objc private func quit() {
        delegate?.menuBarControllerDidRequestQuit(self)
    }

    @objc private func repaste(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        delegate?.menuBarControllerDidRequestRepaste(self, text: text)
    }

    @objc private func clearHistory() {
        ModelManager.clearHistory()
        rebuildMenu()
    }
}
