import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Styles editor — its own left-nav tab in the Studio shell. Lets the user
/// pick which style shapes new dictations (Off / Default clean-up / a transform
/// style), manage their transform styles (add / edit / reorder / delete), and
/// import a `SKILL.md` as a style's instruction. Mirrors `DictionarySettingsView`
/// (grouped `Form`, up/down reorder buttons, sheet editors, destructive-confirm).
struct StylesView: View {
    @ObservedObject var store: TranscriptStore

    @State private var activeStyleID: String = ModelManager.activeStyleID
    @State private var showingAddSheet = false
    @State private var editingStyle: Style? = nil
    @State private var deletingStyle: Style? = nil
    @State private var importDraft: StyleDraft? = nil

    var body: some View {
        Form {
            // MARK: Active style
            Section {
                Picker("Active style", selection: $activeStyleID) {
                    Text("Off — no cleanup").tag(ActiveStyle.offID)
                    Text("Default clean-up").tag(ActiveStyle.defaultCleanupID)
                    ForEach(store.styles) { style in
                        Text(style.name).tag(style.id.uuidString)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: activeStyleID) { _, newValue in
                    guard newValue != ModelManager.activeStyleID else { return }
                    ModelManager.activeStyleID = newValue
                    if newValue != ActiveStyle.offID { TranscriptCleaner.prewarm() }
                }

                if case .unavailable(let reason) = TranscriptCleaner.availability {
                    InlineWarning(message: "\(reason) Until then, dictation uses basic filler-word removal.")
                }
            } header: {
                Text("Active style").font(.sectionTitle)
            } footer: {
                Text("The active style shapes new dictations. A style with apps set below auto-activates when one of those apps is frontmost. File transcriptions always use Default clean-up.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // MARK: Your styles
            Section {
                if store.styles.isEmpty {
                    Text("No styles yet — add one or import a SKILL.md.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(Array(store.styles.enumerated()), id: \.element.id) { index, style in
                    styleRow(style: style, index: index)
                }
                HStack(spacing: 12) {
                    Button("Add Style…") { showingAddSheet = true }
                    Button("Import from file…") { importFromFile() }
                }
            } header: {
                Text("Your styles").font(.sectionTitle)
            } footer: {
                Text("Styles reshape your words for where they're going — an email, a chat message, code, bullets. They can rewrite freely, so they need Apple Intelligence (macOS 26); without it, dictation falls back to basic cleanup.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        // Re-sync when the window (re)appears and whenever the menu-bar quick-pick
        // changes the active style, so picker + menu never disagree.
        .onAppear { activeStyleID = ModelManager.activeStyleID }
        .onReceive(NotificationCenter.default.publisher(for: ModelManager.activeStyleDidChangeNotification)) { _ in
            activeStyleID = ModelManager.activeStyleID
        }
        .alert("Delete this style?", isPresented: Binding(
            get: { deletingStyle != nil },
            set: { if !$0 { deletingStyle = nil } }
        ), presenting: deletingStyle) { style in
            Button("Delete", role: .destructive) { deleteStyle(style) }
            Button("Cancel", role: .cancel) { }
        } message: { style in
            Text("“\(style.name)” will be removed. This can't be undone.")
        }
        .sheet(isPresented: $showingAddSheet) {
            StyleEditor(title: "Add Style") { name, prompt, apps in
                store.addStyle(Style(name: name, prompt: prompt, activationApps: apps))
            }
        }
        .sheet(item: $editingStyle) { style in
            StyleEditor(
                title: "Edit Style",
                name: style.name,
                prompt: style.prompt,
                activationApps: style.activationApps
            ) { name, prompt, apps in
                store.updateStyle(id: style.id, name: name, prompt: prompt, activationApps: apps)
            }
        }
        .sheet(item: $importDraft) { draft in
            StyleEditor(
                title: "Import Style",
                name: draft.name,
                prompt: draft.prompt
            ) { name, prompt, apps in
                store.addStyle(Style(name: name, prompt: prompt, activationApps: apps))
            }
        }
    }

    @ViewBuilder
    private func styleRow(style: Style, index: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(style.name)
                    .lineLimit(1).truncationMode(.tail)
                if !style.activationApps.isEmpty {
                    Text(activationSummary(style.activationApps))
                        .font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Button { store.moveStyle(at: index, by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")
            Button { store.moveStyle(at: index, by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == store.styles.count - 1)
            .help("Move down")
            Button { editingStyle = style } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button { deletingStyle = style } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
    }

    /// A short "activates in Mail, Slack…" line for a row's subtitle.
    private func activationSummary(_ bundleIDs: [String]) -> String {
        let names = bundleIDs.prefix(3).map { StyleAppInfo.displayName($0) }
        let suffix = bundleIDs.count > 3 ? " +\(bundleIDs.count - 3)" : ""
        return "Activates in " + names.joined(separator: ", ") + suffix
    }

    /// Delete a style; if it was the active selection, fall back to Default
    /// clean-up so the picker doesn't end up pointing at a removed row.
    private func deleteStyle(_ style: Style) {
        let wasActive = activeStyleID == style.id.uuidString
        store.deleteStyle(id: style.id)
        if wasActive {
            activeStyleID = ActiveStyle.defaultCleanupID   // onChange syncs ModelManager
        }
    }

    /// Pick a `.md` / `SKILL.md` and open the editor prefilled from it.
    private func importFromFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = SkillFileParser.parse(contents)
        let name = parsed.name ?? url.deletingPathExtension().lastPathComponent
        importDraft = StyleDraft(name: name, prompt: parsed.prompt)
    }
}

/// Transient prefill for the import sheet (needs `Identifiable` for `.sheet(item:)`).
struct StyleDraft: Identifiable {
    let id = UUID()
    var name: String
    var prompt: String
}

// MARK: - Style editor

/// Sheet used for Add / Edit / Import. Save is disabled until name + prompt both
/// have non-whitespace content.
private struct StyleEditor: View {
    let title: String
    @State private var name: String
    @State private var prompt: String
    @State private var activationApps: [String]
    let onSave: (String, String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss

    init(title: String,
         name: String = "",
         prompt: String = "",
         activationApps: [String] = [],
         onSave: @escaping (String, String, [String]) -> Void) {
        self.title = title
        _name = State(initialValue: name)
        _prompt = State(initialValue: prompt)
        _activationApps = State(initialValue: activationApps)
        self.onSave = onSave
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)

            TextField("Style name (e.g. Email, Slack)", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Instruction").font(.caption).foregroundColor(.secondary)
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("Describe how the transcript should be rewritten. It's applied as data-framed instructions the model reformats your words with — never obeyed literally.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Auto-activate in apps").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button { addApp() } label: { Label("Add app", systemImage: "plus") }
                        .controlSize(.small)
                }
                if activationApps.isEmpty {
                    Text("Optional — this style auto-selects when a chosen app is frontmost while you dictate.")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(activationApps, id: \.self) { bundleID in
                            appRow(bundleID)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmedName, trimmedPrompt, activationApps)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedPrompt.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func appRow(_ bundleID: String) -> some View {
        HStack(spacing: 8) {
            if let icon = StyleAppInfo.icon(bundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").foregroundColor(.secondary).frame(width: 16, height: 16)
            }
            Text(StyleAppInfo.displayName(bundleID))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button { activationApps.removeAll { $0 == bundleID } } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    /// Pick an application and add its bundle ID.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        if !activationApps.contains(id) { activationApps.append(id) }
    }
}

/// Resolve a bundle ID to a human app name + icon for display. Falls back to the
/// raw bundle ID when the app isn't installed on this Mac (a seeded preset may
/// name an app the user doesn't have).
enum StyleAppInfo {
    static func displayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func icon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
