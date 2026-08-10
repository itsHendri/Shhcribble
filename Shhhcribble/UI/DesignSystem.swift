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

// MARK: - Shared chrome components
//
// Small views that are *the same affordance* wherever they appear. They live
// beside the tokens because that is what they are: a token you can't express as
// a single value. Reach for these instead of re-stacking the modifiers.

/// The outlined search pill used at the head of every list column. Outlined
/// rather than filled on purpose — a neutral fill would read as a selection,
/// which is what the row highlights use.
struct SearchPill: View {
    @Binding var text: String
    let prompt: String
    /// Optional read-only text before the clear button — a result count, say.
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: DesignSystem.ChromeText.control))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if let trailing {
                Text(trailing)
                    .font(.system(size: DesignSystem.ChromeText.secondary))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(DesignSystem.strokeStrong), lineWidth: 1))
        .padding(10)
    }
}

/// The small neutral capsule that labels an item — a transcript's style, a
/// note's state, a card's type. Always quiet: neutral fill, secondary text, and
/// sized to its content so it never stretches inside a flexible row.
struct TagCapsule: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.caption2).fontWeight(.semibold)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(DesignSystem.strokeSubtle)))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// The transient capsule confirmation, and the state that drives it.
///
/// **Every action whose result isn't otherwise visible on screen flashes one**
/// — copy has always done it; pin joined 2026-08-10, because a glyph quietly
/// filling in is not enough feedback for something that moves an item to
/// another list and another tab.
///
/// This replaces what had become six hand-rolled copies of the same
/// spring-in / 1.4s / fade-out dance. Own one `ToastState` per pane, call
/// `flash(_:)`, and attach `.toast(state)` where you want it anchored.
@MainActor
final class ToastState: ObservableObject {
    @Published private(set) var message: String?

    private var task: Task<Void, Never>?

    func flash(_ message: String) {
        task?.cancel()
        withAnimation(DesignSystem.motion(.spring(response: 0.3, dampingFraction: 0.8))) {
            self.message = message
        }
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(DesignSystem.motion(.easeOut(duration: DesignSystem.motionStandard))) {
                self.message = nil
            }
        }
    }

    /// Call from `.onDisappear`; the modifier does this for you.
    func cancel() { task?.cancel() }
}

private struct ToastOverlay: ViewModifier {
    @ObservedObject var state: ToastState

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message = state.message {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.callout).fontWeight(.medium)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                        .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onDisappear { state.cancel() }
    }
}

extension View {
    /// Anchor a pane's toast at its bottom edge. See `ToastState`.
    func toast(_ state: ToastState) -> some View { modifier(ToastOverlay(state: state)) }
}

/// One always-visible action sitting inline in an item's meta line.
///
/// **Inline and permanent, not hover-revealed** (Hendri, 2026-08-10): having to
/// hover a row *and then* travel to an action to find out what it does made the
/// stream feel like a two-step. Quiet by default — tertiary, matching the meta
/// text it sits beside — so three of them on every row read as punctuation
/// rather than a toolbar. The hit area is the whole 20×18 slot, not the glyph.
struct InlineAction: View {
    let systemName: String
    let help: String
    let action: () -> Void

    init(_ systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DesignSystem.ChromeText.control))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One hover-revealed action in a list row's trailing slot.
///
/// **Neutral, never accent** (human's call, 2026-07-27): these appear under the
/// pointer on every row, and an accent glyph made hovering read like a
/// selection. Accent stays reserved for links and search-match highlights.
///
/// Sized so the hit area is the whole 26×24 slot rather than the glyph — a
/// 13pt symbol is a small target for something you have to travel across a row
/// to reach.
struct RowHoverButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    init(_ systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DesignSystem.ChromeText.body))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
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
