import XCTest
@testable import SweepCore

/// Version comparison that drives "is a newer release available?". Lenient parse:
/// `v` prefix stripped, pre-release/build suffix ignored, missing components → 0.
final class VersionTests: XCTestCase {
    func testParsesPlainTriple() {
        let v = SemanticVersion("1.2.3")
        XCTAssertEqual(v, SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(v?.description, "1.2.3")
    }

    func testStripsLeadingV() {
        XCTAssertEqual(SemanticVersion("v1.4.0"), SemanticVersion("1.4.0"))
        XCTAssertEqual(SemanticVersion("V2.0.1"), SemanticVersion("2.0.1"))
    }

    func testMissingComponentsDefaultToZero() {
        XCTAssertEqual(SemanticVersion("2"), SemanticVersion("2.0.0"))
        XCTAssertEqual(SemanticVersion("2.5"), SemanticVersion("2.5.0"))
    }

    func testIgnoresPreReleaseAndBuildMetadata() {
        XCTAssertEqual(SemanticVersion("1.4.0-beta.2"), SemanticVersion("1.4.0"))
        XCTAssertEqual(SemanticVersion("1.4.0+abc123"), SemanticVersion("1.4.0"))
    }

    func testOrdering() {
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("1.0.1")!)
        XCTAssertLessThan(SemanticVersion("1.0.9")!, SemanticVersion("1.1.0")!)
        XCTAssertLessThan(SemanticVersion("1.9.9")!, SemanticVersion("2.0.0")!)
        XCTAssertGreaterThan(SemanticVersion("2.0.0")!, SemanticVersion("1.99.99")!)
    }

    func testEqualVersionsAreNotLess() {
        let a = SemanticVersion("1.2.3")!
        let b = SemanticVersion("v1.2.3")!
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)
        XCTAssertEqual(a, b)
    }

    /// The core "update available" predicate the checker relies on.
    func testNewerReleaseIsDetected() {
        let current = SemanticVersion("1.0.0")!
        XCTAssertTrue(SemanticVersion("1.0.1")! > current)   // patch bump
        XCTAssertTrue(SemanticVersion("1.1.0")! > current)   // minor bump
        XCTAssertFalse(SemanticVersion("1.0.0")! > current)  // same version
        XCTAssertFalse(SemanticVersion("0.9.9")! > current)  // older
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("   "))
        XCTAssertNil(SemanticVersion("not-a-version"))
        XCTAssertNil(SemanticVersion("beta"))
    }
}
