import XCTest
@testable import SweepCore

/// Uninstalling one app must only take what provably belongs to it.
final class UninstallOwnershipTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-own-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func agent(_ name: String, program: String) throws {
        let url = home.appending(path: "Library/LaunchAgents/\(name)")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": (name as NSString).deletingPathExtension, "ProgramArguments": [program, "--daemon"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func dir(_ relative: String) throws {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appending(path: "data"))
    }

    // MARK: - Launch agents

    func testLaunchAgentsArePreselectedOnlyWithProofOfOwnership() throws {
        let app = URL(fileURLWithPath: "/Applications/Acme.app")
        try agent("com.acme.app.plist", program: "/usr/local/bin/anything")                       // exact name
        try agent("com.acme.updater.plist", program: "/Applications/Acme.app/Contents/MacOS/upd")  // runs from the app
        try agent("com.acme.app.helper.plist", program: "/Library/Acme/helper")                    // labels only
        try agent("com.acme.app2.helper.plist", program: "/Applications/Acme2.app/Contents/MacOS/h") // other app
        try agent("com.apple.acme.app.plist", program: "/usr/libexec/x")                          // never Apple's

        let items = LeftoverFinder.find(bundleID: "com.acme.app", appName: "Acme", depth: .enhanced, appURL: app, home: home)
            .filter { $0.detail.hasPrefix("Launch agent") }
        let tiers = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0.tier) })

        XCTAssertEqual(tiers["com.acme.app.plist"], .explicitOnly)
        XCTAssertEqual(tiers["com.acme.updater.plist"], .explicitOnly)
        XCTAssertEqual(tiers["com.acme.app.helper.plist"], .review)
        XCTAssertNil(tiers["com.acme.app2.helper.plist"], "com.acme.app is a prefix of com.acme.app2, not its owner")
        XCTAssertNil(tiers["com.apple.acme.app.plist"])
    }

    func testProgramPathMustNotEscapeTheBundle() throws {
        let app = URL(fileURLWithPath: "/Applications/Acme.app")
        try agent("org.other.tool.plist", program: "/Applications/Acme.app/../Other.app/Contents/MacOS/tool")
        let items = LeftoverFinder.find(bundleID: "com.acme.app", appName: "Acme", depth: .enhanced, appURL: app, home: home)
        XCTAssertFalse(items.contains { $0.url.lastPathComponent == "org.other.tool.plist" })
    }

    func testBundleIDMatchesWholeLabelsOnly() {
        XCTAssertTrue(LeftoverFinder.containsLabels("UBF8T346G9.com.microsoft.teams", "com.microsoft.teams"))
        XCTAssertTrue(LeftoverFinder.containsLabels("group.com.acme.app", "com.acme.app"))
        XCTAssertTrue(LeftoverFinder.containsLabels("com.acme.app.helper", "com.acme.app"))
        XCTAssertFalse(LeftoverFinder.containsLabels("UBF8T346G9.com.microsoft.teams2", "com.microsoft.teams"))
        XCTAssertFalse(LeftoverFinder.containsLabels("com.acme", "com.acme.app"))
    }

    func testGroupContainersOfASimilarlyNamedAppAreNotTaken() throws {
        try dir("Library/Group Containers/ABCDE12345.com.acme.app")
        try dir("Library/Group Containers/ABCDE12345.com.acme.app2")
        let names = LeftoverFinder.find(bundleID: "com.acme.app", appName: "Acme", depth: .enhanced, home: home)
            .map(\.url.lastPathComponent)
        XCTAssertTrue(names.contains("ABCDE12345.com.acme.app"))
        XCTAssertFalse(names.contains("ABCDE12345.com.acme.app2"))
    }

    // MARK: - Other installed copies

    func testAnotherInstalledCopyKeepsTheSharedData() throws {
        let selected = home.appending(path: "Applications/Acme.app")
        let other = home.appending(path: "Setapp/Acme.app")
        let staged = home.appending(path: "Library/Application Support/Acme/Update/Acme.app")
        let trashed = home.appending(path: ".Trash/Acme.app")
        for url in [selected, other, staged, trashed] {
            try fm.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        }
        let gone = home.appending(path: "Old/Acme.app")   // registered, no longer on disk

        let found = OtherAppCopies.find(
            bundleID: "com.acme.app", excluding: selected, home: home,
            lookup: { _ in [selected, other, staged, trashed, gone] }, networkMounts: []
        )
        XCTAssertEqual(found.copies.map(\.path), [other.path])
        XCTAssertNotNil(found.note(appName: "Acme"))
    }

    func testOnlyTheSelectedCopyMeansNoOtherCopies() throws {
        let selected = home.appending(path: "Applications/Acme.app")
        try fm.createDirectory(at: selected, withIntermediateDirectories: true)
        let found = OtherAppCopies.find(bundleID: "com.acme.app", excluding: selected, home: home,
                                        lookup: { _ in [selected] }, networkMounts: [])
        XCTAssertTrue(found.isEmpty)
        XCTAssertNil(found.note(appName: "Acme"))
    }

    /// A copy on a share whose server is gone can't be examined without
    /// risking a hang — and can't be ruled out either.
    func testCopiesOnNetworkVolumesAreNotTouchedButStillCount() {
        let selected = URL(fileURLWithPath: "/Applications/Acme.app")
        let onShare = URL(fileURLWithPath: "/Volumes/[C] Windows 11.hidden/Apps/Acme.app")
        let found = OtherAppCopies.find(bundleID: "com.acme.app", excluding: selected, home: home,
                                        lookup: { _ in [onShare] }, networkMounts: ["/Volumes/[C] Windows 11.hidden"])
        XCTAssertEqual(found.unchecked, [onShare])
        XCTAssertTrue(found.copies.isEmpty)
        XCTAssertFalse(found.isEmpty)
    }

    func testTimeMachineSnapshotsAreNotInstalls() {
        XCTAssertFalse(OtherAppCopies.isRealInstallLocation(
            "/volumes/com.apple.timemachine.localsnapshots/backups.backupdb/mac/latest/data/applications/acme.app", home: home))
        XCTAssertTrue(OtherAppCopies.isRealInstallLocation("/applications/acme.app", home: home))
    }
}
