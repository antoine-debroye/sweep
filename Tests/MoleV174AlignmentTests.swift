import XCTest
@testable import SweepCore

/// Ideas taken from tw93/Mole V1.63–V1.74, checked against fixtures. The real
/// disk is never touched.
final class MoleV174AlignmentTests: XCTestCase {
    var root: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "sweep-mole174-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int = 4096, age days: Double = 0) throws {
        let url = root.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        if days > 0 {
            let date = Date().addingTimeInterval(-days * 86_400)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    /// Backdates every file and folder under `relative`: a fresh folder's own
    /// timestamp would otherwise defeat the age gate.
    private func age(_ relative: String, days: Double) throws {
        let top = root.appending(path: relative)
        let date = Date().addingTimeInterval(-days * 86_400)
        var all = [top]
        if let walker = fm.enumerator(at: top, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { all.append(url) }
        }
        for url in all { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    private func rule(_ id: String) -> CleaningRule? {
        RuleCatalog.rules(home: root, includeSystemDomain: false).first { $0.id == id }
    }

    private func scan(_ ids: Set<String>, running: Set<String> = []) async -> [ScanItem] {
        let engine = ScanEngine(policy: SafetyPolicy(home: root), runningExecutableNames: running)
        let rules = RuleCatalog.rules(home: root, includeSystemDomain: false).filter { ids.contains($0.id) }
        return await engine.scanReport(rules: rules).items
    }

    // MARK: Claude Code history

    func testClaudeCodeHistoryIsProtected() {
        let policy = SafetyPolicy(home: root)
        for path in [".claude/projects", ".claude/projects/-Users-me-app/abc.jsonl",
                     ".claude/file-history/x", ".claude/history.jsonl", ".claude/todos/t.json"] {
            XCTAssertTrue(policy.isProtected(root.appending(path: path)), path)
        }
        // Agent worktrees and other tool state stay reachable.
        XCTAssertFalse(policy.isProtected(root.appending(path: ".claude/worktrees/feature")))
    }

    // MARK: Tool downloads kept in caches

    func testToolDownloadsInCachesAreNotOffered() async throws {
        for name in ["llama.cpp", "Cypress", "camoufox", "com.old.app"] {
            try write("Library/Caches/\(name)/blob", age: 40)
        }
        let names = Set(await scan(["user-caches"]).map(\.url.lastPathComponent))
        XCTAssertEqual(names, ["com.old.app"])
    }

    func testPuppeteerAndYarnBerryAreNoLongerCleaned() {
        let paths = RuleCatalog.rules(home: root, includeSystemDomain: false).flatMap(\.paths).map(\.path)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/.cache/puppeteer") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("/.yarn/berry/cache") })
    }

    // MARK: npx

    func testOnlyOldNpxPackagesAreOfferedForReview() async throws {
        try write(".npm/_npx/aaa/node_modules/pkg/index.js", age: 45)
        try write(".npm/_npx/bbb/node_modules/pkg/index.js", age: 2)
        try age(".npm/_npx/aaa", days: 45)
        let items = await scan(["npx-old-packages", "dev-tool-caches"])
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["aaa"])
        XCTAssertEqual(items.first?.tier, .review)
        if let first = items.first { XCTAssertTrue(Cleaner.requiresConclusiveIdle(first)) }
    }

    // MARK: Owner-tool gate

    func testUvCacheWaitsWhileUvRuns() async throws {
        try write(".cache/uv/wheels/a.whl", age: 30)
        try age(".cache/uv", days: 30)
        let idle = await scan(["uv-cache"], running: ["zsh"])
        XCTAssertEqual(idle.count, 1)
        let busy = await scan(["uv-cache"], running: ["uvx"])
        XCTAssertTrue(busy.isEmpty)
    }

    func testDartCacheWaitsWhileFlutterRuns() async throws {
        try write(".dartServer/.analysis-driver/index", age: 30)
        try age(".dartServer/.analysis-driver", days: 30)
        let idle = await scan(["dart-analysis-cache"], running: [])
        XCTAssertEqual(idle.count, 1)
        let busy = await scan(["dart-analysis-cache"], running: ["flutter"])
        XCTAssertTrue(busy.isEmpty)
    }

    // MARK: Adobe

    func testAdobeSharedCachesWaitForAnyAdobeApp() {
        let cache = root.appending(path: "Library/Caches/Adobe")
        let other = root.appending(path: "Library/Caches/com.adobe.dunamis")
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(cache, running: ["com.adobe.photoshop"]))
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(other, running: ["com.adobe.premierepro.25"]))
        // Creative Cloud's resident agents alone don't hold them.
        XCTAssertFalse(RunningAppGuard.isOwnedByRunningApp(
            cache, running: ["com.adobe.acc.adobecreativecloud", "com.adobe.ccxprocess"]))
    }

