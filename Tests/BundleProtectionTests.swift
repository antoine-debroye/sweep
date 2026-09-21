import XCTest
@testable import SweepCore

/// Identity-based protection and the vendor-uninstaller hand-off.
final class BundleProtectionTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-protect-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    private func app(_ name: String, _ bundleID: String, at path: String? = nil) -> InstalledApp {
        InstalledApp(
            url: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
            name: name, bundleID: bundleID, version: nil, size: nil, lastUsed: nil
        )
    }

    @discardableResult
    private func appBundle(_ relative: String) throws -> URL {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: url.appending(path: "Contents/MacOS/stub"))
        return url
    }

    // MARK: - Security agents

    func testSecurityAgentsAreRecognized() {
        for id in ["com.crowdstrike.falcon", "com.sentinelone.agent", "com.jamf.management",
                   "com.paloaltonetworks.GlobalProtect", "com.microsoft.wdav.tray",
                   "com.zscaler.tray", "com.eset.endpoint"] {
            XCTAssertTrue(BundleProtection.isSecurityAgent(id), id)
        }
        for id in ["com.apple.Safari", "com.google.Chrome", "md.obsidian"] {
            XCTAssertFalse(BundleProtection.isSecurityAgent(id), id)
        }
    }

    func testUninstallGuardRefusesSecurityAgents() {
        let verdict = UninstallGuard.verdict(for: app("Falcon", "com.crowdstrike.falcon"))
        XCTAssertFalse(verdict.isAllowed)
        XCTAssertTrue(verdict.reason?.contains("MDM") ?? false, "reason was: \(verdict.reason ?? "nil")")
    }

    func testUninstallGuardRefusesAppleAndPlatformDependencies() {
        XCTAssertFalse(UninstallGuard.verdict(for: app("Safari", "com.apple.Safari")).isAllowed)
        XCTAssertFalse(UninstallGuard.verdict(for: app("Docker", "com.docker.docker")).isAllowed)
    }

    func testUninstallGuardStillAllowsAnOrdinaryApp() {
        XCTAssertTrue(UninstallGuard.verdict(for: app("Telegram", "ru.keepcoder.Telegram")).isAllowed)
    }

    func testUninstallGuardKeepsThePathRuleForNestedApps() {
        let nested = app("DaVinci Resolve", "com.blackmagic-design.resolve",
                         at: "/Applications/DaVinci Resolve/DaVinci Resolve.app")
        XCTAssertFalse(UninstallGuard.verdict(for: nested).isAllowed,
                       "still refused: Sweep only removes apps directly in an Applications folder")
    }

    // MARK: - Data-sensitive bundles

    func testDataSensitivePatternsMatchTheRightBundles() {
        for id in ["com.1password.1password", "com.bitwarden.desktop", "com.dashlane.Dashlane",
                   "org.keepassxc.keepassxc", "com.sogou.inputmethod.sogou",
                   "im.rime.inputmethod.Squirrel", "md.obsidian"] {
            XCTAssertTrue(BundleProtection.isDataSensitive(id), id)
        }
        for id in ["com.google.Chrome", "com.figma.Desktop", "com.spotify.client"] {
            XCTAssertFalse(BundleProtection.isDataSensitive(id), id)
        }
    }

    func testGlobMatcherHandlesEachWildcardPosition() {
        XCTAssertTrue(BundleProtection.matches(pattern: "com.acme.*", "com.acme.tool"))
        XCTAssertTrue(BundleProtection.matches(pattern: "*.inputmethod", "com.acme.inputmethod"))
        XCTAssertTrue(BundleProtection.matches(pattern: "*vault*", "com.acme.vaultsync"))
        XCTAssertTrue(BundleProtection.matches(pattern: "md.obsidian", "md.obsidian"))
        XCTAssertFalse(BundleProtection.matches(pattern: "md.obsidian", "md.obsidian.beta"))
        XCTAssertFalse(BundleProtection.matches(pattern: "com.acme.*", "com.other.tool"))
    }

    /// A password vault or a learned input dictionary is not regenerable, so
    /// the leftover scanner must not offer it even when the app is gone.
    func testLeftoverScannerNeverOffersDataSensitiveAppData() throws {
        for name in ["1Password", "Bitwarden", "Dashlane", "Obsidian", "Squirrel"] {
            let file = home.appending(path: "Library/Application Support/\(name)/vault.bin")
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x7, count: 3_000_000).write(to: file)
            let old = Date().addingTimeInterval(-400 * 86_400)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            try fm.setAttributes([.modificationDate: old],
                                 ofItemAtPath: file.deletingLastPathComponent().path)
        }
        // Plant orphaned residue so the evidence channels are tempted.
        let prefs = home.appending(path: "Library/Preferences")
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        for id in ["com.1password.1password", "com.bitwarden.desktop", "com.dashlane.Dashlane"] {
            try Data("x".utf8).write(to: prefs.appending(path: "\(id).plist"))
        }

        let index = InstalledAppIndex(bundleIDs: [], runningBundleIDs: [], resolveBundleID: { _ in nil })
        let offered = OrphanScanner.scan(home: home, index: index, policy: SafetyPolicy(home: home))
        for item in offered {
            for name in ["1Password", "Bitwarden", "Dashlane", "Obsidian", "Squirrel"] {
                XCTAssertFalse(item.url.path.contains(name), "offered \(item.url.path)")
            }
            XCTAssertFalse(item.url.lastPathComponent.contains("1password"), item.url.path)
        }
    }

    // MARK: - Vendor uninstaller hand-off

    func testFindsAPlainUninstallerAppBesideTheApp() throws {
        let vendor = "Applications/DaVinci Resolve"
        let target = try appBundle("\(vendor)/DaVinci Resolve.app")
        try appBundle("\(vendor)/Uninstall Resolve.app")

        let found = VendorUninstaller.discoverTool(near: target)
        XCTAssertEqual(found?.lastPathComponent, "Uninstall Resolve.app")
    }

    /// Creative Cloud's entry is a symlink into /Applications/Utilities.
    func testFollowsASymlinkedUninstaller() throws {
        let target = try appBundle("Applications/Adobe Creative Cloud/Creative Cloud.app")
        let real = try appBundle("Applications/Utilities/Adobe/Creative Cloud Uninstaller.app")
        let link = home.appending(path: "Applications/Adobe Creative Cloud/Uninstall Adobe Creative Cloud")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let found = VendorUninstaller.discoverTool(near: target)
        XCTAssertEqual(found?.lastPathComponent, "Creative Cloud Uninstaller.app")
    }

    /// Acrobat's entry is a macOS **alias file** — neither a symlink nor a
    /// bundle, so it needs bookmark resolution.
    func testResolvesAMacOSAliasFileUninstaller() throws {
        let target = try appBundle("Applications/Adobe Acrobat DC/Adobe Acrobat.app")
        let real = try appBundle("Applications/Utilities/Adobe/Acrobat Uninstaller.app")
        let alias = home.appending(path: "Applications/Adobe Acrobat DC/Acrobat Uninstaller")
        let bookmark = try real.bookmarkData(options: .suitableForBookmarkFile,
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)

        let found = VendorUninstaller.discoverTool(near: target)
        XCTAssertEqual(found?.lastPathComponent, "Acrobat Uninstaller.app",
                       "an alias file must be resolved, not skipped")
    }

    /// A match in /Applications itself would belong to some unrelated app.
    func testDoesNotTreatAnUnrelatedUninstallerInApplicationsRootAsTheVendorTool() throws {
        let target = URL(fileURLWithPath: "/Applications/Some App.app")
        XCTAssertNil(VendorUninstaller.discoverTool(near: target))
    }

    func testSecurityAgentsGetVendorGuidanceRatherThanATool() {
        let handoff = VendorUninstaller.handoff(for: app("Falcon", "com.crowdstrike.falcon"))
        guard case .managedByVendor(let vendor, let guidance) = handoff else {
            return XCTFail("expected vendor guidance, got \(String(describing: handoff))")
        }
        XCTAssertEqual(vendor, "CrowdStrike")
        XCTAssertTrue(guidance.contains("MDM"))
    }

    func testKnownSuiteWithoutALocalToolStillGetsGuidance() {
        let handoff = VendorUninstaller.handoff(
            for: app("Some Adobe Thing", "com.adobe.something", at: "/Applications/Some Adobe Thing.app")
        )
        guard case .managedByVendor(let vendor, _) = handoff else {
            return XCTFail("expected Adobe guidance, got \(String(describing: handoff))")
        }
        XCTAssertEqual(vendor, "Adobe")
    }

    func testAnUninstallerIsNotHandedOffToItself() throws {
        let vendor = "Applications/DaVinci Resolve"
        try appBundle("\(vendor)/DaVinci Resolve.app")
        let tool = try appBundle("\(vendor)/Uninstall Resolve.app")
        let itself = InstalledApp(
            url: tool, name: "Uninstall Resolve", bundleID: "com.blackmagic-design.uninstaller",
            version: nil, size: nil, lastUsed: nil
        )
        if case .vendorTool = VendorUninstaller.handoff(for: itself) {
            XCTFail("an uninstaller must not point at itself")
        }
    }

    func testOrdinaryAppsGetNoHandoff() {
        XCTAssertNil(VendorUninstaller.handoff(for: app("Telegram", "ru.keepcoder.Telegram")))
    }

    // MARK: - Generic word stop list

    /// Role words identify nobody: a folder called "Helper" or "Update"
    /// belongs to whichever app is asked about it, so matching on one is how a
    /// name matcher goes wrong.
    func testRoleWordsAreNotUsableAsIdentityTokens() {
        let split = NameToken.identityTokens(
            name: "Acme Helper", bundleFileName: "Acme Helper", bundleID: "com.acme.helper"
        )
        let all = split.app.union(split.vendor)
        for word in ["helper", "agent", "daemon", "update", "service", "manager"] {
            XCTAssertFalse(all.contains(word), "\(word) must never become an identity token")
        }
        XCTAssertTrue(all.contains("acme"), "the distinctive part is still indexed")
    }

    func testAFolderNamedAfterARoleWordIsNotMatchedToAnInstalledApp() {
        let index = InstalledAppIndex.live(
            apps: [app("Acme Helper", "com.acme.helper")],
            runningBundleIDs: [], runningAppNames: [], resolveBundleID: { _ in nil }
        )
        XCTAssertFalse(index.matchesInstalledApp(name: "Helper"))
        XCTAssertFalse(index.matchesInstalledApp(name: "Update"))
        XCTAssertTrue(index.matchesInstalledApp(name: "Acme Helper"))
    }
}
