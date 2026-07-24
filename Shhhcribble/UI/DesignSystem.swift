import SwiftUI
import AppKit

/// Central design tokens for the app.
///
/// Single source of truth so type, neutral fills, radii, shadows and motion
/// stay consistent instead of being guessed inline per screen. If a value needs
/// tuning, change it here once and every screen follows.
enum DesignSystem {

    // MARK: - Type

    /// The section-title font for every pane's section headers. Applied
    /// explicitly to each grouped-`Form` header *and* the custom panes that
    /// mimic one, so all screens render identically. We pin our own value on
    /// purpose: the macOS grouped-`Form` header default is undocumented and
    /// varies by OS version, so matching it by eye is unreliable.
    static let sectionTitleFont: Font = .system(size: 13, weight: .semibold)

    /// Chrome text sizes. These name the values the app already uses rather
    /// than re-tuning a visual design that's been signed off — the point is to
    /// remove the "which of 11, 11.5, 12 do I pick?" question, not to restyle.
    /// Content inside a note uses `NoteTextStyle` instead.
    enum ChromeText {
        /// Row titles, buttons, body copy in panes.
        static let body: CGFloat = 13
        /// Compact controls and secondary buttons.
        static let control: CGFloat = 12
        /// Supporting and caption text.
        static let secondary: CGFloat = 11
        /// Inline glyphs and micro-labels.
        static let micro: CGFloat = 10
        /// Empty-state and banner icons.
        static let icon: CGFloat = 28
    }

    // MARK: - Neutral fills & hairlines
    //
    // All expressed as opacities over `Color.primary`, so they adapt to the
    // appearance automatically.

    /// Input / read-only container fill — lighter than any selection so boxes
    /// read as containers, not selections.
    static let fillSubtle: Double = 0.03
    /// List-row hover *and* selection — deliberately the same value so the two
    /// read as one affordance.
    static let fillHover: Double = 0.04
    /// Rail-tab selection — a step above the list so the two form a hierarchy.
    static let fillActive: Double = 0.09
    /// Hairline around a box or card.
    static let strokeSubtle: Double = 0.08
    /// Outlined control (the search pill) — needs to read as an affordance
    /// rather than share the neutral grey of the selections.
    static let strokeStrong: Double = 0.15

    /// Neutral fill for a custom input/read-only box.
    static let boxFill = Color.primary.opacity(fillSubtle)
    /// Hairline stroke around a custom input box.
    static let boxStroke = Color.primary.opacity(strokeSubtle)

    // MARK: - Shadows

    static let shadowSoft: Double = 0.12      // toasts, floating capsules
    static let shadowCard: Double = 0.22      // sticky notes
    static let shadowBanner: Double = 0.28    // top-right banners

    // MARK: - Radii
    //
    // Four steps, by role. (The soundwave bar keeps its own 2pt radius — that
    // is a drawn shape, not a container.)

    /// Small inline badge (a keycap-style chip).
    static let radiusBadge: CGFloat = 3
    /// Rows, boxes, and controls — the workhorse.
    static let radiusControl: CGFloat = 7
    /// Floating cards (sticky notes).
    static let radiusCard: CGFloat = 12
    /// Top-right banners.
    static let radiusBanner: CGFloat = 16

    /// Corner radius for boxes and neutral controls.
    static let boxCornerRadius: CGFloat = radiusControl

    // MARK: - Motion

    /// Short state flips — hover, overlay in/out.
    static let motionQuick: TimeInterval = 0.15
    /// Standard transitions — toast dismissal, pane changes.
    static let motionStandard: TimeInterval = 0.25
    /// The house spring, for anything that presents or springs into place.
    static let springStandard: Animation = .spring(response: 0.28, dampingFraction: 0.8)

    /// True when the user has asked the system to reduce motion.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Wrap any animation so it degrades to an instant change when the user has
    /// Reduce Motion on. `withAnimation` and `.animation` both accept the
    /// resulting optional, so call sites read the same either way.
    static func motion(_ animation: Animation) -> Animation? {
        prefersReducedMotion ? nil : animation
    }

