import XCTest
@testable import SweepCore

/// Coverage for the dynamic (installed-app driven) rules: sandbox containers,
/// group containers, Chromium profiles, Electron apps, versioned tool
/// installs and the safety nets around them. Everything runs against a
/// fixture home in a temp folder.
final class DeepCleanRulesTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-deep-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 1_000_000, ageDays: Int = 0) throws -> URL {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        // Age gating looks at the newest mtime in the whole item, including the
        // folders themselves, so every ancestor up to the fixture home is aged.
        var dir = url.deletingLastPathComponent()
        while dir.path.count > home.path.count {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
            dir = dir.deletingLastPathComponent()
        }
        return url
    }

    private func dir(_ relative: String) throws -> URL {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Path relative to the fixture home; paths outside it (rules keyed off
    /// the real TMPDIR) come back prefixed with "!" so assertions can ignore them.
    private func rel(_ url: URL) -> String {
        let base = home.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return "!" + path }
        return String(path.dropFirst(base.count + 1))
    }

    private func scanItems(runningBundleIDs: Set<String> = [], runningNames: Set<String> = []) async -> [ScanItem] {
        let policy = SafetyPolicy(home: home)
        let engine = ScanEngine(policy: policy, runningBundleIDs: runningBundleIDs, runningAppNames: runningNames)
        let rules = RuleCatalog.rules(home: home, includeSystemDomain: false)
        return await engine.scanReport(rules: rules).items
    }

    // MARK: - Sandboxed containers

    func testContainerCachesOfferedButAppleAndDenylistedContainersSkipped() throws {
        try file("Library/Containers/com.microsoft.teams2/Data/Library/Caches/Cache.db", ageDays: 5)
        try file("Library/Containers/com.microsoft.teams2/Data/Library/Logs/teams.log", ageDays: 5)
        try file("Library/Containers/com.microsoft.teams2/Data/tmp/scratch.bin", ageDays: 10)
        try file("Library/Containers/com.microsoft.teams2/Data/Documents/real.docx", ageDays: 10)
        try file("Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/blob", ageDays: 5)   // allow-listed Apple
        try file("Library/Containers/com.apple.Notes/Data/Library/Caches/blob", ageDays: 5)             // Apple, not allow-listed
        try file("Library/Containers/com.apple.Safari/Data/Library/Caches/blob", ageDays: 5)            // dedicated browser rule
        try file("Library/Containers/com.docker.docker/Data/Library/Caches/blob", ageDays: 5)           // deny-listed

        let cacheRoots = DynamicPaths.containerCacheRoots(home: home).map(rel)
        XCTAssertEqual(Set(cacheRoots), [
            "Library/Containers/com.microsoft.teams2/Data/Library/Caches",
            "Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches",
        ])
        XCTAssertEqual(DynamicPaths.containerLogRoots(home: home).map(rel),
                       ["Library/Containers/com.microsoft.teams2/Data/Library/Logs"])
        XCTAssertEqual(DynamicPaths.containerTmpRoots(home: home).map(rel),
                       ["Library/Containers/com.microsoft.teams2/Data/tmp"])
    }

    func testContainerScanOffersChildrenOnlyAndSkipsRunningApp() async throws {
        try file("Library/Containers/com.microsoft.teams2/Data/Library/Caches/Cache.db", ageDays: 5)
        try file("Library/Containers/com.microsoft.teams2/Data/Documents/real.docx", ageDays: 10)

        let idle = await scanItems()
        let offered = idle.filter { $0.ruleID == "container-caches" }.map { rel($0.url) }
        XCTAssertEqual(offered, ["Library/Containers/com.microsoft.teams2/Data/Library/Caches/Cache.db"])
        XCTAssertFalse(idle.contains { $0.url.path.contains("Documents/real.docx") })
        XCTAssertEqual(idle.first { $0.ruleID == "container-caches" }?.displayName, "com.microsoft.teams2 › Caches › Cache.db")

        let running = await scanItems(runningBundleIDs: ["com.microsoft.teams2"])
        XCTAssertFalse(running.contains { $0.ruleID == "container-caches" }, "caches of a running sandboxed app must be skipped")
    }

    // MARK: - Group containers & File Provider protection

    func testGroupContainersSkipAppleAndFileProviderStores() throws {
        try file("Library/Group Containers/ABC123.com.vendor.app/Library/Caches/x.bin")
        try file("Library/Group Containers/ABC123.com.vendor.app/Logs/y.log")
        try file("Library/Group Containers/group.com.apple.notes/Library/Caches/x.bin")
        try file("Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/Library/Caches/x.bin")
        try file("Library/Group Containers/XYZ.some.sync/File Provider Storage/doc.pdf")
        try file("Library/Group Containers/XYZ.some.sync/Library/Caches/x.bin")

        let junk = DynamicPaths.groupContainerJunk(home: home)
        XCTAssertEqual(junk.caches.map(rel), ["Library/Group Containers/ABC123.com.vendor.app/Library/Caches"])
        XCTAssertEqual(junk.logs.map(rel), ["Library/Group Containers/ABC123.com.vendor.app/Logs"])

        let policy = SafetyPolicy(home: home)
        XCTAssertTrue(policy.isProtected(home.appending(path: "Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/OneDrive.noindex/Contract.pdf")),
                      "OneDrive's backing store holds the real synced files and must be hard-protected")
        XCTAssertTrue(policy.isProtected(home.appending(path: "Library/Group Containers/XYZ.some.sync/File Provider Storage/doc.pdf")))
        XCTAssertFalse(policy.isProtected(home.appending(path: "Library/Group Containers/ABC123.com.vendor.app/Library/Caches/x.bin")))
    }

    // MARK: - Chromium profiles

    func testChromiumProfileCachesSplitIntoSafeAndReview() throws {
        try file("Library/Application Support/Google/Chrome/Default/Code Cache/js/0")
        try file("Library/Application Support/Google/Chrome/Default/GPUCache/data_0")
        try file("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage/abc/0")
        try file("Library/Application Support/Google/Chrome/Default/Bookmarks")
        try file("Library/Application Support/Google/Chrome/Default/Login Data")
        try file("Library/Application Support/Google/Chrome/Profile 3/Code Cache/js/0")
        try file("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel/1.0/weights.bin")
        try file("Library/Application Support/Google/Chrome/GrShaderCache/data_0")
        try file("Library/Application Support/Google/Chrome/Local State")
        try file("Library/Application Support/BraveSoftware/Brave-Browser/Profile 1/GPUCache/data_0")
        try file("Library/Application Support/Firefox/Profiles/abcd.default/cache2/entries/0")
        try file("Library/Application Support/Firefox/Profiles/abcd.default/places.sqlite")

        let junk = DynamicPaths.chromiumJunk(home: home)
        XCTAssertEqual(Set(junk.safe.map(rel)), [
            "Library/Application Support/Google/Chrome/GrShaderCache",
            "Library/Application Support/Google/Chrome/Default/Code Cache",
            "Library/Application Support/Google/Chrome/Default/GPUCache",
            "Library/Application Support/Google/Chrome/Profile 3/Code Cache",
            "Library/Application Support/BraveSoftware/Brave-Browser/Profile 1/GPUCache",
            "Library/Application Support/Firefox/Profiles/abcd.default/cache2",
        ])
        XCTAssertEqual(Set(junk.review.map(rel)), [
            "Library/Application Support/Google/Chrome/OptGuideOnDeviceModel",
            "Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage",
        ])
        let all = junk.safe + junk.review
        XCTAssertFalse(all.contains { $0.path.contains("Bookmarks") || $0.path.contains("Login Data") || $0.path.contains("places.sqlite") })
    }

    func testChromiumCachesSkippedWhileBrowserRuns() async throws {
        try file("Library/Application Support/Google/Chrome/Default/Code Cache/js/0", ageDays: 3)
        let idle = await scanItems()
        XCTAssertTrue(idle.contains { $0.ruleID == "browser-profile-caches" })
        XCTAssertEqual(idle.first { $0.ruleID == "browser-profile-caches" }?.displayName, "Chrome › Default › Code Cache")
        let running = await scanItems(runningBundleIDs: ["com.google.chrome"])
        XCTAssertFalse(running.contains { $0.ruleID == "browser-profile-caches" })
    }

    // MARK: - Electron apps

    func testElectronDetectionRequiresChromiumMarkerAndCoversPartitions() throws {
        // A real Electron app: markers present → its caches are offered.
        try file("Library/Application Support/Notion/Code Cache/js/0")
        try file("Library/Application Support/Notion/Cache/data_0")
        try file("Library/Application Support/Notion/Partitions/notion/Cache/data_0")
        try file("Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage/x/0")
        try file("Library/Application Support/Notion/Partitions/notion/IndexedDB/db.leveldb/0")
        try file("Library/Application Support/Notion/notion.db")
        try file("Library/Application Support/Notion/logs/main.log")
        // Not Electron: a "Cache" folder with no Chromium marker stays untouched.
        try file("Library/Application Support/SomeNativeApp/Cache/important.db")
        // Dedicated rules exist for these; the heuristic must not double-offer.
        try file("Library/Application Support/Cursor/Code Cache/js/0")
        try file("Library/Application Support/Code/GPUCache/data_0")

        let junk = DynamicPaths.electronJunk(home: home)
        XCTAssertEqual(Set(junk.safe.map(rel)), [
            "Library/Application Support/Notion/Cache",
            "Library/Application Support/Notion/Code Cache",
            "Library/Application Support/Notion/Partitions/notion/Cache",
        ])
        XCTAssertEqual(Set(junk.review.map(rel)), [
            "Library/Application Support/Notion/logs",
            "Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage",
        ])
        let all = (junk.safe + junk.review).map(rel)
        XCTAssertFalse(all.contains { $0.contains("IndexedDB") || $0.contains("notion.db") || $0.contains("SomeNativeApp") })
    }

    func testElectronCachesSkippedWhenAppRunsByName() async throws {
        try file("Library/Application Support/Notion/Code Cache/js/0", ageDays: 3)
        try file("Library/Application Support/Notion/Cache/data_0", ageDays: 3)
        let idle = await scanItems()
        XCTAssertEqual(idle.filter { $0.ruleID == "electron-app-caches" }.count, 2)
        // Notion's bundle id is "notion.id" — nothing in the path matches it,
        // so the display name is the only usable signal.
        let running = await scanItems(runningNames: ["notion"])
        XCTAssertTrue(running.filter { $0.ruleID == "electron-app-caches" }.isEmpty)
    }

    // MARK: - Versioned installs

    func testStaleVersionDirsKeepNewestAndActive() throws {
        try file(".local/share/claude/versions/2.1.236/claude")
        try file(".local/share/claude/versions/2.1.237/claude")
        try file(".local/share/claude/versions/2.1.238/claude")
        try file(".local/share/claude/versions/2.1.240/claude")
        let bin = try dir(".local/bin")
        // Active symlink points at an OLDER version than the newest on disk.
        try fm.createSymbolicLink(
            at: bin.appending(path: "claude"),
            withDestinationURL: home.appending(path: ".local/share/claude/versions/2.1.237")
        )
        let stale = DynamicPaths.staleVersionDirs(
            root: home.appending(path: ".local/share/claude/versions"),
            activeLink: bin.appending(path: "claude")
        ).map(\.lastPathComponent)
        XCTAssertEqual(Set(stale), ["2.1.236", "2.1.238"], "newest (2.1.240) and active (2.1.237) must survive")
    }

    func testStaleVersionDirsHonorPinnedAndNonSemver() throws {
        try file("Library/Application Support/Claude/claude-code-vm/2.1.258/x")
        try file("Library/Application Support/Claude/claude-code-vm/2.1.260/x")
        try file("Library/Application Support/Claude/claude-code-vm/2.1.255/x")
        let stale = DynamicPaths.staleVersionDirs(
            root: home.appending(path: "Library/Application Support/Claude/claude-code-vm"),
            pinnedVersions: ["2.1.255"]
        ).map(\.lastPathComponent)
        XCTAssertEqual(stale, ["2.1.258"])

        try file(".local/share/cursor-agent/versions/2026.04.17-787b533/cursor-agent")
        try file(".local/share/cursor-agent/versions/2026.03.02-1a2b3c4/cursor-agent")
        let cursorStale = DynamicPaths.staleVersionDirs(root: home.appending(path: ".local/share/cursor-agent/versions"))
            .map(\.lastPathComponent)
        XCTAssertEqual(cursorStale, ["2026.03.02-1a2b3c4"])

        // Fewer dirs than `keep` → nothing.
        XCTAssertTrue(DynamicPaths.staleVersionDirs(root: home.appending(path: "nope")).isEmpty)
    }

    func testStaleVersionsCanBeSingleFiles() throws {
        // Claude Code installs each version as one executable file.
        try file(".local/share/claude/versions/2.1.236", bytes: 10)
        try file(".local/share/claude/versions/2.1.237", bytes: 10)
        try file(".local/share/claude/versions/2.1.238", bytes: 10)
        let bin = try dir(".local/bin")
        try fm.createSymbolicLink(
            at: bin.appending(path: "claude"),
            withDestinationURL: home.appending(path: ".local/share/claude/versions/2.1.238")
        )
        let stale = DynamicPaths.staleVersionDirs(
            root: home.appending(path: ".local/share/claude/versions"),
            activeLink: bin.appending(path: "claude")
        ).map(\.lastPathComponent)
        XCTAssertEqual(Set(stale), ["2.1.236", "2.1.237"])
    }

    func testTinyItemsFallBelowTheRuleFloor() async throws {
        try file("Library/Containers/com.vendor.app/Data/tmp/big.bin", bytes: 6_000_000, ageDays: 10)
        try file("Library/Containers/com.vendor.app/Data/tmp/tiny-uuid-dir/x", bytes: 100, ageDays: 10)
        let items = await scanItems().filter { $0.ruleID == "container-tmp" }
        XCTAssertEqual(items.map { $0.url.lastPathComponent }, ["big.bin"])
    }

    func testObsoleteExtensionsReadFromEditorMarker() throws {
        try file(".cursor/extensions/anthropic.claude-code-2.1.160/package.json")
        try file(".cursor/extensions/anthropic.claude-code-2.1.180/package.json")
        try file(".cursor/extensions/anysphere.remote-ssh-1.1.7/package.json")
        let marker = #"{"anthropic.claude-code-2.1.160":true,"../escape":true,"missing-dir":true}"#
        try marker.data(using: .utf8)!.write(to: home.appending(path: ".cursor/extensions/.obsolete"))
        let dirs = DynamicPaths.obsoleteExtensionDirs(extensionsRoot: home.appending(path: ".cursor/extensions"))
        XCTAssertEqual(dirs.map(\.lastPathComponent), ["anthropic.claude-code-2.1.160"])
    }

    func testIncompleteCodexRuntimesLackRuntimeJSON() throws {
        try file(".cache/codex-runtimes/codex-primary-runtime/runtime.json", bytes: 10)
        try file(".cache/codex-runtimes/codex-primary-runtime/dependencies/x")
        try file(".cache/codex-runtimes/codex-runtime-install-EMYBdd/node-runtime.tar.xz")
        XCTAssertEqual(DynamicPaths.incompleteCodexRuntimes(home: home).map(\.lastPathComponent),
                       ["codex-runtime-install-EMYBdd"])
    }

    func testDeviceSupportKeepsNewestTwoPerPlatform() throws {
        try file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)/Symbols/x", ageDays: 400)
        try file("Library/Developer/Xcode/iOS DeviceSupport/18.4 (22E238)/Symbols/x", ageDays: 90)
        try file("Library/Developer/Xcode/iOS DeviceSupport/26.0 (23A8464)/Symbols/x", ageDays: 30)
        try file("Library/Developer/Xcode/iOS DeviceSupport/26.5 (23F77)/Symbols/x", ageDays: 1)
        try file("Library/Developer/Xcode/watchOS DeviceSupport/11.4 (22T250)/Symbols/x", ageDays: 200)
        let stale = DynamicPaths.staleDeviceSupport(home: home, keep: 2).map(\.lastPathComponent)
        XCTAssertEqual(Set(stale), ["17.0 (21A329)", "18.4 (22E238)"])
    }

    // MARK: - Running-app guard

    func testRunningAppGuardMatchesNamesAndMappedTools() {
        // Known Electron apps are mapped folder-name → bundle id…
        let notion = URL(fileURLWithPath: "/Users/x/Library/Application Support/Notion/Code Cache")
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(notion, running: ["notion.id"]))
        XCTAssertFalse(RunningAppGuard.isOwnedByRunningApp(notion, running: ["com.other.app"]))
        // …and unknown ones are caught by the running app's display name.
        let other = URL(fileURLWithPath: "/Users/x/Library/Application Support/SyncTool/Cache")
        XCTAssertFalse(RunningAppGuard.isOwnedByRunningApp(other, running: ["com.vendor.synctool"]))
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(other, running: ["com.vendor.synctool"], names: ["synctool"]))
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(other, running: [], names: ["SYNCTOOL"]))

        let clang = URL(fileURLWithPath: "/var/folders/ab/xyz/C/clang")
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(clang, running: ["com.apple.dt.xcode"]))
        XCTAssertFalse(RunningAppGuard.isOwnedByRunningApp(clang, running: ["com.apple.finder"]))

        let brave = URL(fileURLWithPath: "/Users/x/Library/Application Support/BraveSoftware/Brave-Browser/Profile 1/GPUCache")
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(brave, running: ["com.brave.browser"]))
    }

    // MARK: - Display names

    func testDisplayNamesCarryTheOwningApp() {
        func name(_ path: String) -> String { ScanEngine.displayName(for: URL(fileURLWithPath: path)) }
        XCTAssertEqual(name("/U/x/Library/Containers/com.microsoft.teams2/Data/Library/Caches/Cache.db"), "com.microsoft.teams2 › Caches › Cache.db")
        XCTAssertEqual(name("/U/x/Library/Application Support/Notion/Partitions/notion/Cache"), "Notion › notion › Cache")
        XCTAssertEqual(name("/U/x/Library/Application Support/Google/Chrome/Profile 3/Code Cache"), "Chrome › Profile 3 › Code Cache")
        XCTAssertEqual(name("/U/x/Library/Application Support/Claude/vm_bundles"), "Claude › vm_bundles")
        XCTAssertEqual(name("/U/x/Library/Caches/com.vendor.app"), "com.vendor.app")
        XCTAssertEqual(name("/U/x/Library/Application Support/Cursor"), "Cursor")
    }

    // MARK: - Catalog invariants

    func testNewSafeRulesNeverTargetUserDataFolders() async throws {
        // Build a realistic tree and make sure nothing under the classic
        // user-data locations of each app is ever offered as Safe.
        try file("Library/Application Support/Google/Chrome/Default/Bookmarks", ageDays: 30)
        try file("Library/Application Support/Google/Chrome/Default/History", ageDays: 30)
        try file("Library/Application Support/Google/Chrome/Default/Code Cache/js/0", ageDays: 30)
        try file("Library/Application Support/Notion/Partitions/notion/IndexedDB/x", ageDays: 30)
        try file("Library/Application Support/Notion/Code Cache/js/0", ageDays: 30)
        try file("Library/Application Support/Cursor/User/globalStorage/state.vscdb", ageDays: 30)
        try file("Library/Application Support/Cursor/Code Cache/js/0", ageDays: 30)
        try file("Library/Containers/net.whatsapp.WhatsApp/Data/Library/Application Support/ChatStorage.sqlite", ageDays: 30)
        try file("Library/Containers/net.whatsapp.WhatsApp/Data/Library/Caches/img.jpg", ageDays: 30)
        try file("Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/OneDrive.noindex/Contract.pdf", ageDays: 30)

        let items = await scanItems()
        let offered = items.map { rel($0.url) }.filter { !$0.hasPrefix("!") }
        for forbidden in ["Bookmarks", "History", "IndexedDB", "state.vscdb", "ChatStorage.sqlite", "Contract.pdf"] {
            XCTAssertFalse(offered.contains { $0.contains(forbidden) }, "\(forbidden) must never be offered; got \(offered)")
        }
        XCTAssertTrue(offered.contains("Library/Application Support/Google/Chrome/Default/Code Cache"))
        XCTAssertTrue(offered.contains("Library/Application Support/Notion/Code Cache"))
        XCTAssertTrue(offered.contains("Library/Application Support/Cursor/Code Cache"))
        XCTAssertTrue(offered.contains("Library/Containers/net.whatsapp.WhatsApp/Data/Library/Caches/img.jpg"))
        // The same path must not be offered by two rules.
        XCTAssertEqual(Set(offered).count, offered.count, "duplicate offers: \(offered)")
    }
}
