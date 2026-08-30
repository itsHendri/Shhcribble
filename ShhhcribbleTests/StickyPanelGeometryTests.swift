import XCTest
import CoreGraphics
@testable import Shhhcribble

/// Tests for the sticky panel's two-size geometry.
///
/// The sign error this guards is AppKit's: the origin is **bottom**-left, so
/// holding the *top* edge while the height changes means moving the origin, and
/// getting it backwards makes an expanding panel grow upward off the screen.
final class StickyPanelGeometryTests: XCTestCase {

    /// A typical laptop screen with the menu bar excluded.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 850)

    func testExpandingHoldsTheTopLeftCorner() {
        let compact = CGRect(x: 200, y: 400,
                             width: StickyPanelMode.compact.size.width,
                             height: StickyPanelMode.compact.size.height)
        let expanded = StickyPanelGeometry.frame(compact, at: .expanded, in: screen)

        XCTAssertEqual(expanded.minX, compact.minX, "the left edge must not move")
        XCTAssertEqual(expanded.maxY, compact.maxY, "and neither must the top edge")
        XCTAssertEqual(expanded.size, StickyPanelMode.expanded.size)
    }

    func testCollapsingAlsoHoldsTheTopLeftCorner() {
        let expanded = CGRect(x: 300, y: 100,
                              width: StickyPanelMode.expanded.size.width,
                              height: StickyPanelMode.expanded.size.height)
        let compact = StickyPanelGeometry.frame(expanded, at: .compact, in: screen)

        XCTAssertEqual(compact.minX, expanded.minX)
        XCTAssertEqual(compact.maxY, expanded.maxY)
        XCTAssertEqual(compact.size, StickyPanelMode.compact.size)
    }

    /// Expanding near the bottom of the screen must push the panel up rather
    /// than let it hang off — the whole point of clamping after the anchor.
    func testExpandingNearTheBottomEdgePushesItBackOnScreen() {
        let compact = CGRect(x: 100, y: 10,
                             width: StickyPanelMode.compact.size.width,
                             height: StickyPanelMode.compact.size.height)
        let expanded = StickyPanelGeometry.frame(compact, at: .expanded, in: screen)

        XCTAssertGreaterThanOrEqual(expanded.minY, screen.minY)
        XCTAssertLessThanOrEqual(expanded.maxY, screen.maxY)
    }

    func testExpandingNearTheRightEdgePullsItBackOnScreen() {
        let compact = CGRect(x: screen.maxX - 340, y: 400,
                             width: StickyPanelMode.compact.size.width,
                             height: StickyPanelMode.compact.size.height)
        let expanded = StickyPanelGeometry.frame(compact, at: .expanded, in: screen)

        XCTAssertLessThanOrEqual(expanded.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(expanded.minX, screen.minX)
    }

    /// A panel taller than the screen keeps its **top** edge visible, because
    /// that is where the tab strip is — the panel's only chrome. AppKit's origin
    /// is bottom-left, so top-aligned means an origin *below* `minY`; asserting
    /// `minY` here (as an earlier version did) actually pins the bottom and
    /// pushes the tab strip off the top of the screen.
    func testAPanelLargerThanTheScreenKeepsItsTopLeftVisible() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
        let size = StickyPanelMode.expanded.size
        let origin = StickyPanelGeometry.clamp(
            origin: CGPoint(x: -50, y: -50), size: size, in: tiny)

        XCTAssertEqual(origin.x, tiny.minX, "left edge visible")
        XCTAssertEqual(origin.y + size.height, tiny.maxY, "and the TOP edge visible")
        XCTAssertLessThan(origin.y, tiny.minY, "which necessarily hangs off the bottom")
    }

    /// The same rule through the frame API, which is how it's actually reached.
    func testExpandingOnAShortScreenKeepsTheTabStripVisible() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 400)
        let compact = CGRect(x: 100, y: 100,
                             width: StickyPanelMode.compact.size.width,
                             height: StickyPanelMode.compact.size.height)
        let expanded = StickyPanelGeometry.frame(compact, at: .expanded, in: short)

        XCTAssertEqual(expanded.maxY, short.maxY, "the top edge stays on screen")
    }

    /// Toggling twice must return the panel exactly where it started, or the
    /// panel walks across the screen as you switch modes.
    func testTogglingTwiceIsIdentityAwayFromTheEdges() {
        let start = CGRect(x: 400, y: 300,
                           width: StickyPanelMode.compact.size.width,
                           height: StickyPanelMode.compact.size.height)
        let there = StickyPanelGeometry.frame(start, at: .expanded, in: screen)
        let back = StickyPanelGeometry.frame(there, at: .compact, in: screen)

        XCTAssertEqual(back, start)
    }

    func testModeToggleAlternatesAndNamesTheOtherSize() {
        XCTAssertEqual(StickyPanelMode.compact.toggled, .expanded)
        XCTAssertEqual(StickyPanelMode.expanded.toggled, .compact)
        XCTAssertEqual(StickyPanelMode.compact.toggleHelp, "Expand")
        XCTAssertEqual(StickyPanelMode.expanded.toggleHelp, "Collapse")
        XCTAssertNotEqual(StickyPanelMode.compact.toggleIcon,
                          StickyPanelMode.expanded.toggleIcon)
    }

    /// The mode is persisted by raw value, so renaming a case silently resets
    /// every user's panel to compact.
    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(StickyPanelMode.compact.rawValue, "compact")
        XCTAssertEqual(StickyPanelMode.expanded.rawValue, "expanded")
        XCTAssertEqual(StickyPanelMode(rawValue: "expanded"), .expanded)
    }
}
