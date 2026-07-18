import XCTest
@testable import SweepCore

/// Uninstaller leftover matching, per sensitivity tier, against a fixture home.
/// Exact bundle-id / app-name hits are `.explicitOnly`; team-ID and heuristic
/// hits are `.review`. The real disk is never touched.
final class LeftoverFinderTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    let bundleID = "com.acme.app"
    let appName = "Acme"
    let teamID = "ABCDE12345"

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-uninstall-\(UUID().uuidString)")

        // Exact bundle-id (all depths)
        try mk("Library/Application Support/com.acme.app/data.bin")
        try mk("Library/Caches/com.acme.app/cache.bin")
        try mk("Library/Preferences/com.acme.app.plist")
        try mk("Library/Preferences/ByHost/com.acme.app.1234-5678.plist")

        // App-name (enhanced+)
        try mk("Library/Application Support/Acme/state.bin")

        // Bundle-id-prefixed shared container (enhanced+)
        try mk("Library/Group Containers/com.acme.app.shared/blob.bin")

        // Team-ID app group (deep only, .review)
        try mk("Library/Group Containers/ABCDE12345.com.acme/blob.bin")

        // Heuristic plug-in named after the app (deep only, .review)
        try mk("Library/Internet Plug-Ins/Acme Helper.plugin/contents.bin")

        // Unrelated — must never appear at any depth
        try mk("Library/Application Support/com.other.app/data.bin")
        try mk("Library/Group Containers/ZZZZZ99999.com.other/blob.bin")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func mk(_ relative: String) throws {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xAB]).write(to: url)
    }

    private func find(_ depth: MatchDepth) -> [ScanItem] {
        LeftoverFinder.find(bundleID: bundleID, appName: appName, teamID: teamID, depth: depth, home: home)
    }

    private func names(_ items: [ScanItem]) -> Set<String> {
        Set(items.map { $0.url.lastPathComponent })
    }

    // MARK: - Strict

    func testStrictFindsOnlyExactBundleIDMatches() {
        let items = find(.strict)
        let found = names(items)
        XCTAssertTrue(found.contains("com.acme.app"))          // App Support + Caches share the leaf name
        XCTAssertTrue(found.contains("com.acme.app.plist"))
        XCTAssertTrue(found.contains("com.acme.app.1234-5678.plist"))
        // Not app-name, not shared/team containers, not heuristic.
        XCTAssertFalse(found.contains("Acme"))
        XCTAssertFalse(found.contains("com.acme.app.shared"))
        XCTAssertFalse(found.contains("ABCDE12345.com.acme"))
        XCTAssertFalse(found.contains("Acme Helper.plugin"))
        // Everything is high-confidence.
        XCTAssertTrue(items.allSatisfy { $0.tier == .explicitOnly })
    }

    // MARK: - Enhanced

    func testEnhancedAddsAppNameAndSharedContainer() {
        let found = names(find(.enhanced))
        XCTAssertTrue(found.contains("Acme"))
        XCTAssertTrue(found.contains("com.acme.app.shared"))
        // Still no team-ID group or heuristic plug-in.
        XCTAssertFalse(found.contains("ABCDE12345.com.acme"))
        XCTAssertFalse(found.contains("Acme Helper.plugin"))
    }

    func testEnhancedMatchesAreAllHighConfidence() {
        XCTAssertTrue(find(.enhanced).allSatisfy { $0.tier == .explicitOnly })
    }

    // MARK: - Deep

    func testDeepAddsTeamIDGroupAndHeuristicAsReview() {
        let items = find(.deep)
        let found = names(items)
        XCTAssertTrue(found.contains("ABCDE12345.com.acme"))
        XCTAssertTrue(found.contains("Acme Helper.plugin"))

        let teamGroup = items.first { $0.url.lastPathComponent == "ABCDE12345.com.acme" }
        let plugin = items.first { $0.url.lastPathComponent == "Acme Helper.plugin" }
        XCTAssertEqual(teamGroup?.tier, .review)
        XCTAssertEqual(plugin?.tier, .review)

        // Exact matches remain high-confidence even in deep mode.
        let prefs = items.first { $0.url.lastPathComponent == "com.acme.app.plist" }
        XCTAssertEqual(prefs?.tier, .explicitOnly)
    }

    func testDeepWithoutTeamIDSkipsTeamGroup() {
        let items = LeftoverFinder.find(bundleID: bundleID, appName: appName, teamID: nil, depth: .deep, home: home)
        XCTAssertFalse(names(items).contains("ABCDE12345.com.acme"))
    }

    // MARK: - Never matches unrelated apps

    func testUnrelatedAppDataNeverAppears() {
        for depth in MatchDepth.allCases {
            let found = names(find(depth))
            XCTAssertFalse(found.contains("com.other.app"), "leaked unrelated data at \(depth.label)")
            XCTAssertFalse(found.contains("ZZZZZ99999.com.other"), "leaked unrelated group at \(depth.label)")
        }
    }
}
