import XCTest
@testable import Shhhcribble

/// Pins the pure half of the Feedback tab — body assembly and `mailto:` encoding.
/// The diagnostics *values* depend on the host machine, so they're not asserted
/// here; the invariant that matters (no transcript content ever leaks) is
/// structural: `plainText` only ever contains the fields the caller passed plus
/// the diagnostics string the caller passed.
final class FeedbackReportTests: XCTestCase {

    private func report(_ kind: FeedbackReport.Kind,
                        _ fields: [String],
                        diagnostics: String = "DIAGNOSTICS_BLOCK") -> FeedbackReport {
        FeedbackReport(kind: kind, fields: fields, diagnostics: diagnostics)
    }

    // MARK: - Kind metadata

    func testBugSubjectAndLabels() {
        XCTAssertEqual(FeedbackReport.Kind.bug.subject, "Shhhcribble bug report")
        XCTAssertEqual(FeedbackReport.Kind.bug.fieldLabels,
                       ["What happened", "What you expected", "Steps to reproduce"])
    }

    func testFeatureSubjectAndLabels() {
        XCTAssertEqual(FeedbackReport.Kind.feature.subject, "Shhhcribble feature request")
        XCTAssertEqual(FeedbackReport.Kind.feature.fieldLabels,
                       ["What you'd like", "What problem it solves", "Who it's for"])
    }

    // MARK: - plainText

    func testPlainTextContainsEachLabelAndValue() {
        let r = report(.bug, ["it crashed", "no crash", "press hotkey"])
        let text = r.plainText
        for label in FeedbackReport.Kind.bug.fieldLabels {
            XCTAssertTrue(text.contains(label), "missing label \(label)")
        }
        XCTAssertTrue(text.contains("it crashed"))
        XCTAssertTrue(text.contains("no crash"))
        XCTAssertTrue(text.contains("press hotkey"))
        XCTAssertTrue(text.contains("— Diagnostics —"))
        XCTAssertTrue(text.contains("DIAGNOSTICS_BLOCK"))
    }

    func testPlainTextUsesEmDashForBlankFields() {
        let r = report(.feature, ["", "  ", "designers"])
        let text = r.plainText
        // Blank / whitespace-only answers render as a placeholder, not nothing.
        XCTAssertTrue(text.contains("What you'd like:\n—"))
        XCTAssertTrue(text.contains("designers"))
    }

    func testPlainTextTrimsFieldWhitespace() {
        let r = report(.bug, ["  spaced  ", "", ""])
        XCTAssertTrue(r.plainText.contains("What happened:\nspaced"))
    }

    func testPlainTextTracksKind() {
        // Switching kind changes which labels appear — a bug report never leaks
        // feature labels and vice-versa.
        XCTAssertTrue(report(.bug, ["a", "b", "c"]).plainText.contains("Steps to reproduce"))
        XCTAssertFalse(report(.bug, ["a", "b", "c"]).plainText.contains("Who it's for"))
        XCTAssertTrue(report(.feature, ["a", "b", "c"]).plainText.contains("Who it's for"))
    }

    // MARK: - mailtoURL

    func testMailtoURLBasics() throws {
        let r = report(.bug, ["x", "y", "z"])
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        XCTAssertEqual(url.scheme, "mailto")
        let str = url.absoluteString
        XCTAssertTrue(str.hasPrefix("mailto:test@example.com?"))
        XCTAssertTrue(str.contains("subject="))
        XCTAssertTrue(str.contains("body="))
    }

    func testMailtoURLEncodesSubject() throws {
        let r = report(.bug, ["", "", ""])
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        // "Shhhcribble bug report" — spaces must be %20, not raw or "+".
        XCTAssertTrue(url.absoluteString.contains("Shhhcribble%20bug%20report"))
    }

    func testMailtoURLEncodesNewlinesAndSpaces() throws {
        let r = report(.bug, ["line one", "", ""], diagnostics: "d")
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        let str = url.absoluteString
        XCTAssertTrue(str.contains("%0A"), "newlines should encode to %0A")
        XCTAssertTrue(str.contains("line%20one"), "spaces should encode to %20")
    }

    func testMailtoURLEncodesAmpersandInsideValue() throws {
        // A field value with reserved characters must not split the query into
        // extra parameters — `&` has to be percent-encoded inside the body.
        let r = report(.bug, ["tom & jerry", "", ""])
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        let str = url.absoluteString
        XCTAssertTrue(str.contains("%26"), "ampersand should encode to %26")
        // Exactly one bare `&` (the subject/body separator), none from the value.
        XCTAssertEqual(str.filter { $0 == "&" }.count, 1)
    }

    func testMailtoURLBodyMatchesPlainText() throws {
        // The email body and Copy-report share one source, so decoding the body
        // query item must reproduce plainText verbatim.
        let r = report(.feature, ["want", "solves", "for"], diagnostics: "diag\nline")
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(comps.queryItems?.first(where: { $0.name == "body" })?.value)
        XCTAssertEqual(body, r.plainText)
    }
}
