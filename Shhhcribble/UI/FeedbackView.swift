import SwiftUI
import AppKit

// MARK: - FeedbackReport (pure, testable)

/// The value type behind the Feedback form. Kept free of SwiftUI/UI state so the
/// body-assembly and `mailto:` encoding can be unit-tested (mirrors the
/// `DictionaryImport` / `PromptFence` "extract the pure logic" pattern).
///
/// Both the composed email body and the "Copy" clipboard text come from the
/// single `plainText` property, so they can never diverge. The version block is
/// version/OS/hardware/pref facts only — **never** transcript content.
struct FeedbackReport {
    /// The prompts shown above each answer field, in order. General (not
    /// bug-vs-feature specific) so a single form covers any kind of feedback.
    static let fieldLabels = [
        "What's on your mind?",
        "What were you trying to do?",
        "Anything else we should know?"
    ]

    /// Email subject line — also the title line at the top of the report body so a
    /// pasted copy is self-identifying (there's no subject line on a clipboard).
    static let subject = "Shhhcribble feedback"

    /// Where the user can send the report. `mailto:` forces the default mail
    /// client (Apple Mail), which not everyone uses — the web options open a
    /// prefilled compose window in the default browser instead.
    enum MailClient: String, CaseIterable, Identifiable {
        case gmail = "Gmail"
        case appleMail = "Apple Mail"
        case outlook = "Outlook"
        var id: String { rawValue }
    }

    /// Free-text answers, positionally aligned with `fieldLabels`.
    var fields: [String]
    /// The version block (auto-filled, read-only in the UI).
    var diagnostics: String