    // MARK: - Pane insets

    /// Content insets for a **custom** (non-`Form`) pane, chosen so it lines up
    /// with the grouped `Form` panes when switching rail tabs (no vertical jump).
    static let paneTopInset: CGFloat = 20
    static let paneHorizontalInset: CGFloat = 20
    static let paneBottomInset: CGFloat = 24

    /// Leading inset for a custom section title so it sits slightly in from its
    /// box edge, the way grouped-`Form` headers align with their card content.
    static let sectionTitleLeadingInset: CGFloat = 12
}

extension Font {
    /// `.font(.sectionTitle)` — the shared section-title font. See
    /// `DesignSystem.sectionTitleFont`.
    static let sectionTitle = DesignSystem.sectionTitleFont
}

/// The app's type scale, used for the content *inside* a note — one ramp,
/// largest to smallest, applied per paragraph.
///
/// All five are the **system font (San Francisco)**, which is what the rest of
/// the app uses; only size and weight change. Keeping one family is the point:
/// a note assembled from several sources should still read as one document.
///
/// The three heading steps carry weight as well as size — a "title" that is
/// only larger, not heavier, doesn't read as a title next to body text. Sizes
/// follow a roughly 1.3 ratio so no two adjacent steps are hard to tell apart
/// (an earlier 13/11 pairing was 2pt and effectively invisible in running text).
enum NoteTextStyle: String, CaseIterable, Identifiable {
    case display, title, subtitle, paragraph, caption

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display:   return "Display"
        case .title:     return "Title"
        case .subtitle:  return "Subtitle"
        case .paragraph: return "Paragraph"
        case .caption:   return "Caption"
        }
    }

    var size: CGFloat {
        switch self {
        case .display:   return 28
        case .title:     return 22
        case .subtitle:  return 17
        case .paragraph: return 13
        case .caption:   return 10
        }
    }

    var weight: NSFont.Weight {
        switch self {
        case .display, .title:  return .bold
        case .subtitle:         return .semibold
        case .paragraph, .caption: return .regular
        }
    }

    var font: NSFont { .systemFont(ofSize: size, weight: weight) }

    /// SwiftUI equivalent, so chrome can borrow a ramp step where it fits.
    var swiftUIFont: Font {
        .system(size: size, weight: Font.Weight(nsWeight: weight))
    }

    /// ⌘1 … ⌘5, largest to smallest.
    var shortcutKey: String { String(NoteTextStyle.allCases.firstIndex(of: self)! + 1) }

    /// The step a paragraph currently is, by size — used to tick the active
    /// item in the Style menu. Nil when the size matches no step (mid-edit or
    /// pasted content that hasn't been restyled).
    static func matching(size: CGFloat) -> NoteTextStyle? {
        allCases.first { abs($0.size - size) < 0.5 }
    }

    /// The step for text that is `ratio` times the size of its document's own
    /// body text.
    ///
    /// **Relative, not absolute, on purpose.** Mapping a pasted size straight
    /// to the nearest step breaks on the most common case there is: browser
    /// body text is typically 16px, which is nearest to `.subtitle`, so an
    /// ordinary paste would arrive as a page of semibold subtitles. What makes
    /// something a heading is that it is larger *than the surrounding text*.
    ///
    /// Thresholds are the midpoints between this ramp's own ratios against
    /// `.paragraph` (2.15, 1.69, 1.31, 1.0, 0.77).
    static func step(forRatio ratio: CGFloat) -> NoteTextStyle {
        switch ratio {
        case 1.92...: return .display
        case 1.50...: return .title
        case 1.15...: return .subtitle
        case 0.89...: return .paragraph
        default:      return .caption
        }
    }
}

private extension Font.Weight {
    init(nsWeight: NSFont.Weight) {
        switch nsWeight {
        case .bold:     self = .bold
        case .semibold: self = .semibold
        case .medium:   self = .medium
        default:        self = .regular
        }
    }
}
