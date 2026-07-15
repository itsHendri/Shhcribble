import XCTest
@testable import Shhhcribble

/// Pins the pure half of the Feedback form — body assembly and `mailto:` encoding.
/// The version-block *values* depend on the host machine, so they're not asserted
/// here; the invariant that matters (no transcript content ever leaks) is
/// structural: `plainText` only ever contains the answers the caller passed plus
/// the diagnostics string the caller passed.
final class FeedbackReportTests: XCTestCase {

    private func report(_ fields: [String],
                        diagnostics: String = "DIAGNOSTICS_BLOCK") -> FeedbackReport {
        FeedbackReport(fields: fields, diagnostics: diagnostics)
    }

    // MARK: - Metadata

    func testSubjectAndLabels() {
        XCTAssertEqual(FeedbackReport.subject, "Shhhcribble feedback")
        XCTAssertEqual(FeedbackReport.fieldLabels.count, 3)
    }

    func testPlainTextStartsWithTitle() {
        // A self-identifying title so a pasted copy isn't anonymous.
        XCTAssertTrue(report(["a", "b", "c"]).plainText.hasPrefix("Shhhcribble feedback\n"))
    }

    // MARK: - plainText

    func testPlainTextContainsEachLabelAndValue() {
        let r = report(["it crashed", "opening a file", "on AirPods"])
        let text = r.plainText
        for label in FeedbackReport.fieldLabels {
            XCTAssertTrue(text.contains(label), "missing label \(label)")
        }
        XCTAssertTrue(text.contains("it crashed"))
        XCTAssertTrue(text.contains("opening a file"))
        XCTAssertTrue(text.contains("on AirPods"))
        XCTAssertTrue(text.contains("— Version —"))
        XCTAssertTrue(text.contains("DIAGNOSTICS_BLOCK"))
    }

    func testPlainTextUsesEmDashForBlankFields() {
        let r = report(["", "  ", "designers"])
        let text = r.plainText
        // Blank / whitespace-only answers render as a placeholder, not nothing.
        XCTAssertTrue(text.contains("\(FeedbackReport.fieldLabels[0])\n—"))
        XCTAssertTrue(text.contains("designers"))
    }

    func testPlainTextTrimsFieldWhitespace() {
        let r = report(["  spaced  ", "", ""])
        XCTAssertTrue(r.plainText.contains("\(FeedbackReport.fieldLabels[0])\nspaced"))
    }

    func testPlainTextToleratesShortFieldArray() {
        // Fewer than three answers still renders all three prompts (missing → —).
        let r = report(["only one"])
        let text = r.plainText
        for label in FeedbackReport.fieldLabels {
            XCTAssertTrue(text.contains(label))
        }
        XCTAssertTrue(text.contains("only one"))
    }

    // MARK: - mailtoURL

    func testMailtoURLBasics() throws {
        let r = report(["x", "y", "z"])
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        XCTAssertEqual(url.scheme, "mailto")
        let str = url.absoluteString
        XCTAssertTrue(str.hasPrefix("mailto:test@example.com?"))
        XCTAssertTrue(str.contains("subject="))
        XCTAssertTrue(str.contains("body="))
    }

    func testMailtoURLEncodesSubject() throws {
        let r = report(["", "", ""])
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        // "Shhhcribble feedback" — spaces must be %20, not raw or "+".
        XCTAssertTrue(url.absoluteString.contains("Shhhcribble%20feedback"))
    }

    func testMailtoURLEncodesNewlinesAndSpaces() throws {
        let r = report(["line one", "", ""], diagnostics: "d")
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        let str = url.absoluteString
        XCTAssertTrue(str.contains("%0A"), "newlines should encode to %0A")
        XCTAssertTrue(str.contains("line%20one"), "spaces should encode to %20")
    }

    func testMailtoURLEncodesAmpersandInsideValue() throws {
        // A field value with reserved characters must not split the query into
        // extra parameters — `&` has to be percent-encoded inside the body.
        let r = report(["tom & jerry", "", ""])
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        let str = url.absoluteString
        XCTAssertTrue(str.contains("%26"), "ampersand should encode to %26")
        // Exactly one bare `&` (the subject/body separator), none from the value.
        XCTAssertEqual(str.filter { $0 == "&" }.count, 1)
    }

    func testGmailURLIsWebComposeWithEncodedFields() throws {
        let r = report(["hi there", "", ""])
        let url = try XCTUnwrap(r.composeURL(.gmail, to: "test@example.com"))
        let str = url.absoluteString
        XCTAssertTrue(str.hasPrefix("https://mail.google.com/mail/?view=cm&fs=1&to=test@example.com"))
        XCTAssertTrue(str.contains("su=Shhhcribble%20feedback"))
        XCTAssertTrue(str.contains("body="))
        XCTAssertTrue(str.contains("hi%20there"))
    }

    func testOutlookURLIsWebCompose() throws {
        let url = try XCTUnwrap(report(["x", "", ""]).composeURL(.outlook, to: "test@example.com"))
        let str = url.absoluteString
        XCTAssertTrue(str.hasPrefix("https://outlook.live.com/mail/0/deeplink/compose"))
        XCTAssertTrue(str.contains("to=test@example.com"))
        XCTAssertTrue(str.contains("subject=Shhhcribble%20feedback"))
    }

    func testAppleMailComposeMatchesMailto() throws {
        // The .appleMail case and the mailtoURL convenience produce the same URL.
        let r = report(["a", "b", "c"])
        XCTAssertEqual(r.composeURL(.appleMail, to: "test@example.com"),
                       r.mailtoURL(to: "test@example.com"))
    }

    func testMailtoURLBodyMatchesPlainText() throws {
        // The email body and Copy share one source, so decoding the body query
        // item must reproduce plainText verbatim.
        let r = report(["want", "solves", "for"], diagnostics: "diag\nline")
        let url = try XCTUnwrap(r.mailtoURL(to: "test@example.com"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(comps.queryItems?.first(where: { $0.name == "body" })?.value)
        XCTAssertEqual(body, r.plainText)
    }
}
