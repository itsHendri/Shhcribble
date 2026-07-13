import SwiftUI
import AppKit

// MARK: - FeedbackReport (pure, testable)

/// The value type behind the Feedback tab. Kept free of SwiftUI/UI state so the
/// body-assembly and `mailto:` encoding can be unit-tested (mirrors the
/// `DictionaryImport` / `PromptFence` "extract the pure logic" pattern).
///
/// Both the composed email body and the "Copy report" clipboard text come from
/// the single `plainText` property, so they can never diverge. Diagnostics are
/// version/OS/hardware/pref facts only — **never** transcript content.
struct FeedbackReport {
    enum Kind: String, CaseIterable, Identifiable {
        case bug, feature
        var id: String { rawValue }

        /// Segmented-control label.
        var pickerLabel: String {
            switch self {
            case .bug:     return "Bug report"
            case .feature: return "Feature request"
            }
        }

        /// Email subject line.
        var subject: String {
            switch self {
            case .bug:     return "Shhhcribble bug report"
            case .feature: return "Shhhcribble feature request"
            }
        }

        /// The three prompt labels, in order, for this kind.
        var fieldLabels: [String] {
            switch self {
            case .bug:
                return ["What happened", "What you expected", "Steps to reproduce"]
            case .feature:
                return ["What you'd like", "What problem it solves", "Who it's for"]
            }
        }
    }

    var kind: Kind
    /// Free-text answers, positionally aligned with `kind.fieldLabels`.
    var fields: [String]
    /// The diagnostics block (auto-filled, user-editable before sending).
    var diagnostics: String

    /// The full report — labelled fields followed by a diagnostics block. This is
    /// the single source of truth for both the email body and the clipboard copy.
    var plainText: String {
        var out = ""
        let labels = kind.fieldLabels
        for (i, label) in labels.enumerated() {
            let value = i < fields.count ? fields[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            out += "\(label):\n\(value.isEmpty ? "—" : value)\n\n"
        }
        let diag = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "— Diagnostics —\n\(diag)"
        return out
    }

    /// A `mailto:` URL that opens the user's mail client prefilled with the
    /// subject + body. Values are percent-encoded against a restricted query set
    /// so `&`, `?`, `+`, `/`, spaces and newlines all encode inside the value
    /// rather than terminating or corrupting the query.
    func mailtoURL(to recipient: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?+/=")
        guard let s = kind.subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let b = plainText.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "mailto:\(recipient)?subject=\(s)&body=\(b)")
    }

    // MARK: Diagnostics assembly

    /// Builds the auto-filled diagnostics block. Reads only version/OS/hardware
    /// and prefs — nothing transcript-derived, so it's always safe to share.
    static func diagnostics() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        let model = hardwareModel()

        let ai: String
        switch TranscriptCleaner.availability {
        case .available:                 ai = "Available"
        case .unavailable(let reason):   ai = "Unavailable — \(reason)"
        }

        let modelName = ModelManager.availableModels
            .first(where: { $0.id == ModelManager.selectedModel })?.displayName
            ?? ModelManager.selectedModel

        let hotkey = ModelManager.selectedHotkey.symbol

        return """
        Shhhcribble v\(short) (build \(build))
        macOS \(os)
        Mac model: \(model)
        Apple Intelligence: \(ai)
        Model: \(modelName)
        Hotkey: \(hotkey)
        """
    }

    /// The hardware model identifier (e.g. "Mac15,6") via sysctl `hw.model`.
    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

// MARK: - FeedbackDraft

/// Holds the Feedback form's in-progress input. Owned by `TranscriptionsView` as a
/// `@StateObject` so a half-written report survives rail-tab switches: the detail
/// area is a `switch` that tears down and rebuilds `FeedbackView`, which would
/// reset plain `@State`. The window (and this draft) outlive that rebuild.
final class FeedbackDraft: ObservableObject {
    @Published var kind: FeedbackReport.Kind = .bug
    @Published var fields: [String] = ["", "", ""]
    @Published var diagnosticsText = ""
    /// Guards the one-time diagnostics seed; persists across tab switches so a
    /// user's edits to the diagnostics box are never re-stomped.
    @Published var didSeedDiagnostics = false
}

// MARK: - FeedbackView

/// The Feedback rail tab. Compose a bug report or feature request and either open
/// a prefilled email (`mailto:`) or copy the report to the clipboard. `mailto:` is
/// deliberate: the repo is public GPLv3, so no API key or backend endpoint can
/// ship — the user sees exactly what leaves the machine and presses Send themself.
struct FeedbackView: View {
    /// Where reports are addressed. Intentionally public (this is committed to a
    /// public repo); there is no secret here to protect.
    private static let recipient = "hvanniekerk.14@gmail.com"

    @ObservedObject var draft: FeedbackDraft

    @State private var copiedToast = false
    @State private var copiedToastTask: Task<Void, Never>?

    private var report: FeedbackReport {
        FeedbackReport(kind: draft.kind, fields: draft.fields, diagnostics: draft.diagnosticsText)
    }

    var body: some View {
        Form {
            Section {
                Picker("Report type", selection: $draft.kind) {
                    ForEach(FeedbackReport.Kind.allCases) { k in
                        Text(k.pickerLabel).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text("Reports open in your email app so you can review before sending — nothing is sent automatically.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                ForEach(Array(draft.kind.fieldLabels.enumerated()), id: \.offset) { i, label in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(label).fontWeight(.medium)
                        TextField(label, text: fieldBinding(i), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(2...6)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(draft.kind == .bug ? "Bug report" : "Feature request")
            }

            Section {
                TextEditor(text: $draft.diagnosticsText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 108)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Attached to your report to help debugging. Editable, and it never includes any of your transcribed text.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Button {
                        composeEmail()
                    } label: {
                        Label("Compose Email", systemImage: "envelope")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    Button {
                        copyReport()
                    } label: {
                        Label("Copy report", systemImage: "doc.on.doc")
                    }
                    .controlSize(.large)

                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .overlay(alignment: .bottom) { copiedToastView }
        // Bug and feature ask different questions, so answers must not carry over
        // under relabeled fields when the user flips the report type.
        .onChange(of: draft.kind) { _, _ in
            draft.fields = ["", "", ""]
        }
        .onAppear {
            // Seed once (guard lives on the draft, so this holds across tab
            // switches too) so the user's diagnostics edits aren't clobbered.
            if !draft.didSeedDiagnostics {
                draft.diagnosticsText = FeedbackReport.diagnostics()
                draft.didSeedDiagnostics = true
            }
        }
        .onDisappear { copiedToastTask?.cancel() }
    }

    private func fieldBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < draft.fields.count ? draft.fields[i] : "" },
            set: { if i < draft.fields.count { draft.fields[i] = $0 } }
        )
    }

    // MARK: - Actions

    private func composeEmail() {
        // Open the user's mail client with a prefilled draft. If there's no
        // configured mail client (or the URL is somehow malformed), don't leave
        // the primary button dead — fall back to copying so the report isn't lost.
        if let url = report.mailtoURL(to: Self.recipient), NSWorkspace.shared.open(url) {
            return
        }
        copyReport()
    }

    private func copyReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report.plainText, forType: .string)
        flashCopied()
    }

    // MARK: - Copied toast (shared recipe with the rest of the Studio)

    @ViewBuilder
    private var copiedToastView: some View {
        if copiedToast {
            Label("Copied", systemImage: "checkmark.circle.fill")
                .font(.callout).fontWeight(.medium)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func flashCopied() {
        copiedToastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copiedToast = true }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { copiedToast = false }
        }
    }
}