    // MARK: Kitty

    func testKittyGraphicsCacheIsLiveData() {
        XCTAssertTrue(SafetyPolicy(home: root).isProtected(root.appending(path: "Library/Caches/kitty/graphics")))
    }

    // MARK: Library folders

    func testFirstLevelLibraryFoldersStayButTheirContentsMayGo() {
        let policy = SafetyPolicy(home: root)
        XCTAssertTrue(policy.isProtected(root.appending(path: "Library/Fonts")))
        XCTAssertTrue(policy.isProtected(root.appending(path: "Library/LaunchAgents")))
        XCTAssertTrue(policy.isProtected(URL(fileURLWithPath: "/Library/Fonts")))
        XCTAssertFalse(policy.isProtected(root.appending(path: "Library/Fonts/Old.ttf")))
        XCTAssertFalse(policy.isProtected(root.appending(path: "Library/Caches/com.old.app")))
    }

    // MARK: Cancel

    func testCancelSkipsThePrivilegedBatch() async {
        let privileged = RecordingPrivileged()
        let cleaner = Cleaner(policy: SafetyPolicy(home: root), privileged: privileged)
        let item = ScanItem(
            ruleID: "system-caches", category: .systemDomain,
            url: URL(fileURLWithPath: "/Library/Caches/com.vendor.app"),
            displayName: "com.vendor.app", detail: "", size: 1, fileCount: 1,
            newestModification: nil, tier: .review, domain: .system, forcePermanent: true
        )
        let session = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cleaner.clean(items: [item], source: .smartScan, permanentDelete: false)
        }.value
        XCTAssertTrue(privileged.calls.isEmpty, "no permanent removal after a cancel")
        XCTAssertTrue(session.errors.contains { $0.contains("cancelled") })
    }

    // MARK: Docker

    func testDockerEndpointIsLocalOnlyForSockets() {
        XCTAssertTrue(DockerEndpoint.isLocal("unix:///Users/me/.docker/run/docker.sock\n"))
        XCTAssertTrue(DockerEndpoint.isLocal(""))
        XCTAssertFalse(DockerEndpoint.isLocal("ssh://me@build-box"))
        XCTAssertFalse(DockerEndpoint.isLocal("tcp://10.0.0.5:2376"))
        XCTAssertEqual(DockerEndpoint.effective(dockerHost: "tcp://x:2375", contextHost: "unix:///s"), "tcp://x:2375")
        XCTAssertEqual(DockerEndpoint.effective(dockerHost: " ", contextHost: "unix:///s\n"), "unix:///s")
    }

    // MARK: Uninstaller

    func testVersionedAppNameFindsItsDataFolder() throws {
        XCTAssertEqual(LeftoverFinder.dataFolderNames(for: "Alfred 4"), ["Alfred 4", "Alfred"])
        XCTAssertEqual(LeftoverFinder.dataFolderNames(for: "Office 2016"), ["Office 2016", "Office"])
        XCTAssertEqual(LeftoverFinder.dataFolderNames(for: "Sweep2"), ["Sweep2"])
        XCTAssertEqual(LeftoverFinder.dataFolderNames(for: "Foo"), ["Foo"])

        try write("Library/Application Support/Alfred/prefs.json")
        let items = LeftoverFinder.find(
            bundleID: "com.runningwithcrayons.Alfred", appName: "Alfred 4", depth: .enhanced, home: root
        )
        let match = items.first { $0.url.lastPathComponent == "Alfred" }
        XCTAssertNotNil(match)
        XCTAssertNotEqual(match?.tier, .safe, "a data folder is never pre-selected")
    }

    func testTeamViewerAndAvastGoToTheirOwnUninstallers() {
        XCTAssertTrue(BundleProtection.securityAgentPrefixes.contains { "com.teamviewer.teamviewer".hasPrefix($0) })
        XCTAssertTrue(BundleProtection.securityAgentPrefixes.contains { "com.avast.avast-one".hasPrefix($0) })
    }

    // MARK: Launch audit

    func testBareCommandsAndTildePathsAreNotOrphans() throws {
        try fm.createDirectory(at: root.appending(path: "agents"), withIntermediateDirectories: true)
        try write("bin/mytool")
        func plist(_ name: String, _ contents: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
            try data.write(to: root.appending(path: "agents/\(name).plist"))
        }
        try plist("bare", ["Label": "bare", "ProgramArguments": ["sh", "-c", "echo hi"]])
        try plist("tilde", ["Label": "tilde", "ProgramArguments": ["~/bin/mytool"]])
        try plist("gone", ["Label": "gone", "Program": "~/bin/missing"])

        var roots = LaunchItemAudit.Roots(home: root)
        roots.userAgents = root.appending(path: "agents")
        roots.systemAgents = root.appending(path: "none")
        roots.systemDaemons = root.appending(path: "none")
        roots.privilegedHelpers = root.appending(path: "none")
        let index = InstalledAppIndex(bundleIDs: [], runningBundleIDs: [], resolveBundleID: { _ in nil })
        let findings = LaunchItemAudit.audit(home: root, index: index, roots: roots)
        XCTAssertEqual(findings.map(\.label), ["gone"])
    }

    // MARK: Idle simulators

    private func device(_ udid: String, state: Int) throws {
        let dir = root.appending(path: "Library/Developer/CoreSimulator/Devices/\(udid)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["UDID": udid, "state": state], format: .xml, options: 0)
        try data.write(to: dir.appending(path: "device.plist"))
        for leaf in ["data/Library/Caches/com.apple.PosterBoard/a", "data/var/db/diagnostics/x.tracev3",
                     "data/var/db/uuidtext/AB/cd", "data/private/var/MobileAsset/AssetsV2/x",
                     "data/Library/Preferences/keep.plist"] {
            try write("Library/Developer/CoreSimulator/Devices/\(udid)/\(leaf)", age: 3)
        }
        try age("Library/Developer/CoreSimulator/Devices/\(udid)/data", days: 3)
    }

    func testIdleSimulatorDataOffersOnlyRebuildableLeaves() async throws {
        try device("AAA", state: 1)
        try device("BBB", state: 1)
        let items = await scan(["simulator-idle-device-data"])
        let leaves = Set(items.map { $0.url.pathComponents.suffix(2).joined(separator: "/") })
        XCTAssertEqual(leaves, ["Library/Caches", "db/diagnostics", "db/uuidtext", "var/MobileAsset"])
        XCTAssertEqual(items.count, 8)
        XCTAssertTrue(items.allSatisfy { $0.tier == .review })
        XCTAssertFalse(items.contains { $0.url.path.contains("Preferences") })
    }

    func testNothingIsOfferedWhileAnySimulatorIsBooted() async throws {
        try device("AAA", state: 1)
        try device("BBB", state: 3)
        XCTAssertTrue(DynamicPaths.idleSimulatorDeviceData(home: root).isEmpty)
    }

    func testAnUnreadableDeviceStopsTheWholeBatch() throws {
        try device("AAA", state: 1)
        try fm.createDirectory(
            at: root.appending(path: "Library/Developer/CoreSimulator/Devices/BROKEN"), withIntermediateDirectories: true)
        XCTAssertTrue(DynamicPaths.idleSimulatorDeviceData(home: root).isEmpty)
    }

    func testSimulatorToolsRunningHoldTheRule() async throws {
        try device("AAA", state: 1)
        let busy = await scan(["simulator-idle-device-data"], running: ["simulator"])
        XCTAssertTrue(busy.isEmpty)
    }

    func testALeafLinkedOutOfTheDeviceIsNotFollowed() throws {
        try device("AAA", state: 1)
        let caches = root.appending(path: "Library/Developer/CoreSimulator/Devices/AAA/data/Library/Caches")
        try fm.removeItem(at: caches)
        try write("elsewhere/precious")
        try fm.createSymbolicLink(at: caches, withDestinationURL: root.appending(path: "elsewhere"))
        let found = DynamicPaths.idleSimulatorDeviceData(home: root)
        XCTAssertFalse(found.contains { $0.lastPathComponent == "Caches" })
        XCTAssertFalse(found.isEmpty)
    }
}

final class RecordingPrivileged: PrivilegedRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    func removePrivileged(paths: [String]) async throws -> String {
        lock.withLock { calls.append(paths) }
        return ""
    }
}
