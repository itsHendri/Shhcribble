import Foundation
import CoreGraphics

/// The two sizes a sticky panel comes in.
///
/// **Free resize was retired on 2026-08-28** in favour of two deliberate sizes
/// (Trace's discipline, and Wispr's compact↔expand): a fiddly drag edge on a
/// small floating card bought nothing, and every pixel of the old persisted
/// frame was a decision the user had to keep making. Compact is the note you
/// glance at; expanded is the one you write in.
enum StickyPanelMode: String, CaseIterable {
    case compact, expanded

    var size: CGSize {
        switch self {
        case .compact:  return CGSize(width: 320, height: 260)
        case .expanded: return CGSize(width: 520, height: 560)
        }
    }

    var toggled: StickyPanelMode { self == .compact ? .expanded : .compact }

    /// The glyph for the control that switches *to the other* mode.
    var toggleIcon: String {
        self == .compact ? "arrow.up.left.and.arrow.down.right"
                         : "arrow.down.right.and.arrow.up.left"
    }

    var toggleHelp: String { self == .compact ? "Expand" : "Collapse" }
}

/// Pure frame maths for the sticky panel, kept out of the window so the part
/// that is easy to get wrong — AppKit's bottom-left origin — is testable.
enum StickyPanelGeometry {

    /// The frame `current` becomes at `mode`, **anchored at its top-left
    /// corner** and clamped to `visibleFrame`.
    ///
    /// Top-left is the anchor because that is where the tab strip is: the tab
    /// you are reading must not move when you expand, and growing downward from
    /// the title is what every expanding panel does. AppKit's origin is
    /// *bottom*-left, so holding the top edge means moving the origin down by
    /// the height difference — the sign error this function exists to contain.
    ///
    /// The clamp then keeps the whole panel on screen, which is what makes
    /// expanding near the bottom edge push it up rather than off.
    static func frame(_ current: CGRect,
                      at mode: StickyPanelMode,
                      in visibleFrame: CGRect) -> CGRect {
        let size = mode.size
        var origin = CGPoint(x: current.minX, y: current.maxY - size.height)
        origin = clamp(origin: origin, size: size, in: visibleFrame)
        return CGRect(origin: origin, size: size)
    }

    /// Keep a panel of `size` fully inside `visibleFrame` where it can be.
    ///
    /// A panel larger than the screen is pinned to the top-left rather than
    /// pushed off it: `max` runs last so it wins the tie, which is what stops a
    /// too-tall expanded panel from hiding its own tab strip above the menu bar.
    static func clamp(origin: CGPoint, size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: max(min(origin.x, visibleFrame.maxX - size.width), visibleFrame.minX),
            y: max(min(origin.y, visibleFrame.maxY - size.height), visibleFrame.minY)
        )
    }
}
