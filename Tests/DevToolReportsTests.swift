import XCTest
@testable import SweepCore

final class DevToolReportsTests: XCTestCase {

    // MARK: - Homebrew

    func testBrewPreviewCountsRealRemovalsAndReadsTheEstimate() {
        let output = """
        Would remove: /Users/x/Library/Caches/Homebrew/downloads/abc--node-22.bottle.tar.gz (41.2MB)
        Would remove: /opt/homebrew/Cellar/python@3.12/3.12.4 (3,201 files, 64.8MB)
        Would remove: /Users/x/Library/Logs/Homebrew/glib (0B)
        Would remove (empty directory): /opt/homebrew/lib/gio
        ==> This operation would free approximately 106.0MB of disk space.
        """
        let preview = BrewCleanupPreview.parse(output)
        XCTAssertEqual(preview.items, [
            "/Users/x/Library/Caches/Homebrew/downloads/abc--node-22.bottle.tar.gz",
            "/opt/homebrew/Cellar/python@3.12/3.12.4",
        ])
        XCTAssertEqual(preview.approximateFree, "106.0MB")
        XCTAssertEqual(preview.summary, "Would remove 2 items · about 106.0MB")
        XCTAssertEqual(BrewCleanupPreview.parse("").summary, "Nothing to clean up.")
    }

    func testBrewCleanupNeverAutoremovesFormulae() {
        XCTAssertEqual(BrewCleanupPreview.environment["HOMEBREW_NO_AUTOREMOVE"], "1")
        XCTAssertEqual(BrewCleanupPreview.environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
    }

    // MARK: - Docker

    func testDockerInUseImagesAreNotCalledReclaimable() {
        let output = """
        Images\t7.093GB\t7.093GB (100%)\t2\t2
        Containers\t51.33MB\t25.34MB (49%)\t25\t11
        Build Cache\t3.315GB\t1.841GB\t61\t0
        """
        let lines = DockerDiskUsage.summary(output).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["Images: 2/2 in use", "Containers: 25.34MB (49%)", "Build Cache: 1.841GB"])
    }

    // MARK: - VPN

    func testConnectedSystemVPNIsDetectedByName() {
        let list = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      6A3C… IPSec              "Office VPN"                     [IPSec]
        * (Disconnected)   1B2D… PPP --> L2TP       "Old L2TP"                       [PPP/L2TP]
        """
        XCTAssertEqual(VPNStatus.connectedService(inNCList: list), "Office VPN")
        XCTAssertNil(VPNStatus.connectedService(inNCList: "* (Disconnected)   1B2D… \"Old\" [PPP/L2TP]"))
    }

    func testOnlyADefaultRouteThroughATunnelCountsAsAVPN() {
        let tunnel = "   route to: default\ndestination: default\n  interface: utun4\n"
        let wifi = "   route to: default\ndestination: default\n  interface: en0\n"
        XCTAssertEqual(VPNStatus.defaultRouteVerdict(stdout: tunnel, stderr: "", status: 0), .active("tunnel on utun4"))
        XCTAssertEqual(VPNStatus.defaultRouteVerdict(stdout: wifi, stderr: "", status: 0), .inactive)
        XCTAssertEqual(VPNStatus.defaultRouteVerdict(stdout: "", stderr: "route: writing to routing socket: not in table", status: 1),
                       .inactive, "offline is not a VPN")
        XCTAssertEqual(VPNStatus.defaultRouteVerdict(stdout: "", stderr: "", status: ProcessRunner.timedOutStatus), .unknown)
    }

    // MARK: - Codex worktrees

    func testCodexWorktreesAreFoundInTheirFixedContainer() throws {
        let fm = FileManager()
        let home = fm.temporaryDirectory.appending(path: "sweep-codex-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let container = home.appending(path: ".codex/worktrees")
        for path in ["task-a/.git", "f00d/repo-b/.git"] {
            let url = container.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("gitdir: /nowhere".utf8).write(to: url)
        }
        try fm.createDirectory(at: container.appending(path: "empty-dir"), withIntermediateDirectories: true)

        let found = WorktreeScanner.findCodexWorktrees(home: home, policy: SafetyPolicy(home: home))
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["repo-b", "task-a"])
    }
}
