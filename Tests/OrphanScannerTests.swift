import XCTest
@testable import SweepCore

/// Coverage for leftover detection: folders named after an app's display name
/// whose owning app is gone ("Figma"), and dead per-app subfolders inside a
/// live vendor's folder ("Adobe/AcroCef"). Everything runs against a fixture
/// home with an injected LaunchServices lookup, so no test reads the real
/// machine's app database.
final class OrphanScannerTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-orphan-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    // MARK: - Fixture helpers

    /// Writes `bytes` at `relative` and ages the file **and every ancestor** up
    /// to the fixture home, because age gating reads folder mtimes too.
    @discardableResult
    private func file(_ relative: String, bytes: Int = 2_000_000, ageDays: Int = 0) throws -> URL {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        try age(url, days: ageDays)
        return url
    }

    private func age(_ url: URL, days: Int) throws {
        let date = Date().addingTimeInterval(-Double(days) * 86_400)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        var dir = url.deletingLastPathComponent()
        while dir.path.count > home.path.count {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// A minimal but real `.app` bundle so `Bundle(url:)` can read its id.
    @discardableResult
    private func appBundle(_ relative: String, bundleID: String) throws -> URL {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": url.deletingPathExtension().lastPathComponent,
            "CFBundleExecutable": "stub",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appending(path: "Contents/Info.plist"))
        try Data("stub".utf8).write(to: url.appending(path: "Contents/MacOS/stub"))
        return url
    }

    private func makeIndex(
        installed: [(name: String, bundleID: String)] = [],
        running: Set<String> = [],
        runningNames: Set<String> = [],
        resolve: @escaping @Sendable (String) -> URL? = { _ in nil }
    ) -> InstalledAppIndex {
        let apps = installed.map {
            InstalledApp(
                url: URL(fileURLWithPath: "/Applications/\($0.name).app"),
                name: $0.name, bundleID: $0.bundleID, version: nil, size: nil, lastUsed: nil
            )
        }
        return .live(apps: apps, runningBundleIDs: running, runningAppNames: runningNames, resolveBundleID: resolve)
    }

    private func scan(_ index: InstalledAppIndex) -> [ScanItem] {
        OrphanScanner.scan(home: home, index: index, policy: SafetyPolicy(home: home))
    }

    private func rel(_ url: URL) -> String {
        let base = home.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return "!" + path }
        return String(path.dropFirst(base.count + 1))
    }

    // MARK: - Part A: name-style leftovers

    func testFindsNameStyleFolderWhenVendorResidueIsOrphaned() throws {
        try file("Library/Application Support/Figma/DesktopProfile/blob.bin", bytes: 5_000_000, ageDays: 60)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 4_000, ageDays: 60)
        try file("Library/Caches/com.figma.agent/cache.bin", bytes: 500_000, ageDays: 60)

        let items = scan(makeIndex())
        let paths = Set(items.map { rel($0.url) })

        XCTAssertTrue(paths.contains("Library/Application Support/Figma"),
                      "the display-name folder is the whole point of this pass")
        XCTAssertTrue(paths.contains("Library/Preferences/com.figma.Desktop.plist"))
        XCTAssertTrue(paths.contains("Library/Caches/com.figma.agent"))

        let figma = try XCTUnwrap(items.first { rel($0.url) == "Library/Application Support/Figma" })
        XCTAssertEqual(figma.tier, .review, "leftovers must never be pre-selected")
        XCTAssertEqual(figma.group, "figma")
        XCTAssertEqual(figma.ruleID, "orphan-app")

        let groups = Set(items.compactMap(\.group))
        XCTAssertEqual(groups, ["figma"], "every member of the cluster shares one group key")
    }

    /// Pitfall 1. Auto-updating apps stage a copy of themselves inside their own
    /// support folder and LaunchServices registers it, so the bundle id resolves
    /// to a path *inside the leftover*. That must not read as "installed".
    func testStagedAppBundleInsideLibraryIsNotAnInstallation() throws {
        try file("Library/Application Support/Figma/DesktopProfile/blob.bin", bytes: 5_000_000, ageDays: 60)
        try file("Library/Caches/com.figma.agent/cache.bin", bytes: 500_000, ageDays: 60)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 4_000, ageDays: 60)
        let staged = try appBundle("Library/Application Support/Figma/Figma Desktop.app",
                                   bundleID: "com.figma.universalLinks")
        try age(staged.appending(path: "Contents/Info.plist"), days: 60)
        try age(staged.appending(path: "Contents/MacOS/stub"), days: 60)
        let stagedHome = home!
        let index = makeIndex(resolve: { id in
            switch id {
            case "com.figma.universallinks", "com.figma.universalLinks": return staged
            case "com.figma.agent":
                return stagedHome.appending(path: "Library/Application Support/Figma/FigmaAgent.app")
            default: return nil
            }
        })

        let paths = Set(scan(index).map { rel($0.url) })
        XCTAssertTrue(paths.contains("Library/Application Support/Figma"),
                      "a staged bundle in ~/Library must not make the folder look installed")
        XCTAssertTrue(paths.contains("Library/Caches/com.figma.agent"),
                      "the reverse-DNS pass must apply the same rule")
    }

    func testResolvedAppInApplicationsSuppressesTheCluster() throws {
        try file("Library/Application Support/Figma/DesktopProfile/blob.bin", bytes: 5_000_000, ageDays: 60)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 4_000, ageDays: 60)

        let index = makeIndex(resolve: { _ in URL(fileURLWithPath: "/Applications/Figma.app") })
        let paths = Set(scan(index).map { rel($0.url) })
        XCTAssertFalse(paths.contains("Library/Application Support/Figma"),
                       "a real installation anywhere outside ~/Library means keep the data")
    }

    /// Pitfall 2. Finder writes `.DS_Store` into every folder the user browses,
    /// which makes a long-dead folder look modified today.
    func testDSStoreDoesNotResetTheAgeGate() throws {
        try file("Library/Application Support/Figma/DesktopProfile/blob.bin", bytes: 5_000_000, ageDays: 400)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 4_000, ageDays: 400)
        // Browsed just now: dot files and the folder mtimes are current.
        try Data("x".utf8).write(to: home.appending(path: "Library/Application Support/Figma/.DS_Store"))
        try Data("x".utf8).write(to: home.appending(path: "Library/Application Support/Figma/DesktopProfile/.DS_Store"))

        let paths = Set(scan(makeIndex()).map { rel($0.url) })
        XCTAssertTrue(paths.contains("Library/Application Support/Figma"),
                      "Finder metadata must not count as the app touching its data")
    }

    func testDirectorySizerIgnoresHiddenEntriesForAgeButNotForSize() throws {
        let folder = home.appending(path: "Library/Application Support/Figma")
        try file("Library/Application Support/Figma/blob.bin", bytes: 1_000_000, ageDays: 400)
        try Data(repeating: 0x11, count: 4_096).write(to: folder.appending(path: ".DS_Store"))

        let raw = DirectorySizer.stats(of: folder)
        let filtered = DirectorySizer.stats(of: folder, ignoringHiddenEntries: true)
        let old = Date().addingTimeInterval(-300 * 86_400)

        XCTAssertGreaterThan(try XCTUnwrap(raw.newestModification), old,
                             "the raw reading is polluted by the fresh .DS_Store")
        XCTAssertLessThan(try XCTUnwrap(filtered.newestModification), old,
                          "the filtered reading reflects real content only")
        XCTAssertEqual(filtered.size, raw.size, "hidden bytes are still bytes that get deleted")
        XCTAssertEqual(filtered.fileCount, raw.fileCount)
    }

    /// The dangerous class: folders holding live data whose names don't match
    /// their app. Same-vendor orphaned residue is planted deliberately, so the
    /// evidence channels are actively tempted.
    func testLiveVendorFoldersAreNeverOffered() throws {
        try file("Library/Application Support/Code/User/globalStorage/state.vscdb", bytes: 9_000_000, ageDays: 400)
        try file("Library/Application Support/Google/Chrome/Default/Bookmarks", bytes: 3_000_000, ageDays: 400)
        try file("Library/Application Support/Microsoft/Office/data.bin", bytes: 3_000_000, ageDays: 400)
        try file("Library/Application Support/Adobe/CameraRaw/blob.bin", bytes: 3_000_000, ageDays: 400)
        try file("Library/Application Support/Dropbox/instance1/db.bin", bytes: 3_000_000, ageDays: 400)
        // Orphaned same-vendor residue, to make sure evidence (b) doesn't fire.
        try file("Library/Caches/com.google.Keystone/agent.bin", bytes: 1_000_000, ageDays: 400)
        try file("Library/Preferences/com.adobe.CCXProcess.plist", bytes: 4_000, ageDays: 400)
        try file("Library/Preferences/com.microsoft.rdc.macos.plist", bytes: 4_000, ageDays: 400)

        let index = makeIndex(installed: [
            ("Visual Studio Code", "com.microsoft.VSCode"),
            ("Google Chrome", "com.google.Chrome"),
            ("Microsoft Word", "com.microsoft.Word"),
            ("Acrobat Distiller", "com.adobe.distiller"),
            ("Dropbox", "com.dropbox.desktop"),
        ], resolve: { id in
            let installed: Set<String> = [
                "com.microsoft.vscode", "com.google.chrome", "com.microsoft.word",
                "com.adobe.distiller", "com.dropbox.desktop",
            ]
            return installed.contains(id.lowercased()) ? URL(fileURLWithPath: "/Applications/Stub.app") : nil
        })

        let offered = Set(scan(index).map { rel($0.url) })
        for folder in ["Code", "Google", "Microsoft", "Adobe", "Dropbox"] {
            XCTAssertFalse(offered.contains("Library/Application Support/\(folder)"),
                           "\(folder) holds live data and must never be offered")
        }
        for path in offered {
            XCTAssertFalse(path.contains("Bookmarks"), "offered: \(path)")
            XCTAssertFalse(path.contains("state.vscdb"), "offered: \(path)")
        }
    }

    func testAppleOwnedFoldersAreNeverOffered() throws {
        let names = ["AddressBook", "CrashReporter", "CloudDocs", "Knowledge", "MobileSync",
                     "FileProvider", "Spotlight", "SyncServices", "icdd", "SESStorage",
                     "Animoji", "DiskImages"]
        for name in names {
            try file("Library/Application Support/\(name)/data.bin", bytes: 3_000_000, ageDays: 400)
            try file("Library/Preferences/com.\(name.lowercased()).helper.plist", bytes: 4_000, ageDays: 400)
        }
        let offered = Set(scan(makeIndex()).map { rel($0.url) })
        for name in names {
            XCTAssertFalse(offered.contains("Library/Application Support/\(name)"),
                           "\(name) is Apple-owned")
        }
    }

    func testSharedRuntimeFoldersAreNeverOffered() throws {
        let names = ["Electron", "CEF", "go", "turborepo", "Codex", "Antigravity", "React Native DevTools"]
        for name in names {
            try file("Library/Application Support/\(name)/data.bin", bytes: 3_000_000, ageDays: 400)
        }
        let offered = Set(scan(makeIndex()).map { rel($0.url) })
        for name in names {
            XCTAssertFalse(offered.contains("Library/Application Support/\(name)"),
                           "\(name) is shared runtime data, not one app's leftover")
        }
    }

    func testNestedApplicationsAreDiscoveredForSuppression() async throws {
        try appBundle("FakeApplications/Adobe Acrobat DC/Adobe Acrobat.app", bundleID: "com.adobe.Acrobat.Pro")
        // A helper inside the bundle must NOT be listed as a separate app.
        try appBundle("FakeApplications/Adobe Acrobat DC/Adobe Acrobat.app/Contents/Helper.app",
                      bundleID: "com.adobe.Acrobat.Helper")
        try appBundle("FakeApplications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app",
                      bundleID: "com.adobe.acc.AdobeCreativeCloud")

        let apps = await AppInventory.scanNested(roots: [home.appending(path: "FakeApplications")], maxDepth: 4)
        let ids = Set(apps.map(\.bundleID))
        XCTAssertTrue(ids.contains("com.adobe.Acrobat.Pro"), "a suite app nested one folder deep counts as installed")
        XCTAssertTrue(ids.contains("com.adobe.acc.AdobeCreativeCloud"), "and three folders deep")
        XCTAssertFalse(ids.contains("com.adobe.Acrobat.Helper"), "never walk inside an .app bundle")
    }

    func testNormalizationSuppressesInstalledAppsWithDifferentFolderNames() throws {
        let pairs: [(folder: String, app: String, bundleID: String)] = [
            ("sync-tool", "SyncTool", "com.example.synctool"),
            ("logitune", "Logi Tune", "com.logitech.logitune"),
            ("audiopad-ai", "AudioPad AI", "com.example.audiopadai"),
            ("anythingllm-desktop", "AnythingLLM", "com.example.anythingllm"),
            ("iStat Menus 7", "iStat Menus", "com.bjango.istatmenus"),
            ("Docker Desktop", "Docker", "com.docker.docker"),
        ]
        for pair in pairs {
            try file("Library/Application Support/\(pair.folder)/data.bin", bytes: 3_000_000, ageDays: 400)
            try file("Library/Preferences/\(pair.bundleID).plist", bytes: 4_000, ageDays: 400)
        }

        // Installed -> suppressed.
        let installedIndex = makeIndex(
            installed: pairs.map { (name: $0.app, bundleID: $0.bundleID) },
            resolve: { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
        )
        let suppressed = Set(scan(installedIndex).map { rel($0.url) })
        for pair in pairs {
            XCTAssertFalse(suppressed.contains("Library/Application Support/\(pair.folder)"),
                           "\(pair.folder) is \(pair.app)'s live data")
        }

        // Absent, with orphaned residue -> offered.
        let offered = Set(scan(makeIndex()).map { rel($0.url) })
        for pair in pairs where pair.folder != "Docker Desktop" {
            XCTAssertTrue(offered.contains("Library/Application Support/\(pair.folder)"),
                          "\(pair.folder) should be offered once \(pair.app) is gone")
        }
    }

    func testSmallSiblingsRideAlongWithTheCluster() throws {
        try file("Library/Application Support/Figma/blob.bin", bytes: 5_000_000, ageDays: 60)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 1_000, ageDays: 60)

        let paths = Set(scan(makeIndex()).map { rel($0.url) })
        XCTAssertTrue(paths.contains("Library/Preferences/com.figma.Desktop.plist"),
                      "gates apply to the cluster, so a 1 KB plist still comes along")
    }

    /// A departed app's background helper can keep rewriting its cache. That
    /// must not hold the whole cluster hostage — being *in use* is a separate
    /// question, answered by the running-process check.
    func testFreshSiblingCacheDoesNotBlockAStaleLeftover() throws {
        try file("Library/Application Support/Figma/blob.bin", bytes: 5_000_000, ageDays: 400)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 4_000, ageDays: 400)
        try file("Library/Caches/com.figma.agent/cache.bin", bytes: 500_000, ageDays: 0)

        let paths = Set(scan(makeIndex()).map { rel($0.url) })
        XCTAssertTrue(paths.contains("Library/Application Support/Figma"),
                      "the primary folder is 400 days stale; a fresh cache is not a reason to keep it")
        XCTAssertTrue(paths.contains("Library/Caches/com.figma.agent"),
                      "and the fresh cache comes along with its cluster")
    }

    /// A launchd job needs no `.app`, so every no-app-installed channel fires
    /// on the user's own scripts. This is the real-world case that caught it:
    /// `~/Library/LaunchAgents/com.antoine.montage-truenas.plist` runs a script
    /// inside `~/Library/Application Support/montage-truenas/` every 5 minutes.
    func testFolderDrivenByALiveLaunchAgentIsNeverOffered() throws {
        try file("Library/Application Support/montage-truenas/montage-truenas.sh",
                 bytes: 2_000_000, ageDays: 400)
        try file("Library/Logs/montage-truenas.log", bytes: 1_000_000, ageDays: 0)
        try file("Library/Preferences/com.antoine.montage-truenas.plist", bytes: 4_000, ageDays: 400)

        let script = home.appending(path: "Library/Application Support/montage-truenas/montage-truenas.sh")
        let log = home.appending(path: "Library/Logs/montage-truenas.log")
        let agents = home.appending(path: "Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let job: [String: Any] = [
            "Label": "com.antoine.montage-truenas",
            "ProgramArguments": ["/bin/bash", script.path],
            "StandardOutPath": log.path,
            "StartInterval": 300,
        ]
        try PropertyListSerialization
            .data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: agents.appending(path: "com.antoine.montage-truenas.plist"))

        let offered = Set(scan(makeIndex()).map { rel($0.url) })
        XCTAssertFalse(offered.contains("Library/Application Support/montage-truenas"),
                       "a live launchd job's script folder is not a leftover")
        for path in offered {
            XCTAssertFalse(path.contains("montage-truenas"), "offered part of a live job: \(path)")
        }
    }

    /// App-group entries are named "group.<bundle id>". Reading the vendor as
    /// "group.com" made an installed app's group preferences look orphaned.
    func testAppGroupPreferencesOfAnInstalledAppAreNotOffered() throws {
        try file("Library/Preferences/group.com.nordvpn.macos.firebase.plist", bytes: 4_000, ageDays: 400)
        try file("Library/Preferences/group.com.deadvendor.gone.plist", bytes: 4_000, ageDays: 400)

        let index = makeIndex(
            installed: [("NordVPN", "com.nordvpn.macos")],
            resolve: { $0.lowercased() == "com.nordvpn.macos" ? URL(fileURLWithPath: "/Applications/NordVPN.app") : nil }
        )
        let offered = Set(scan(index).map { rel($0.url) })
        XCTAssertFalse(offered.contains("Library/Preferences/group.com.nordvpn.macos.firebase.plist"),
                       "NordVPN is installed; its app-group prefs are live")
        XCTAssertTrue(offered.contains("Library/Preferences/group.com.deadvendor.gone.plist"),
                      "a genuinely departed vendor's group prefs are still found")
    }

    /// Dropbox ships as com.getdropbox.dropbox, so its own updater
    /// (com.dropbox.DropboxMacUpdate) is invisible to a vendor-prefix check.
    func testUpdaterOfAnInstalledAppWithAMismatchedVendorIsNotOffered() throws {
        try file("Library/Preferences/com.dropbox.DropboxMacUpdate.plist", bytes: 4_000, ageDays: 400)
        try file("Library/Preferences/com.deadvendor.oldapp.plist", bytes: 4_000, ageDays: 400)

        // The updater is also RUNNING, which is what made this fail in
        // production: its id contributes "dropbox" as a *vendor* token.
        let index = makeIndex(
            installed: [("Dropbox", "com.getdropbox.dropbox")],
            running: ["com.dropbox.DropboxMacUpdate"],
            resolve: { $0.lowercased() == "com.getdropbox.dropbox" ? URL(fileURLWithPath: "/Applications/Dropbox.app") : nil }
        )
        let offered = Set(scan(index).map { rel($0.url) })
        XCTAssertFalse(offered.contains("Library/Preferences/com.dropbox.DropboxMacUpdate.plist"),
                       "Dropbox is installed; its updater's data is live")
        XCTAssertTrue(offered.contains("Library/Preferences/com.deadvendor.oldapp.plist"),
                      "a genuine orphan is still found")
    }

    func testMinSizeAndAgeGatesAreHonored() throws {
        try file("Library/Application Support/Figma/tiny.bin", bytes: 1_000, ageDays: 400)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 100, ageDays: 400)
        try file("Library/Application Support/Kite/big.bin", bytes: 5_000_000, ageDays: 1)
        try file("Library/Preferences/com.kite.mail.plist", bytes: 4_000, ageDays: 1)

        let paths = Set(scan(makeIndex()).map { rel($0.url) })
        XCTAssertFalse(paths.contains("Library/Application Support/Figma"), "under the size floor")
        XCTAssertFalse(paths.contains("Library/Application Support/Kite"), "under the age floor")
    }

    func testCuratedMappingRecoversAppsWhoseFolderNameIsNothingLikeTheirBundleID() throws {
        // Arc's bundle id is company.thebrowser.Browser, so no vendor token
        // links it to a folder called "Arc"; only the curated map can.
        try file("Library/Application Support/Arc/User Data/blob.bin", bytes: 5_000_000, ageDays: 400)

        XCTAssertTrue(Set(scan(makeIndex()).map { rel($0.url) })
            .contains("Library/Application Support/Arc"))

        let installed = makeIndex(
            installed: [("Arc", "company.thebrowser.Browser")],
            resolve: { _ in URL(fileURLWithPath: "/Applications/Arc.app") }
        )
        XCTAssertFalse(Set(scan(installed).map { rel($0.url) })
            .contains("Library/Application Support/Arc"))
    }

    func testNoDuplicateOffersAndNothingProtected() throws {
        try file("Library/Application Support/Figma/blob.bin", bytes: 5_000_000, ageDays: 60)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 4_000, ageDays: 60)
        try file("Library/Caches/com.figma.agent/cache.bin", bytes: 500_000, ageDays: 60)
        try file("Library/Application Support/com.deadvendor.oldapp/data.bin", bytes: 2_000_000, ageDays: 60)

        let items = scan(makeIndex())
        let paths = items.map { rel($0.url) }
        XCTAssertEqual(Set(paths).count, paths.count, "every path must be offered exactly once")

        let policy = SafetyPolicy(home: home)
        for item in items {
            XCTAssertFalse(policy.isProtected(item.url), "offered a protected path: \(item.url.path)")
            XCTAssertEqual(item.domain, .user)
            XCTAssertEqual(item.tier, .review)
        }
    }

    /// A leftover can still be *running*: on the machine this was built for,
    /// `figma_agent` was executing out of the Figma folder with Figma
    /// uninstalled. Deleting data under a live process is not a clean-up.
    func testRunningProcessInsideLeftoverBlocksTheOffer() throws {
        try file("Library/Application Support/Figma/DesktopProfile/blob.bin", bytes: 5_000_000, ageDays: 60)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 4_000, ageDays: 60)
        let agent = home.appending(path: "Library/Application Support/Figma/FigmaAgent.app/Contents/MacOS/figma_agent")

        let quiet = makeIndex()
        XCTAssertTrue(Set(scan(quiet).map { rel($0.url) })
            .contains("Library/Application Support/Figma"), "nothing running: offered")

        let busy = InstalledAppIndex(
            bundleIDs: [], runningBundleIDs: [], runningNames: [], tokens: [], vendorTokens: [],
            runningExecutablePaths: [agent.path], resolveBundleID: { _ in nil }
        )
        XCTAssertFalse(Set(scan(busy).map { rel($0.url) })
            .contains("Library/Application Support/Figma"),
            "a live process in the folder must block the offer")
    }

    func testRunningProcessInsideLeftoverIsReportedInstead() throws {
        try file("Library/Application Support/Figma/DesktopProfile/blob.bin", bytes: 5_000_000, ageDays: 60)
        try file("Library/Preferences/com.figma.Desktop.plist", bytes: 4_000, ageDays: 60)
        let agent = home.appending(path: "Library/Application Support/Figma/FigmaAgent.app/Contents/MacOS/figma_agent")
        let index = InstalledAppIndex(
            bundleIDs: [], runningBundleIDs: [], runningNames: [], tokens: [], vendorTokens: [],
            runningExecutablePaths: [agent.path], resolveBundleID: { _ in nil }
        )
        let result = OrphanScanner.scanDetailed(home: home, index: index, policy: SafetyPolicy(home: home))
        XCTAssertEqual(result.blocked.count, 1)
        XCTAssertEqual(result.blocked.first?.kind, .backgroundItem)
        XCTAssertEqual(result.blocked.first?.label, "Figma",
                       "the finding points at the leftover folder the user can act on")
        XCTAssertFalse(result.items.contains { rel($0.url) == "Library/Application Support/Figma" })
    }

    /// The reason the running-process check happens only AFTER evidence: CLI
    /// tools and helper agents legitimately run out of their own folder under
    /// Application Support, and must not be reported as leftovers.
    func testLiveToolRunningFromItsOwnFolderIsNotReported() throws {
        try file("Library/Application Support/Claude/claude-code/2.1.275/blob.bin",
                 bytes: 5_000_000, ageDays: 400)
        let executable = home.appending(
            path: "Library/Application Support/Claude/claude-code/2.1.275/claude.app/Contents/MacOS/claude")
        let index = InstalledAppIndex(
            bundleIDs: ["com.anthropic.claudefordesktop"], runningBundleIDs: [], runningNames: [],
            tokens: ["claude"], vendorTokens: [],
            runningExecutablePaths: [executable.path],
            resolveBundleID: { _ in URL(fileURLWithPath: "/Applications/Claude.app") }
        )
        let result = OrphanScanner.scanDetailed(home: home, index: index, policy: SafetyPolicy(home: home))
        XCTAssertTrue(result.blocked.isEmpty, "no evidence the owner is gone, so nothing to report")
        XCTAssertFalse(result.items.contains { rel($0.url) == "Library/Application Support/Claude" })
    }

    // MARK: - Part B: stale data inside a live vendor folder

    func testStaleVendorSubfolderIsOfferedButRecentSiblingIsNot() throws {
        try file("Library/Application Support/Adobe/AcroCef/Default/blob.bin", bytes: 60_000_000, ageDays: 340)
        try file("Library/Application Support/Adobe/CameraRaw/blob.bin", bytes: 70_000_000, ageDays: 65)

        let index = makeIndex(
            installed: [("Acrobat Distiller", "com.adobe.distiller")],
            resolve: { $0.lowercased() == "com.adobe.distiller" ? URL(fileURLWithPath: "/Applications/Stub.app") : nil }
        )
        let items = scan(index)
        let paths = Set(items.map { rel($0.url) })

        XCTAssertTrue(paths.contains("Library/Application Support/Adobe/AcroCef"),
                      "11 months untouched inside a live vendor folder is dead data")
        XCTAssertFalse(paths.contains("Library/Application Support/Adobe/CameraRaw"),
                       "2 months is far too recent to call dead")
        XCTAssertFalse(paths.contains("Library/Application Support/Adobe"),
                       "the vendor folder itself stays, an Adobe app is installed")

        let acrocef = try XCTUnwrap(items.first { rel($0.url) == "Library/Application Support/Adobe/AcroCef" })
        XCTAssertEqual(acrocef.tier, .review)
        XCTAssertEqual(acrocef.ruleID, "vendor-stale-subfolder")
        XCTAssertEqual(acrocef.group, "adobe")
    }

    func testStaleSubfolderNamedAfterAnInstalledAppIsNotOffered() throws {
        try file("Library/Application Support/Adobe/Photoshop/blob.bin", bytes: 60_000_000, ageDays: 340)
        try file("Library/Application Support/Adobe/AcroCef/blob.bin", bytes: 60_000_000, ageDays: 340)

        let index = makeIndex(
            installed: [("Acrobat Distiller", "com.adobe.distiller"), ("Photoshop", "com.adobe.Photoshop")],
            resolve: { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
        )
        let paths = Set(scan(index).map { rel($0.url) })
        XCTAssertFalse(paths.contains("Library/Application Support/Adobe/Photoshop"),
                       "Photoshop is installed; its support folder is live")
        XCTAssertTrue(paths.contains("Library/Application Support/Adobe/AcroCef"))
    }

    func testSmallOrRecentSubfoldersAreNotOffered() throws {
        try file("Library/Application Support/Adobe/Tiny/blob.bin", bytes: 10_000_000, ageDays: 340)
        try file("Library/Application Support/Adobe/Fresh/blob.bin", bytes: 60_000_000, ageDays: 10)
        let index = makeIndex(
            installed: [("Acrobat Distiller", "com.adobe.distiller")],
            resolve: { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
        )
        let paths = Set(scan(index).map { rel($0.url) })
        XCTAssertFalse(paths.contains("Library/Application Support/Adobe/Tiny"), "under the 50 MB floor")
        XCTAssertFalse(paths.contains("Library/Application Support/Adobe/Fresh"), "under the 180 day floor")
    }

    /// The reason Part B is restricted to *vendor* folders: descending into an
    /// app's own data folder would offer its settings and local history.
    func testPartBNeverDescendsIntoALiveAppsOwnFolder() throws {
        try file("Library/Application Support/Code/User/History/old.bin", bytes: 60_000_000, ageDays: 400)
        try file("Library/Application Support/Code/CachedData/old.bin", bytes: 60_000_000, ageDays: 400)
        try file("Library/Application Support/Cursor/User/History/old.bin", bytes: 60_000_000, ageDays: 400)

        let index = makeIndex(
            installed: [("Visual Studio Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92")],
            resolve: { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
        )
        let offered = Set(scan(index).map { rel($0.url) })
        for path in offered {
            XCTAssertFalse(path.hasPrefix("Library/Application Support/Code/"),
                           "offered a live editor's own data: \(path)")
            XCTAssertFalse(path.hasPrefix("Library/Application Support/Cursor/"),
                           "offered a live editor's own data: \(path)")
        }
    }

    func testSingleChildVendorFolderIsNotTreatedAsAVendorShare() throws {
        try file("Library/Application Support/Adobe/AcroCef/blob.bin", bytes: 60_000_000, ageDays: 340)
        let index = makeIndex(
            installed: [("Acrobat Distiller", "com.adobe.distiller")],
            resolve: { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
        )
        let paths = Set(scan(index).map { rel($0.url) })
        XCTAssertFalse(paths.contains("Library/Application Support/Adobe/AcroCef"),
                       "one child means this is an app's own folder, not a vendor share")
    }

    // MARK: - Name normalization units

    func testNameTokenVariants() {
        XCTAssertTrue(NameToken.variants("anythingllm-desktop").contains("anythingllm"))
        XCTAssertTrue(NameToken.variants("iStat Menus 7").contains("istatmenus"))
        XCTAssertTrue(NameToken.variants("Docker Desktop").contains("docker"))
        XCTAssertEqual(NameToken.normalize("sync-tool"), "synctool")
        XCTAssertEqual(NameToken.normalize("AudioPad AI"), "audiopadai")
        XCTAssertEqual(NameToken.normalize("Logi Tune"), "logitune")
    }
}
