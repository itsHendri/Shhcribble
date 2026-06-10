import SwiftUI
import ApplicationServices
import AVFoundation

struct SettingsView: View {
    @ObservedObject var transcriptionEngine: TranscriptionEngine
    var appDelegate: AppDelegate

    @State private var selectedModel:        String = ModelManager.selectedModel
    @State private var selectedHotkeyID:    String = ModelManager.selectedHotkeyID
    @State private var transcriptCleanupEnabled: Bool = ModelManager.transcriptCleanupEnabled

    @State private var dictionaryEntries: [DictionaryEntry] = ModelManager.dictionaryEntries
    @State private var showingAddEntrySheet = false
    @State private var editingEntry: DictionaryEntry? = nil

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
                Text("Transcription Model")
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
                Text("Recording Shortcut")
            } footer: {
                Text("Tap the shortcut to start recording and tap again to stop, " +
                     "or hold it and release to transcribe — Shhhcribble picks the " +
                     "mode based on how long you hold.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: Transcription options
            Section {
                let cleanupAvailability = TranscriptCleaner.availability
                Toggle("Clean up transcript with on-device AI", isOn: $transcriptCleanupEnabled)
                    .disabled(!cleanupAvailability.isAvailable)
                    .onChange(of: transcriptCleanupEnabled) { _, newValue in
                        ModelManager.transcriptCleanupEnabled = newValue
                        if newValue { TranscriptCleaner.prewarm() }
                    }
                if case .unavailable(let reason) = cleanupAvailability {
                    InlineWarning(message: reason)
                }
            } header: {
                Text("Options")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On-device AI cleanup uses Apple Intelligence (macOS 26) to remove filler words and fix punctuation, capitalization and false starts. Nothing leaves your Mac.")
                    Text("When it’s off or unavailable, basic filler-word removal (\"um\", \"uh\", \"hmm\") is applied automatically.")
                    Text("Spotify and Apple Music pause automatically while you dictate and resume when recording ends.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // MARK: Personal dictionary
            Section {
                if dictionaryEntries.isEmpty {
                    Text("No entries yet — add names or jargon the transcriber gets wrong.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(Array(dictionaryEntries.enumerated()), id: \.element.id) { index, entry in
                    dictionaryRow(entry: entry, index: index)
                }
                Button("Add Entry…") { showingAddEntrySheet = true }
            } header: {
                Text("Personal Dictionary")
            } footer: {
                Text("Replacements are applied to the raw transcript before AI cleanup, " +
                     "in list order. Whole words only — \"cat\" never matches inside \"catalog\".")
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
                Text("Permissions")
            }

            // MARK: About
            Section("About") {
                HStack {
                    Text("Shhhcribble").fontWeight(.medium)
                    Spacer()
                    Text(appVersionString).foregroundColor(.secondary)
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { checkPermissions() }
        .onReceive(permissionTimer) { _ in checkPermissions() }
        .sheet(isPresented: $showingAddEntrySheet) {
            DictionaryEntryEditor(title: "Add Dictionary Entry") { phrase, replacement, caseSensitive in
                dictionaryEntries.append(
                    DictionaryEntry(phrase: phrase, replacement: replacement, caseSensitive: caseSensitive)
                )
                saveDictionary()
            }
        }
        .sheet(item: $editingEntry) { entry in
            DictionaryEntryEditor(
                title: "Edit Dictionary Entry",
                phrase: entry.phrase,
                replacement: entry.replacement,
                caseSensitive: entry.caseSensitive
            ) { phrase, replacement, caseSensitive in
                if let i = dictionaryEntries.firstIndex(where: { $0.id == entry.id }) {
                    dictionaryEntries[i].phrase = phrase
                    dictionaryEntries[i].replacement = replacement
                    dictionaryEntries[i].caseSensitive = caseSensitive
                    saveDictionary()
                }
            }
        }
    }

    // MARK: - Personal dictionary rows & helpers

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
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
                    .help("Matches case exactly")
            }
            Spacer(minLength: 8)
            // Explicit reorder buttons — drag-reorder inside a grouped Form is
            // unreliable on macOS, and order is meaningful (entries apply top-down).
            Button { moveDictionaryEntry(at: index, by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")
            Button { moveDictionaryEntry(at: index, by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == dictionaryEntries.count - 1)
            .help("Move down")
            Button { editingEntry = entry } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button { deleteDictionaryEntry(id: entry.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
    }

    private func saveDictionary() {
        ModelManager.dictionaryEntries = dictionaryEntries
    }

    private func moveDictionaryEntry(at index: Int, by offset: Int) {
        let target = index + offset
        guard dictionaryEntries.indices.contains(index),
              dictionaryEntries.indices.contains(target) else { return }
        dictionaryEntries.swapAt(index, target)
        saveDictionary()
    }

    private func deleteDictionaryEntry(id: UUID) {
        dictionaryEntries.removeAll { $0.id == id }
        saveDictionary()
    }

    /// Single source of truth for the displayed version. Reads
    /// CFBundleShortVersionString from Info.plist so bumping the plist
    /// is all that's required at release time.
    private var appVersionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(v)"
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

            TextField("Spoken phrase (what the transcriber hears)", text: $phrase)
                .textFieldStyle(.roundedBorder)
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
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.95, green: 0.66, blue: 0.10).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.95, green: 0.66, blue: 0.10).opacity(0.28), lineWidth: 0.6)
        )
    }
}
