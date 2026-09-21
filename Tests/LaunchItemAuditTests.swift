import XCTest
@testable import SweepCore

/// Coverage for the read-only launch-item audit. Everything is driven off a
/// fixture home with injected roots, so no test reads /Library.
final class LaunchItemAuditTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-launch-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "agents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "daemons"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "helpers"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func roots() -> LaunchItemAudit.Roots {
        var roots = LaunchItemAudit.Roots(home: home)
        roots.userAgents = home.appending(path: "agents")
        roots.systemAgents = home.appending(path: "nowhere")
        roots.systemDaemons = home.appending(path: "daemons")
        roots.privilegedHelpers = home.appending(path: "helpers")
        return roots
    }

    private func plist(_ relative: String, _ contents: [String: Any]) throws {
        let url = home.appending(path: relative)
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func audit(installed: Set<String> = [], running: Set<String> = []) -> [LaunchItemFinding] {
        let index = InstalledAppIndex(
            bundleIDs: installed, runningBundleIDs: running, resolveBundleID: { _ in nil }
        )
        return LaunchItemAudit.audit(home: home, index: index, roots: roots())
    }

    func testReportsLaunchItemWhoseProgramIsMissing() throws {
        try plist("agents/com.siber.gs-server.plist", [
            "Label": "com.siber.gs-server",
            "Program": "/Applications/GoodSync.app/Contents/Resources/gs-server",
        ])
        let findings = audit()
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.kind, .launchAgent)
        XCTAssertEqual(findings.first?.label, "com.siber.gs-server")
    }

    func testProgramArgumentsIsUsedWhenProgramIsAbsent() throws {
        let existing = home.appending(path: "real-binary")
        try Data("x".utf8).write(to: existing)
        try plist("daemons/com.example.alive.plist", [
            "Label": "com.example.alive",
            "ProgramArguments": [existing.path, "--serve"],
        ])
        XCTAssertTrue(audit().isEmpty, "the program exists, so there is nothing to report")
    }

    /// Regression: a plist with no program key at all must produce NO finding.
    /// A shell probe during design treated a plist-reader error string as a
    /// path and reported a perfectly healthy NordVPN daemon as orphaned.
    func testPlistWithNoProgramKeyProducesNoFinding() throws {
        try plist("daemons/com.nordvpn.macos.helper.plist", [
            "Label": "com.nordvpn.macos.helper",
            "MachServices": ["com.nordvpn.macos.helper": true],
        ])
        XCTAssertTrue(audit().isEmpty, "unknown is not the same as orphaned")
    }

    func testReportsHelperToolWithNoLaunchItemAndNoInstalledVendor() throws {
        try Data("x".utf8).write(to: home.appending(path: "helpers/com.bitgapp.eqmac.helper"))
        let findings = audit()
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.kind, .privilegedHelper)
    }

    func testHelperToolOfAnInstalledVendorIsNotReported() throws {
        try Data("x".utf8).write(to: home.appending(path: "helpers/com.docker.vmnetd"))
        XCTAssertTrue(audit(installed: ["com.docker.docker"]).isEmpty,
                      "Docker is installed, so its helper is not orphaned")
    }

    func testReferencedHelperToolIsNotReported() throws {
        let helper = home.appending(path: "helpers/com.example.helper")
        try Data("x".utf8).write(to: helper)
        try plist("daemons/com.example.helper.plist", [
            "Label": "com.example.helper", "Program": helper.path,
        ])
        XCTAssertTrue(audit().isEmpty, "a live launch item references it")
    }

    func testAppleHelpersAreNeverReported() throws {
        try Data("x".utf8).write(to: home.appending(path: "helpers/com.apple.something.helper"))
        XCTAssertTrue(audit().isEmpty)
    }

    func testAuditDeletesNothing() throws {
        try plist("agents/com.siber.gs-server.plist", [
            "Label": "com.siber.gs-server", "Program": "/nonexistent/binary",
        ])
        try Data("x".utf8).write(to: home.appending(path: "helpers/com.bitgapp.eqmac.helper"))
        _ = audit()
        XCTAssertTrue(fm.fileExists(atPath: home.appending(path: "agents/com.siber.gs-server.plist").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appending(path: "helpers/com.bitgapp.eqmac.helper").path))
    }
}
