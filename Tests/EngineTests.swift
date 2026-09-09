import XCTest
@testable import SweepCore

/// Engine behavior against a fixture home directory built in a temp folder —
/// the real disk is never touched by these tests.
final class EngineTests: XCTestCase {
    var fixtureHome: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        fixtureHome = fm.temporaryDirectory
            .appending(path: "sweep-fixture-\(UUID().uuidString)")
        try makeFixtureTree()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: fixtureHome)
    }

    /// Builds:
    ///   Library/Caches/com.old.app/blob.bin        (5 MB, 40 days old)
    ///   Library/Caches/com.running.app/blob.bin    (3 MB — owner "running")
    ///   Library/Caches/com.apple.bird/x.bin        (excluded name)
    ///   Library/Logs/old.log                       (1 MB, 30 days old)
    ///   Library/Logs/fresh.log                     (1 MB, today → age-gated)
    ///   Documents/important.txt                    (must never appear)
    ///   Desktop/Setup.dmg                          (old, but Desktop is protected)
    ///   Downloads/Installer.dmg                    (2 MB, 30 days old)
    ///   Downloads/report.pdf                       (wrong extension)
    private func makeFixtureTree() throws {
        let old = Date().addingTimeInterval(-40 * 86_400)
        let monthOld = Date().addingTimeInterval(-30 * 86_400)

        try write("Library/Caches/com.old.app/blob.bin", megabytes: 5, date: old)
        try write("Library/Caches/com.running.app/blob.bin", megabytes: 3, date: old)
        try write("Library/Caches/com.apple.bird/x.bin", megabytes: 2, date: old)
        try write("Library/Logs/old.log", megabytes: 1, date: monthOld)
        try write("Library/Logs/fresh.log", megabytes: 1, date: Date())
        try write("Documents/important.txt", megabytes: 1, date: old)
        try write("Desktop/Setup.dmg", megabytes: 2, date: monthOld)
        try write("Downloads/Installer.dmg", megabytes: 2, date: monthOld)
        try write("Downloads/report.pdf", megabytes: 2, date: monthOld)
    }

    private func setDateRecursively(_ date: Date, under relative: String) throws {
        let root = fixtureHome.appending(path: relative)
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            var urls: [URL] = [root]
            while let url = enumerator.nextObject() as? URL { urls.append(url) }
            for url in urls {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
    }

    private func write(_ relative: String, megabytes: Int, date: Date) throws {
        let url = fixtureHome.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: 0xAB, count: megabytes * 1_000_000)
        try data.write(to: url)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        // Parent dir mtime also matters for age gating of contentsOnly items.
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.deletingLastPathComponent().path)
    }

    private func scan() async -> [ScanItem] {
        let policy = SafetyPolicy(home: fixtureHome)
        let engine = ScanEngine(policy: policy, runningBundleIDs: ["com.running.app"])
        let rules = RuleCatalog.rules(home: fixtureHome, includeSystemDomain: false)
        let report = await engine.scanReport(rules: rules)
        return report.items
    }

    // MARK: - Tests

    func testScanFindsJunkAndHonorsGates() async {
        let items = await scan()
        let paths = Set(items.map { $0.url.lastPathComponent })

        XCTAssertTrue(paths.contains("com.old.app"), "stale cache must be found")
        XCTAssertFalse(paths.contains("com.running.app"), "caches of running apps must be skipped")
        XCTAssertFalse(paths.contains("com.apple.bird"), "excluded names must be skipped")
        XCTAssertTrue(paths.contains("old.log"), "old log must be found")
        XCTAssertFalse(paths.contains("fresh.log"), "fresh log must be age-gated out")
        XCTAssertTrue(paths.contains("Installer.dmg"), "old installer in Downloads must be found")
        XCTAssertFalse(paths.contains("report.pdf"), "non-installer extensions must be skipped")
    }

    func testScanNeverEmitsProtectedPaths() async {
        let items = await scan()
        let policy = SafetyPolicy(home: fixtureHome)
        for item in items {
            XCTAssertFalse(policy.isProtected(item.url), "scan emitted protected path \(item.url.path)")
            XCTAssertFalse(item.url.path.contains("/Documents/"), "Documents leaked into scan: \(item.url.path)")
            XCTAssertFalse(item.url.path.contains("/Desktop/"), "Desktop leaked into scan: \(item.url.path)")
        }
    }

    func testWhitelistExcludesItems() async {
        let policy = SafetyPolicy(home: fixtureHome)
        let whitelisted = fixtureHome.appending(path: "Library/Caches/com.old.app").path
        let engine = ScanEngine(policy: policy, whitelist: [whitelisted])
        let rules = RuleCatalog.rules(home: fixtureHome, includeSystemDomain: false)
        let report = await engine.scanReport(rules: rules)
        XCTAssertFalse(
            report.items.contains { $0.url.path == whitelisted },
            "whitelisted path must not be offered"
        )
    }

    func testSizesAreAccurate() async {
        let items = await scan()
        guard let cache = items.first(where: { $0.url.lastPathComponent == "com.old.app" }) else {
            return XCTFail("expected com.old.app item")
        }
        XCTAssertGreaterThanOrEqual(cache.size, 4_900_000)
        XCTAssertEqual(cache.fileCount, 1)
    }

    // MARK: - Cleaner

    func testCleanerMovesItemsAndRefusesProtected() async {
        let policy = SafetyPolicy(home: fixtureHome)
        let recorder = RecordingRemover()
        let cleaner = Cleaner(policy: policy, trashRemover: recorder, permanentRemover: recorder)

        let junk = ScanItem(
            ruleID: "user-caches", category: .systemJunk,
            url: fixtureHome.appending(path: "Library/Caches/com.old.app"),
            displayName: "com.old.app", detail: "", size: 5_000_000, fileCount: 1,
            newestModification: nil, tier: .safe, domain: .user
        )
        let protected = ScanItem(
            ruleID: "user-caches", category: .systemJunk,
            url: fixtureHome.appending(path: "Documents/important.txt"),
            displayName: "important.txt", detail: "", size: 1_000_000, fileCount: 1,
            newestModification: nil, tier: .safe, domain: .user
        )

        let session = await cleaner.clean(
            items: [junk, protected],
            source: .smartScan,
            permanentDelete: false
        )

        XCTAssertEqual(recorder.removed.count, 1, "only the junk item may be removed")
        XCTAssertEqual(recorder.removed.first?.lastPathComponent, "com.old.app")
        XCTAssertEqual(session.items.count, 1)
        XCTAssertEqual(session.errors.count, 1, "protected refusal must be reported")
        XCTAssertTrue(session.errors[0].contains("Refused protected path"))
    }

    func testCleanerSkipsSystemItemsWithoutPrivilegedRemover() async {
        let policy = SafetyPolicy(home: fixtureHome)
        let recorder = RecordingRemover()
        let cleaner = Cleaner(policy: policy, trashRemover: recorder, permanentRemover: recorder, privileged: nil)
        let systemItem = ScanItem(
            ruleID: "system-caches", category: .systemDomain,
            url: URL(fileURLWithPath: "/Library/Caches/com.vendor.app"),
            displayName: "com.vendor.app", detail: "", size: 1, fileCount: 1,
            newestModification: nil, tier: .review, domain: .system, forcePermanent: true
        )
        let session = await cleaner.clean(items: [systemItem], source: .smartScan, permanentDelete: false)
        XCTAssertTrue(recorder.removed.isEmpty, "system items must never be removed directly")
        XCTAssertEqual(session.items.count, 0)
        XCTAssertEqual(session.errors.count, 1)
    }

    // MARK: - History undo

    func testHistoryUndoRestoresFromTrashLocation() async throws {
        let historyFile = fixtureHome.appending(path: "history.json")
        let store = HistoryStore(fileURL: historyFile)

        // Simulate: a file was moved to a "trash" location.
        let original = fixtureHome.appending(path: "Library/Caches/com.old.app/blob.bin")
        let trashed = fixtureHome.appending(path: "trash-blob.bin")
        try fm.moveItem(at: original, to: trashed)

        var session = CleanSession(date: Date(), source: .smartScan, items: [], errors: [])
        session.items.append(CleanedItem(
            originalPath: original.path,
            trashPath: trashed.path,
            size: 5_000_000,
            displayName: "blob.bin",
            category: .systemJunk
        ))
        await store.add(session)

        let result = await store.undo(sessionID: session.id)
        XCTAssertEqual(result.restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: original.path), "file must be back at its original path")
        XCTAssertFalse(fm.fileExists(atPath: trashed.path))
    }

    // MARK: - Project artifacts

    func testTrashHeldAndPurgeOnlyTouchSweepsOwnItems() async throws {
        let trash = fixtureHome.appending(path: ".Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try write(".Trash/sweep-moved.bin", megabytes: 2, date: Date())
        try write(".Trash/users-own-file.txt", megabytes: 1, date: Date())
        // A recorded item whose Trash copy is already gone must not count.
        let store = HistoryStore(fileURL: fixtureHome.appending(path: "history.json"))
        let session = CleanSession(date: Date().addingTimeInterval(-3 * 86_400), source: .smartScan, items: [
            CleanedItem(originalPath: "/orig/sweep-moved.bin", trashPath: trash.appending(path: "sweep-moved.bin").path,
                        size: 2_000_000, displayName: "sweep-moved.bin", category: .systemJunk),
            CleanedItem(originalPath: "/orig/gone.bin", trashPath: trash.appending(path: "gone.bin").path,
                        size: 9_000_000, displayName: "gone.bin", category: .systemJunk),
            CleanedItem(originalPath: "/orig/permanent.bin", trashPath: nil,
                        size: 5_000_000, displayName: "permanent.bin", category: .systemJunk),
        ], errors: [])
        await store.add(session)

        // An OLDER session whose Trash file was emptied long ago, but whose
        // path Finder has since reused for the newer item above: must not be
        // counted twice (the real card once promised 5.95 GB and freed 2.85).
        let stale = CleanSession(date: Date().addingTimeInterval(-30 * 86_400), source: .smartScan, items: [
            CleanedItem(originalPath: "/orig/old/sweep-moved.bin", trashPath: trash.appending(path: "sweep-moved.bin").path,
                        size: 7_000_000, displayName: "sweep-moved.bin", category: .systemJunk),
        ], errors: [])
        await store.add(stale)

        let held = await store.trashHeld()
        XCTAssertEqual(held.count, 1, "a reused Trash path counts once")
        XCTAssertEqual(held.bytes, 2_000_000, "attributed to the newest session's record")
        XCTAssertNotNil(held.oldest)

        let result = await store.purgeTrashedItems()
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.bytes, 2_000_000)
        XCTAssertEqual(result.errors, 0)
        XCTAssertFalse(fm.fileExists(atPath: trash.appending(path: "sweep-moved.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: trash.appending(path: "users-own-file.txt").path), "the user's own Trash content is never touched")
        let after = await store.trashHeld()
        XCTAssertEqual(after.count, 0)
        let restorable = await store.sessions().first?.restorableCount
        XCTAssertEqual(restorable, 0, "purged items must no longer be offered for undo")
    }

    func testProjectArtifactScannerFindsStaleBuildDirs() throws {
        let old = Date().addingTimeInterval(-60 * 86_400)
        try write("Developer/myapp/node_modules/pkg/index.js", megabytes: 1, date: old)
        try write("Developer/myapp/src/main.ts", megabytes: 1, date: old)
        try write("Developer/active/node_modules/pkg/index.js", megabytes: 1, date: Date())
        // Freshly-created intermediate dirs carry today's mtime; age them like
        // a real stale project (the age gate looks at the newest entry).
        try setDateRecursively(old, under: "Developer/myapp")

        let policy = SafetyPolicy(home: fixtureHome)
        let items = ProjectArtifactScanner.scan(
            devFolders: [fixtureHome.appending(path: "Developer")],
            minAgeDays: 30,
            policy: policy
        )
        let names = Set(items.map(\.displayName))
        XCTAssertTrue(names.contains("myapp/node_modules"), "stale node_modules must be found")
        XCTAssertFalse(names.contains("active/node_modules"), "recently used artifacts must be age-gated out")
        XCTAssertFalse(names.contains { $0.contains("src") }, "source folders must never be offered")
    }

    // MARK: - Cleaner whitelist re-check (defense in depth)

    func testCleanerHonorsWhitelistEvenIfCallerBypassedScanner() async {
        let policy = SafetyPolicy(home: fixtureHome)
        let recorder = RecordingRemover()
        let whitelisted = fixtureHome.appending(path: "Library/Caches/com.keep.me")
        let cleaner = Cleaner(
            policy: policy,
            whitelist: [whitelisted.path],
            trashRemover: recorder,
            permanentRemover: recorder
        )
        let item = ScanItem(
            ruleID: "user-caches", category: .systemJunk,
            url: whitelisted.appending(path: "blob.bin"),
            displayName: "blob.bin", detail: "", size: 1_000, fileCount: 1,
            newestModification: nil, tier: .safe, domain: .user
        )
        let session = await cleaner.clean(items: [item], source: .largeFiles, permanentDelete: false)
        XCTAssertTrue(recorder.removed.isEmpty, "whitelisted item must never be removed")
        XCTAssertEqual(session.items.count, 0)
        XCTAssertEqual(session.errors.count, 1)
        XCTAssertTrue(session.errors[0].contains("whitelisted"))
    }

    // MARK: - Orphan scanner vendor-prefix guard

    func testOrphanScannerSkipsHelperBundlesOfInstalledVendors() throws {
        try write("Library/Application Support/com.google.Keystone/agent.bin", megabytes: 1, date: Date())
        try write("Library/Application Support/com.deadvendor.oldapp/data.bin", megabytes: 1, date: Date())

        let items = OrphanScanner.scan(
            home: fixtureHome,
            installedBundleIDs: ["com.google.Chrome"],
            runningBundleIDs: []
        )
        let names = Set(items.map(\.displayName))
        XCTAssertFalse(names.contains("com.google.Keystone"),
                       "an installed vendor's helper/updater id must not be flagged as an orphan")
        XCTAssertTrue(names.contains("com.deadvendor.oldapp"),
                      "a genuinely orphaned bundle id should still be found")
    }

    // MARK: - Large file scanner pruning

    func testLargeFileScannerPrunesBuildCachesAndFindsRealFiles() async throws {
        try write("code/app/movie.mov", megabytes: 2, date: Date())
        try write("code/app/node_modules/pkg/blob.bin", megabytes: 2, date: Date())
        try write("code/app/.next/cache/turbopack/chunk.sst", megabytes: 2, date: Date())
        try write("code/app/target/release/binary.bin", megabytes: 2, date: Date())

        let policy = SafetyPolicy(home: fixtureHome)
        var found: [String] = []
        for await file in LargeFileScanner.scan(roots: [fixtureHome], minSize: 1_000_000, policy: policy) {
            found.append(file.name)
        }
        XCTAssertTrue(found.contains("movie.mov"), "real large files must be found")
        XCTAssertFalse(found.contains("blob.bin"), "node_modules must be pruned")
        XCTAssertFalse(found.contains("chunk.sst"), ".next build cache must be pruned")
        XCTAssertFalse(found.contains("binary.bin"), "target build output must be pruned")
        // No duplicate ids in the stream.
        XCTAssertEqual(found.count, Set(found).count)
    }
}

/// Records removals instead of performing them.
final class RecordingRemover: FileRemover, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var removed: [URL] = []

    func remove(_ url: URL) throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        removed.append(url)
        return nil
    }
}
