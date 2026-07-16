import XCTest
@testable import Shhhcribble

/// Pins the per-app / default style resolution and the cleanup→style migration
/// decision — both pure, AppKit-free logic.
final class StyleResolverTests: XCTestCase {

    private func style(_ name: String, apps: [String] = []) -> Style {
        Style(name: name, prompt: "p", activationApps: apps)
    }

    // MARK: - resolve (per-app override)

    func testFrontmostAppMatchWins() {
        let email = style("Email", apps: ["com.apple.mail"])
        let code = style("Code", apps: ["com.apple.dt.Xcode"])
        let resolved = StyleResolver.resolve(
            frontmostBundleID: "com.apple.dt.Xcode",
            activeStyleID: ActiveStyle.defaultCleanupID,
            styles: [email, code]
        )
        XCTAssertEqual(resolved, .custom(code))
    }

    func testFirstMatchingStyleWins() {
        // Two styles claim the same app — the earlier (lower position) one wins.
        let a = style("A", apps: ["com.foo.bar"])
        let b = style("B", apps: ["com.foo.bar"])
        let resolved = StyleResolver.resolve(
            frontmostBundleID: "com.foo.bar",
            activeStyleID: ActiveStyle.offID,
            styles: [a, b]
        )
        XCTAssertEqual(resolved, .custom(a))
    }

    func testNoAppMatchFallsThroughToDefault() {
        let email = style("Email", apps: ["com.apple.mail"])
        let resolved = StyleResolver.resolve(
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            activeStyleID: ActiveStyle.defaultCleanupID,
            styles: [email]
        )
        XCTAssertEqual(resolved, .defaultCleanup)
    }

    func testNilFrontmostUsesActiveStyle() {
        let slack = style("Slack", apps: ["com.tinyspeck.slackmacgap"])
        let resolved = StyleResolver.resolve(
            frontmostBundleID: nil,
            activeStyleID: slack.id.uuidString,
            styles: [slack]
        )
        XCTAssertEqual(resolved, .custom(slack))
    }

    func testEmptyFrontmostBundleIsIgnored() {
        let resolved = StyleResolver.resolve(
            frontmostBundleID: "",
            activeStyleID: ActiveStyle.offID,
            styles: [style("Email", apps: [""])]  // empty activation entry must not match
        )
        XCTAssertEqual(resolved, .off)
    }

    // MARK: - active(for:)

    func testActiveForOff() {
        XCTAssertEqual(StyleResolver.active(for: ActiveStyle.offID, styles: []), .off)
    }

    func testActiveForDefault() {
        XCTAssertEqual(StyleResolver.active(for: ActiveStyle.defaultCleanupID, styles: []), .defaultCleanup)
    }

    func testActiveForCustom() {
        let s = style("Notes")
        XCTAssertEqual(StyleResolver.active(for: s.id.uuidString, styles: [s]), .custom(s))
    }

    func testActiveForDeletedStyleFallsBackToDefault() {
        // An activeStyleID pointing at a style that no longer exists must not
        // silently become Off — it falls back to Default clean-up.
        let dangling = UUID().uuidString
        XCTAssertEqual(StyleResolver.active(for: dangling, styles: [style("Other")]), .defaultCleanup)
    }

    // MARK: - cleanup→style migration decision

    func testMigrationLeavesExistingSelectionAlone() {
        XCTAssertNil(ModelManager.migratedActiveStyleID(legacyCleanupEnabled: true, existingActiveID: ActiveStyle.offID))
    }

    func testMigrationNoLegacyKeyLeavesDefault() {
        XCTAssertNil(ModelManager.migratedActiveStyleID(legacyCleanupEnabled: nil, existingActiveID: nil))
    }

    func testMigrationLegacyOnMapsToDefaultCleanup() {
        XCTAssertEqual(
            ModelManager.migratedActiveStyleID(legacyCleanupEnabled: true, existingActiveID: nil),
            ActiveStyle.defaultCleanupID
        )
    }

    func testMigrationLegacyOffMapsToOff() {
        XCTAssertEqual(
            ModelManager.migratedActiveStyleID(legacyCleanupEnabled: false, existingActiveID: nil),
            ActiveStyle.offID
        )
    }
}
