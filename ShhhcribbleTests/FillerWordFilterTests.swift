import XCTest
@testable import Shhhcribble

// NOTE: This file is a ready-to-use artifact, but the XCTest *target* is not yet
// wired into Shhhcribble.xcodeproj. Wiring it (a unit-test PBXNativeTarget hosted
// by the app + scheme test action, then switching CI from `build` to `test`) is
// the autonomous loop's first warm-up task — it's self-contained and exercises
// the build/CI gate. See CLAUDE.md "Autonomous development loop".

final class FillerWordFilterTests: XCTestCase {

    func testRemovesUm() {
        XCTAssertEqual(FillerWordFilter.filter("I um think so"), "I think so")
    }

    func testRemovesUhAndCollapsesWhitespace() {
        XCTAssertEqual(FillerWordFilter.filter("Well uh maybe"), "Well maybe")
    }

    func testRemovesParentheticalYouKnow() {
        XCTAssertEqual(FillerWordFilter.filter("I, you know, think"), "I think")
    }

    func testRemovesLeadingLike() {
        XCTAssertEqual(FillerWordFilter.filter("Like, that works"), "that works")
    }

    /// Whole-word boundaries: words that merely contain a filler substring stay intact.
    func testPreservesWordsContainingFillerSubstrings() {
        XCTAssertEqual(
            FillerWordFilter.filter("An umbrella under the umbrella"),
            "An umbrella under the umbrella"
        )
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(FillerWordFilter.filter(""), "")
    }
}
