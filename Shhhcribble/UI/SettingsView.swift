import SwiftUI
import ApplicationServices
import AVFoundation

struct SettingsView: View {
    @ObservedObject var transcriptionEngine: TranscriptionEngine
    var appDelegate: AppDelegate
    /// Source of truth for the Personal Dictionary (SQLite-backed). The list +
    /// CRUD drive off `transcriptStore.dictionaryEntries` directly — no @State copy.
    @ObservedObject var transcriptStore: TranscriptStore

    @State private var selectedModel:        String = ModelManager.selectedModel
    @State private var selectedHotkeyID:    String = ModelManager.selectedHotkeyID
    @State private var activationMode: ModelManager.ActivationMode = ModelManager.activationMode
    @State private var callDetectionEnabled: Bool = ModelManager.callDetectionEnabled

    @State private var axGranted        = false
    @State private var micGranted       = false
    @State private var micNotDetermined = false

    // Auto-refresh permission status while the panel is open
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            // MARK: Model picker
            Section {
                Picker("Model", selection: $selectedModel) {
                    ForEach(ModelManager.availableModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(transcriptionEngine.isBusy)
                .onChange(of: selectedModel) { _, newValue in
                    guard newValue != ModelManager.selectedModel else { return }
                    ModelManager.selectedModel = newValue
                    Task { await transcriptionEngine.reloadModel(variant: newValue) }
                }

                if transcriptionEngine.isBusy {
                    InlineWarning(message: "Stop the current recording to change the transcription model.")
                }

                // Loading state feedback
                switch transcriptionEngine.loadingState {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(transcriptionEngine.statusText)
                            .font(.caption).foregroundColor(.secondary)
                    }
                case .failed:
                    Label(transcriptionEngine.statusText, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.red)
                default:
                    Text(transcriptionEngine.statusText)
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Text("Transcription Model").font(.sectionTitle)
            } footer: {
                Text("Models are downloaded once and cached on your Mac.\n" +
                     "Parakeet V3 (multilingual) is recommended for most users.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Hotkey picker
            Section {
                Picker("Shortcut", selection: $selectedHotkeyID) {
                    ForEach(ModelManager.availableHotkeys) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: selectedHotkeyID) { _, newValue in
                    guard let option = ModelManager.availableHotkeys.first(where: { $0.id == newValue }) else { return }
                    appDelegate.updateHotkey(option)
                }
            } header: {
                Text("Recording Shortcut").font(.sectionTitle)
            }

            // MARK: Activation mode
            Section {
                Picker("Activation", selection: $activationMode) {
                    ForEach(ModelManager.ActivationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: activationMode) { _, newValue in
                    ModelManager.activationMode = newValue
                }
            } header: {
                Text("Activation").font(.sectionTitle)
            } footer: {
                Text(activationMode.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Transcription options
            Section {
                Toggle("Detect calls and offer to transcribe", isOn: $callDetectionEnabled)
                    .onChange(of: callDetectionEnabled) { _, newValue in
                        ModelManager.callDetectionEnabled = newValue
                        appDelegate.callDetectionSettingChanged()
                    }
                Text("When WhatsApp, Zoom, FaceTime or another call app starts using the microphone, a notification offers to transcribe your side of the call into the library. Nothing is recorded unless you accept.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Transcript cleanup and writing styles now live in the **Styles** tab — pick a default, add your own, or import a SKILL.md.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Options").font(.sectionTitle)
            } footer: {
                Text("Spotify and Apple Music pause automatically while you dictate and resume when recording ends.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Permissions
            Section {
                // Accessibility
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility (optional)").fontWeight(.medium)
                            Text(axGranted
                                 ? "Text is inserted directly at the cursor in the focused field"
                                 : "Without this, text is pasted via ⌘V instead")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if axGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green).font(.callout)
                        } else {
                            HStack(spacing: 8) {
                                Button("Re-check") { checkPermissions() }
                                    .controlSize(.small)
                                Button("Open Settings") { openSystemPrivacy("Privacy_Accessibility") }
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    if !axGranted {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("First time:")
                                .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
                            Text("Open Settings → find Shhhcribble → toggle it on.")
                                .font(.caption2).foregroundColor(.secondary)
                            Text("After a rebuild:")
                                .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
                                .padding(.top, 2)
                            Text("If the toggle is already on but not detected, click − to remove Shhhcribble then + to re-add the freshly built app.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.leading, 32)
                    }
                }

                // Microphone — distinguish "never asked" from "denied"
                microphoneRow
            } header: {
                Text("Permissions").font(.sectionTitle)
            }

            // MARK: About
            Section {
                HStack {
                    Text("Shhhcribble").fontWeight(.medium)
                    Spacer()
                    Text(appVersionString).foregroundColor(.secondary)
                }
                // Manual update check — Sparkle also checks automatically in the
                // background; a pending update tints the menu-bar icon amber.
                if appDelegate.updaterAvailable {
                    Button("Check for Updates…") { appDelegate.checkForUpdates() }
                }
                Text(aboutShortcutHint)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(alignment: .bottom, spacing: 12) {
                    Text("this app was crafted by a human named Hendri with chief vibes officer Tiuri whispering ideas in his ear. both humans. probably.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text("( ᴗ ͜ʖ ᴗ)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.top, 2)
            } header: {
                Text("About").font(.sectionTitle)
            }
        }
        .formStyle(.grouped)
        .onAppear { checkPermissions() }
        .onReceive(permissionTimer) { _ in checkPermissions() }
    }

    /// Single source of truth for the displayed version. Reads
    /// CFBundleShortVersionString from Info.plist so bumping the plist
    /// is all that's required at release time. "Beta" is a display-only label
    /// (the plist version stays plain numeric for Sparkle/tooling) — drop the
    /// suffix here when the app graduates.
    private var appVersionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(v) Beta"
    }

    private var aboutShortcutHint: String {
        let symbol = ModelManager.availableHotkeys.first(where: { $0.id == selectedHotkeyID })?.symbol ?? "⌥Space"
        return "Tap \(symbol) to start recording and tap again to stop, or hold it and release — text pastes into any field."
    }

    // MARK: - Microphone row (inline to call requestAccess directly)

    @ViewBuilder
    private var microphoneRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mic.fill")
                .foregroundColor(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone").fontWeight(.medium)
                Text("Required to record your voice")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if micGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.callout)
            } else if micNotDetermined {
                // First-time: trigger the system prompt directly
                Button("Grant Access") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { checkPermissions() }
                    }
                }
                .controlSize(.small)
            } else {
                // Already denied — must go to System Settings
                Button("Open Settings") { openSystemPrivacy("Privacy_Microphone") }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func checkPermissions() {
        axGranted = AXIsProcessTrusted()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    micGranted = true;  micNotDetermined = false
        case .notDetermined: micGranted = false; micNotDetermined = true
        default:             micGranted = false; micNotDetermined = false
        }
    }

    private func openSystemPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Dictionary tab

/// The Dictionary editor — its own left-nav tab in the Studio shell
/// (moved out of Settings). Drives directly off the SQLite-backed store (no
/// `@State` copy); reorder via explicit up/down buttons since drag-reorder
/// inside a grouped `Form` is unreliable on macOS and order is meaningful
/// (entries apply top-down).
struct DictionarySettingsView: View {
    @ObservedObject var store: TranscriptStore

    @State private var showingAddEntrySheet = false
    @State private var editingEntry: DictionaryEntry? = nil
    @State private var deletingEntry: DictionaryEntry? = nil
    @State private var showingImportSheet = false
    @State private var copiedToast = false
    @State private var copiedToastTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if store.dictionaryEntries.isEmpty {
                    Text("No entries yet — add names or jargon the transcriber gets wrong.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(Array(store.dictionaryEntries.enumerated()), id: \.element.id) { index, entry in
                    dictionaryRow(entry: entry, index: index)
                }
                Button("Add Entry…") { showingAddEntrySheet = true }
            } header: {
                Text("Dictionary").font(.sectionTitle)
            }

            Section {
                Text(Self.wordListPrompt)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy prompt") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(Self.wordListPrompt, forType: .string)
                    flashCopied()
                }
            } header: {
                HStack {
                    Text("Build a word list with AI").font(.sectionTitle)
                    Spacer()
                    Button("Paste list") { showingImportSheet = true }
                        .textCase(nil)
                }
            } footer: {
                Text("Copy this prompt into any AI. Tell it about your work, then tell it which words keep " +
                     "coming out wrong when you dictate. It replies with `misheard => correct` lines; paste " +
                     "those back here and they're added to your dictionary in one go.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .overlay(alignment: .bottom) {
            if copiedToast {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.callout).fontWeight(.medium)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                    .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDisappear { copiedToastTask?.cancel() }
        .sheet(isPresented: $showingImportSheet) {
            DictionaryBulkImportView { entries in
                store.addDictionaryEntries(entries)
            }
        }
        .alert("Delete this word?", isPresented: Binding(
            get: { deletingEntry != nil },
            set: { if !$0 { deletingEntry = nil } }
        ), presenting: deletingEntry) { entry in
            Button("Delete", role: .destructive) { store.deleteDictionaryEntry(id: entry.id) }
            Button("Cancel", role: .cancel) { }
        } message: { entry in
            Text("“\(entry.phrase)” → “\(entry.replacement)” will be removed from your dictionary.")
        }
        .sheet(isPresented: $showingAddEntrySheet) {
            DictionaryEntryEditor(title: "Add Dictionary Entry") { phrase, replacement, caseSensitive in
                store.addDictionaryEntry(
                    DictionaryEntry(phrase: phrase, replacement: replacement, caseSensitive: caseSensitive)
                )
            }
        }
        .sheet(item: $editingEntry) { entry in
            DictionaryEntryEditor(
                title: "Edit Dictionary Entry",
                phrase: entry.phrase,
                replacement: entry.replacement,
                caseSensitive: entry.caseSensitive
            ) { phrase, replacement, caseSensitive in
                store.updateDictionaryEntry(
                    id: entry.id, phrase: phrase, replacement: replacement, caseSensitive: caseSensitive
                )
            }
        }
    }

    @ViewBuilder
    private func dictionaryRow(entry: DictionaryEntry, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(entry.phrase)
                .lineLimit(1).truncationMode(.tail)
            Image(systemName: "arrow.right")
                .font(.caption2).foregroundColor(.secondary)
            Text(entry.replacement)
                .fontWeight(.medium)
                .lineLimit(1).truncationMode(.tail)
            if entry.caseSensitive {
                Text("Aa")
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: DesignSystem.radiusBadge).fill(Color.secondary.opacity(0.15)))
                    .help("Matches case exactly")
            }
            Spacer(minLength: 8)
            Button { store.moveDictionaryEntry(at: index, by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")
            .accessibilityLabel("Move up")
            Button { store.moveDictionaryEntry(at: index, by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == store.dictionaryEntries.count - 1)
            .help("Move down")
            .accessibilityLabel("Move down")
            Button { editingEntry = entry } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            .accessibilityLabel("Edit entry")
            Button { deletingEntry = entry } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .accessibilityLabel("Delete entry")
        }
    }

    /// Flash the shared "Copied" toast (same as the transcripts view) — the
    /// universal rule that any copy action gives visible confirmation.
    private func flashCopied() {
        copiedToastTask?.cancel()
        withAnimation(DesignSystem.motion(.spring(response: 0.3, dampingFraction: 0.8))) { copiedToast = true }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(DesignSystem.motion(.easeOut(duration: 0.25))) { copiedToast = false }
        }
    }

    /// A ready-to-paste prompt users drop into any AI to generate a custom word
    /// list. The output format (`misheard => correct`, one per line) is baked in
    /// so the reply pastes straight into the bulk-import sheet
    /// (`DictionaryBulkImportView`), which parses exactly that.
    static let wordListPrompt = """
        I use a voice-to-text app whose speech model often mis-transcribes proper nouns, brand and product \
        names, technical jargon, and non-English names. Help me build a correction list. First, ask me about my \
        job, company, tools, teammates' names, and the topics I dictate about — and ask which words tend to come \
        out wrong when I dictate. Then give me 20–40 likely-mis-transcribed terms.

        Format the result as ONLY these lines, nothing else — one entry per line:
        misheard spelling => correct spelling

        (put the wrong transcription on the left, the correct word on the right). Prioritise names, acronyms, \
        product names, and domain jargon.
        """
}

// MARK: - Dictionary entry editor

/// Small sheet used for both Add and Edit. Save is disabled until both fields
/// have non-whitespace content.
private struct DictionaryEntryEditor: View {
    let title: String
    @State var phrase: String = ""
    @State var replacement: String = ""
    @State var caseSensitive: Bool = false
    let onSave: (String, String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private var trimmedPhrase: String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Spoken phrase (what the transcriber hears)", text: $phrase)
                    .textFieldStyle(.roundedBorder)
                Text("Separate multiple variants with commas — e.g. henry, hendry, henri")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Replace with", text: $replacement)
                .textFieldStyle(.roundedBorder)
            Toggle("Match case exactly", isOn: $caseSensitive)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmedPhrase, trimmedReplacement, caseSensitive)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedPhrase.isEmpty || trimmedReplacement.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Dictionary bulk import

/// Paste a list of `misheard => correct` lines (the format the "Build a word
/// list with AI" prompt asks for) and add them all at once. Tolerant of arrows,
/// commas, tabs, and Markdown-table pipes so a pasted table still parses.
private struct DictionaryBulkImportView: View {
    let onAdd: ([DictionaryEntry]) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var parsed: [DictionaryEntry] { DictionaryImport.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a word list").font(.headline)
            Text("One entry per line as `misheard => correct`. Lines from a Markdown table " +
                 "(`|`- or comma-separated) work too.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: DesignSystem.radiusControl).stroke(.quaternary))

            HStack {
                Text(parsed.isEmpty ? "No entries detected yet" : countLabel)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(countLabel)") {
                    onAdd(parsed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var countLabel: String { "\(parsed.count) word\(parsed.count == 1 ? "" : "s")" }
}

/// Parses a pasted word list into dictionary entries. Extracted from the view so
/// it's unit-testable. Left = misheard (phrase), right = correct (replacement).
/// Accepts `=>`, `->`, `→`, `|`, tab, comma, or `=` as the separator; strips
/// Markdown pipes; skips blanks, separator rows, and an obvious header row.
enum DictionaryImport {
    static func parse(_ text: String) -> [DictionaryEntry] {
        let separators = ["=>", "->", "→", "|", "\t", ",", "="]
        var result: [DictionaryEntry] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                       .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("---") else { continue }
            guard let sep = separators.first(where: { line.contains($0) }) else { continue }
            let parts = line.components(separatedBy: sep)
            guard parts.count >= 2 else { continue }
            let phrase = parts[0].trimmingCharacters(in: .whitespaces)
            let replacement = parts[1].trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty, !replacement.isEmpty else { continue }
            let low = phrase.lowercased()
            if low == "misheard" || low == "wrong" || low == "misheard spelling" { continue }
            result.append(DictionaryEntry(phrase: phrase, replacement: replacement, caseSensitive: false))
        }
        return result
    }
}

// MARK: - Inline warning

/// Inline amber callout used to explain why a control is disabled. Pattern
/// borrowed from Base44 on Mobbin — an inset card with a warning glyph and
/// short body copy, distinct from a destructive-action modal because the
/// situation is informational, not an error.
struct InlineWarning: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color(red: 0.95, green: 0.66, blue: 0.10))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 1)
            Text(message)
                .font(.caption)
                .foregroundColor(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.radiusControl)
                .fill(Color(red: 0.95, green: 0.66, blue: 0.10).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusControl)
                .stroke(Color(red: 0.95, green: 0.66, blue: 0.10).opacity(0.28), lineWidth: 0.6)
        )
    }
}
