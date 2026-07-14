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

    // Neutral palette, shared with the rail/list selection so the whole Studio
    // reads as one system (rail-tab fill is primary@0.09 at radius 7).
    private let neutralFill = Color.primary.opacity(0.09)
    private let boxFill = Color.primary.opacity(0.05)
    private let boxStroke = Color.primary.opacity(0.10)
    private let radius: CGFloat = 7

    // Plain scrolling layout — deliberately NOT a grouped Form, which nested each
    // section in its own card (and the inputs in a second card → card-in-card).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Bug / Feature switcher — neutral (adaptive gray) selected segment,
                // matching the Transcript/Summary/Notes tabs, not the accent blue.
                Picker("Report type", selection: $draft.kind) {
                    ForEach(FeedbackReport.Kind.allCases) { k in
                        Text(k.pickerLabel).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Color(nsColor: .secondaryLabelColor))

                // The three answer fields — real editable text boxes so the user
                // writes directly in the app; the email is then prefilled from these.
                ForEach(0..<3, id: \.self) { i in
                    fieldEditor(index: i, label: draft.kind.fieldLabels[i])
                }

                diagnosticsSection

                // Neutral, rectangular call-to-action buttons — not boxed in a card.
                HStack(spacing: 10) {
                    ctaButton("Compose Email", systemImage: "envelope", action: composeEmail)
                    ctaButton("Copy report", systemImage: "doc.on.doc", action: copyReport)
                    Spacer(minLength: 0)
                }
                Text("Compose Email opens your mail app with everything filled in — just review and press Send.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) { copiedToastView }
        // Bug and feature ask different questions, so answers must not carry over
        // under relabeled fields when the user flips the report type.
        .onChange(of: draft.kind) { _, _ in
            draft.fields = ["", "", ""]
        }
        .onAppear {
            // Seed the (read-only) diagnostics once; the guard lives on the draft
            // so it holds across tab switches too.
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
            Text(label).font(.subheadline).fontWeight(.medium)
            ZStack(alignment: .topLeading) {
                TextEditor(text: fieldBinding(index))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                if draft.fields[index].isEmpty {
                    Text("Type your answer…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
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

    // MARK: - Diagnostics (read-only)

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics").font(.subheadline).fontWeight(.medium)
            Text(draft.diagnosticsText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(boxFill))
            Text("Attached automatically to help with debugging — never any of your transcribed text.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - CTA button

    private func ctaButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout).fontWeight(.medium)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(neutralFill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
