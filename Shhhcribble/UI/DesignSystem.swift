import SwiftUI

/// Central design tokens for the Transcription Studio panes.
///
/// Single source of truth so section titles, neutral fills and pane insets stay
/// consistent across **Settings / Dictionary / Feedback** instead of being set —
/// and guessed — inline per screen. If a value needs tuning, change it here once
/// and every screen follows.
enum DesignSystem {

    /// The section-title font for every pane's section headers. Applied explicitly
    /// to each grouped-`Form` header *and* the custom Feedback labels so all three
    /// screens render identically. We pin our own value on purpose: the macOS
    /// grouped-`Form` header default is undocumented and varies by OS version, so
    /// matching it by eye is unreliable.
    static let sectionTitleFont: Font = .system(size: 13, weight: .semibold)

    /// Neutral fill for a custom input/read-only box (lighter than the rail/list
    /// selection so boxes read as containers, not selections).
    static let boxFill = Color.primary.opacity(0.03)
    /// Hairline stroke around a custom input box.
    static let boxStroke = Color.primary.opacity(0.08)
    /// Corner radius for boxes and neutral controls (matches the rail-tab fill).
    static let boxCornerRadius: CGFloat = 7

    /// Content insets for a **custom** (non-`Form`) pane, chosen so it lines up
    /// with the grouped `Form` panes when switching rail tabs (no vertical jump).
    static let paneTopInset: CGFloat = 20
    static let paneHorizontalInset: CGFloat = 20
    static let paneBottomInset: CGFloat = 24

    /// Leading inset for a custom section title so it sits slightly in from its box
    /// edge, the way grouped-`Form` headers align with their card content.
    static let sectionTitleLeadingInset: CGFloat = 12
}

extension Font {
    /// `.font(.sectionTitle)` — the shared section-title font. See
    /// `DesignSystem.sectionTitleFont`.
    static let sectionTitle = DesignSystem.sectionTitleFont
}
