import XCTest
import Security
@testable import SweepCore

/// The updater must only ever install a bundle signed by our Developer ID team.
final class UpdateSignatureTests: XCTestCase {
    func testRequirementNamesOurTeamAndBundle() {
        let req = UpdateSignature.requirement()
        XCTAssertTrue(req.contains("identifier \"com.debroye.sweep\""))
        XCTAssertTrue(req.contains("certificate leaf[subject.OU] = \"\(SweepHelperConstants.teamIdentifier)\""))
        XCTAssertTrue(req.contains("anchor apple generic"))
        // Developer ID intermediate + leaf markers, so a Mac App Store or
        // development certificate from the same team doesn't qualify.
        XCTAssertTrue(req.contains("1.2.840.113635.100.6.2.6"))
        XCTAssertTrue(req.contains("1.2.840.113635.100.6.1.13"))
    }

    func testRequirementCompiles() {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(UpdateSignature.requirement() as CFString, [], &requirement),
                       errSecSuccess)
        XCTAssertNotNil(requirement)
    }

    func testRejectsMissingBundle() {
        let url = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).app")
        XCTAssertNotNil(failure(of: UpdateSignature.verify(appAt: url)))
    }

    func testRejectsUnsignedBundle() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "Fake-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try Data("#!/bin/sh\n".utf8).write(to: app.appending(path: "Contents/MacOS/Sweep"))
        XCTAssertNotNil(failure(of: UpdateSignature.verify(appAt: app)))
    }

    /// Validly signed, but by Apple rather than by us.
    func testRejectsAppSignedBySomeoneElse() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator.path))
        XCTAssertNotNil(failure(of: UpdateSignature.verify(appAt: calculator)))
        // Sanity: its signature itself is valid, so the rejection above is
        // about identity, not a broken check.
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(calculator as CFURL, [], &code), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), [], nil), errSecSuccess)
    }

    /// The test bundle is ad-hoc signed, like a Debug build.
    func testRejectsAdHocBuild() {
        let bundle = Bundle(for: Self.self).bundleURL
        XCTAssertNotNil(failure(of: UpdateSignature.verify(appAt: bundle)))
    }

    /// The real released app, when installed on this Mac, must pass.
    func testAcceptsInstalledReleaseBuild() throws {
        let installed = URL(fileURLWithPath: "/Applications/Sweep.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: installed.path), "Sweep isn't installed")
        XCTAssertNil(failure(of: UpdateSignature.verify(appAt: installed)))
    }

    private func failure(of result: Result<Void, UpdateSignature.Failure>) -> UpdateSignature.Failure? {
        if case .failure(let f) = result { return f }
        return nil
    }
}
