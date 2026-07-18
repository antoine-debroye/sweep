import XCTest
@testable import SweepCore

/// Regression coverage for the launch crash: parsing `zip-sha256:` out of a real
/// multi-line release body must not trap on a cross-string index.
final class ReleaseNotesTests: XCTestCase {
    private let sha = "3c8c2cfc327dfc54e95258578170eac87110701581525ff72ab70de9cc2519c9"

    func testParsesShaFromRealisticMultilineBody() {
        // This exact shape (the tag on a later line, so it's a mid-string
        // Substring) is what crashed 1.1.0.
        let body = """
        ## Sweep 1.1.0

        - Release v1.1.0
        - Add Disk Explorer + Large Files
        - Add in-app auto-updater

        zip-sha256: \(sha)
        """
        XCTAssertEqual(ReleaseNotes.parseZipSHA256(from: body), sha)
    }

    func testCaseInsensitiveTag() {
        XCTAssertEqual(ReleaseNotes.parseZipSHA256(from: "ZIP-SHA256: \(sha)"), sha)
    }

    func testToleratesSurroundingWhitespace() {
        XCTAssertEqual(ReleaseNotes.parseZipSHA256(from: "  zip-sha256:    \(sha)   "), sha)
    }

    func testUnicodeBeforeTagDoesNotTrap() {
        // Index-safety stress: multibyte content on earlier lines.
        let body = "Notes ✅ 日本語\nsome text\nzip-sha256: \(sha)\n"
        XCTAssertEqual(ReleaseNotes.parseZipSHA256(from: body), sha)
    }

    func testNilWhenNoLine() {
        XCTAssertNil(ReleaseNotes.parseZipSHA256(from: "## Sweep 1.1.0\n- a change\n"))
        XCTAssertNil(ReleaseNotes.parseZipSHA256(from: ""))
    }

    func testNilWhenHexWrongLength() {
        XCTAssertNil(ReleaseNotes.parseZipSHA256(from: "zip-sha256: abc123"))
        XCTAssertNil(ReleaseNotes.parseZipSHA256(from: "zip-sha256: \(sha)ff")) // 66 chars
    }
}