    /// The full report — a title line, the labelled answers, then a version block.
    /// The single source of truth for every email body AND the clipboard copy, so
    /// they can never diverge.
    var plainText: String {
        var out = "\(Self.subject)\n\n"
        for (i, label) in Self.fieldLabels.enumerated() {
            let value = i < fields.count ? fields[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            out += "\(label)\n\(value.isEmpty ? "—" : value)\n\n"
        }
        let diag = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "— Version —\n\(diag)"
        return out
    }

    /// A compose URL for the chosen service, prefilled with the subject + body.
    /// Values are percent-encoded against a restricted query set so `&`, `?`, `+`,
    /// `/`, `=`, spaces and newlines all encode inside the value rather than
    /// terminating or corrupting the query.
    func composeURL(_ client: MailClient, to recipient: String) -> URL? {
        guard let su = Self.encode(Self.subject), let bo = Self.encode(plainText) else { return nil }
        switch client {
        case .appleMail:
            return URL(string: "mailto:\(recipient)?subject=\(su)&body=\(bo)")
        case .gmail:
            return URL(string: "https://mail.google.com/mail/?view=cm&fs=1&to=\(recipient)&su=\(su)&body=\(bo)")
        case .outlook:
            return URL(string: "https://outlook.live.com/mail/0/deeplink/compose?to=\(recipient)&subject=\(su)&body=\(bo)")
        }
    }

    /// Convenience for the default mail client (Apple Mail via `mailto:`).
    func mailtoURL(to recipient: String) -> URL? { composeURL(.appleMail, to: recipient) }

    private static func encode(_ s: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?+/=")
        return s.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    // MARK: Version block assembly

    /// Builds the auto-filled version/system block. Reads only version/OS/hardware
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
    @Published var fields: [String] = ["", "", ""]
    @Published var diagnosticsText = ""
    /// Guards the one-time version-block seed; persists across tab switches.
    @Published var didSeedDiagnostics = false
}

// MARK: - FeedbackView

/// The Feedback rail tab — a single general feedback form. Fill in the answers and
/// either open a prefilled email (`mailto:`) or copy the report to the clipboard.
/// `mailto:` is deliberate: the repo is public GPLv3, so no API key or backend
/// endpoint can ship — the user sees exactly what leaves the machine and presses
/// Send themself.
struct FeedbackView: View {
    /// Where reports are addressed. Intentionally public (this is committed to a
    /// public repo); there is no secret here to protect.
    private static let recipient = "hvanniekerk.14@gmail.com"

    @ObservedObject var draft: FeedbackDraft

    @State private var copiedToast = false
    @State private var copiedToastTask: Task<Void, Never>?
    @State private var showingMailChooser = false

    // Shared design tokens (see DesignSystem) — one source of truth so the
    // section titles / boxes / insets match Settings & Dictionary exactly.
    private let boxFill = DesignSystem.boxFill
    private let boxStroke = DesignSystem.boxStroke
    private let radius = DesignSystem.boxCornerRadius
    private let titleInset = DesignSystem.sectionTitleLeadingInset

    private var report: FeedbackReport {
        FeedbackReport(fields: draft.fields, diagnostics: draft.diagnosticsText)
    }

    // Plain scrolling layout — deliberately NOT a grouped Form, which nested each
    // section in its own card (and the inputs in a second card → card-in-card).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Three general answer fields — real editable text boxes so the
                // user writes in the app; the email is prefilled from these.
                ForEach(0..<3, id: \.self) { i in
                    fieldEditor(index: i, label: FeedbackReport.fieldLabels[i])
                }

                versionSection

                // Plain text buttons, no icons — matching the Dictionary page.
                HStack(spacing: 10) {
                    Button("Send via Email") { showingMailChooser = true }
                    Button("Copy") { copyReport() }
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, DesignSystem.paneTopInset)
            .padding(.horizontal, DesignSystem.paneHorizontalInset)
            .padding(.bottom, DesignSystem.paneBottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) { copiedToastView }
        .confirmationDialog("Send with which email?", isPresented: $showingMailChooser, titleVisibility: .visible) {
            ForEach(FeedbackReport.MailClient.allCases) { client in
                Button(client.rawValue) { openMail(client) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Opens a prefilled draft — review it and press Send. Gmail and Outlook open in your browser.")
        }
        .onAppear {
            // Seed the (read-only) version block once; the guard lives on the
            // draft so it holds across tab switches too.
            if !draft.didSeedDiagnostics {
                draft.diagnosticsText = FeedbackReport.diagnostics()
                draft.didSeedDiagnostics = true
            }
        }
        .onDisappear { copiedToastTask?.cancel() }
    }

    // MARK: - Field editor

    @ViewBuilder
    private func fieldEditor(index: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.sectionTitle)
                .padding(.leading, titleInset)
            ZStack(alignment: .topLeading) {
                // Placeholder and the editor's text share the same origin: both
                // sit at the box's inner top-left plus the text view's 5pt line-
                // fragment inset, so the cursor lines up with "Type your answer…".
                if draft.fields[index].isEmpty {
                    Text("Type your answer…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: fieldBinding(index))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(boxFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(boxStroke, lineWidth: 1))
        }
    }

    private func fieldBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < draft.fields.count ? draft.fields[i] : "" },
            set: { if i < draft.fields.count { draft.fields[i] = $0 } }
        )
    }

    // MARK: - Version (read-only)

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Version")
                .font(.sectionTitle)
                .padding(.leading, titleInset)
            Text(draft.diagnosticsText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(boxFill))
        }
    }

    // MARK: - Actions

    private func openMail(_ client: FeedbackReport.MailClient) {
        // Open a prefilled compose window in the chosen service. If it can't open
        // (no default mail client / browser, or a malformed URL), don't leave the
        // action dead — fall back to copying so the report isn't lost.
        if let url = report.composeURL(client, to: Self.recipient), NSWorkspace.shared.open(url) {
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
                .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func flashCopied() {
        copiedToastTask?.cancel()
        withAnimation(DesignSystem.motion(.spring(response: 0.3, dampingFraction: 0.8))) { copiedToast = true }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(DesignSystem.motion(.easeOut(duration: 0.25))) { copiedToast = false }
        }
    }
}
