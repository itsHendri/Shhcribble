import XCTest
@testable import Shhhcribble

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
