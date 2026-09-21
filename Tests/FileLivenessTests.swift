import XCTest
@testable import SweepCore

/// A probe that answers from a script instead of shelling out to lsof.
private struct StubProbe: OpenHandleProbing {
    var open: [String: String] = [:]
    var failureReason: String?
    var completeView = true

    func openPaths(files: [URL], directories: [URL]) async -> ProbeOutcome {
        // Answer only about what was actually asked, so a test can prove the
        // SQLite siblings really were included in the probe. Directories match
        // recursively, mirroring `lsof +D`.
        let exact = Set(files.map { SafetyPolicy.canonical($0.path) })
        let trees = directories.map { SafetyPolicy.canonical($0.path) + "/" }
        var matched: [String: String] = [:]
        for (path, command) in open {
            let canonical = SafetyPolicy.canonical(path)
            let inTree = trees.contains { canonical.hasPrefix($0) }
            guard exact.contains(canonical) || inTree else { continue }
            matched[canonical] = command
        }
        return ProbeOutcome(openPaths: matched, failureReason: failureReason)
    }

    func processViewIsComplete() async -> Bool { completeView }
}

final class FileLivenessTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-live-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    @discardableResult
    private func write(_ relative: String) throws -> URL {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    // MARK: - Verdicts

    func testOpenFileIsReportedInUse() async throws {
        let file = try write("Downloads/movie.crdownload")
        let liveness = FileLiveness(probe: StubProbe(open: [file.path: "Safari"]))
        let verdict = await liveness.verdicts(for: [file])[file.path]
        XCTAssertEqual(verdict, .inUse(command: "Safari"))
        XCTAssertFalse(verdict?.isConclusivelyIdle ?? true)
    }

    func testIdleFileIsConclusivelyIdleWhenTheProcessViewIsComplete() async throws {
        let file = try write("Downloads/old.part")
        let liveness = FileLiveness(probe: StubProbe())
        let verdict = await liveness.verdicts(for: [file])[file.path]
        XCTAssertEqual(verdict, .idle(completeProcessView: true))
    }

    /// An unprivileged lsof cannot see other users' processes, so "no handles"
    /// is a weaker statement. The verdict records that rather than hiding it.
    func testIncompleteProcessViewIsRecordedOnTheVerdict() async throws {
        let file = try write("Downloads/old.part")
        let liveness = FileLiveness(probe: StubProbe(completeView: false))
        let verdict = await liveness.verdicts(for: [file])[file.path]
        XCTAssertEqual(verdict, .idle(completeProcessView: false))
    }

    func testProbeFailureIsUnknownNotIdle() async throws {
        let file = try write("Downloads/old.part")
        let liveness = FileLiveness(probe: StubProbe(failureReason: "lsof did not finish in time"))
        let verdict = await liveness.verdicts(for: [file])[file.path]
        XCTAssertEqual(verdict, .unknown(reason: "lsof did not finish in time"))
        XCTAssertFalse(verdict?.isConclusivelyIdle ?? true,
                       "a timeout must never be allowed to authorize a deletion")
    }

    func testHandleInsideADirectoryMakesTheDirectoryInUse() async throws {
        let directory = home.appending(path: "Library/Caches/Chromium")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let inner = try write("Library/Caches/Chromium/Cache/data_0")
        let liveness = FileLiveness(probe: StubProbe(open: [inner.path: "Chromium"]))
        let verdict = await liveness.verdicts(for: [directory])[directory.path]
        XCTAssertEqual(verdict, .inUse(command: "Chromium"))
    }

    /// A WAL `-shm` exists only while a connection is open, but a stale one
    /// survives an unclean exit — so the sibling files must be probed, not
    /// merely observed to exist.
    func testSQLiteSiblingHandleMarksTheDatabaseInUse() async throws {
        let db = try write("Library/App/state.vscdb")
        let shm = try write("Library/App/state.vscdb-shm")
        try write("Library/App/state.vscdb-wal")

        let liveness = FileLiveness(probe: StubProbe(open: [shm.path: "Cursor"]))
        let verdict = await liveness.verdicts(for: [db])[db.path]
        XCTAssertEqual(verdict, .inUse(command: "Cursor"),
                       "a handle on the -shm means the database is live")
    }

    func testStaleSQLiteSiblingsWithNoHandlesAreIdle() async throws {
        let db = try write("Library/App/state.vscdb")
        try write("Library/App/state.vscdb-shm")
        let liveness = FileLiveness(probe: StubProbe())
        let verdict = await liveness.verdicts(for: [db])[db.path]
        XCTAssertEqual(verdict, .idle(completeProcessView: true),
                       "an orphaned -shm must not block deletion forever")
    }

    func testSiblingsAreDerivedInBothDirections() throws {
        let base = URL(fileURLWithPath: "/tmp/x.db")
        XCTAssertEqual(Set(FileLiveness.sqliteSiblings(of: base).map(\.lastPathComponent)),
                       ["x.db-wal", "x.db-shm"])
        let wal = URL(fileURLWithPath: "/tmp/x.db-wal")
        XCTAssertEqual(Set(FileLiveness.sqliteSiblings(of: wal).map(\.lastPathComponent)),
                       ["x.db", "x.db-shm"])
    }

    func testMissingPathsGetNoVerdictRatherThanAFalseIdle() async throws {
        let missing = home.appending(path: "Downloads/gone.part")
        let liveness = FileLiveness(probe: StubProbe())
        let verdicts = await liveness.verdicts(for: [missing])
        XCTAssertNil(verdicts[missing.path])
    }

    // MARK: - The real probe

    /// Everything above uses a stub, so this is the one test that proves the
    /// actual lsof invocation and parsing work. The test process holds the
    /// handle itself, so there is no child process to race.
    func testRealLsofProbeSeesAHandleThisProcessHolds() async throws {
        try XCTSkipUnless(fm.isExecutableFile(atPath: LsofProbe.executable), "lsof unavailable")
        let held = try write("held.bin")
        let idle = try write("idle.bin")

        let handle = try FileHandle(forReadingFrom: held)
        defer { try? handle.close() }

        let liveness = FileLiveness(probe: LsofProbe(timeout: 20))
        let verdicts = await liveness.verdicts(for: [held, idle])

        XCTAssertTrue(verdicts[held.path]?.isInUse ?? false,
                      "lsof should see the handle this process holds; got \(String(describing: verdicts[held.path]))")
        XCTAssertFalse(verdicts[idle.path]?.isInUse ?? true,
                       "an unopened file must not be reported in use")
    }

    /// Directories are probed recursively (`+D`), which is what lets a cache
    /// folder be refused because of one file open inside it.
    func testRealLsofProbeSeesAHandleInsideADirectory() async throws {
        try XCTSkipUnless(fm.isExecutableFile(atPath: LsofProbe.executable), "lsof unavailable")
        let inner = try write("tree/deeper/held.bin")
        let directory = home.appending(path: "tree")

        let handle = try FileHandle(forReadingFrom: inner)
        defer { try? handle.close() }

        let liveness = FileLiveness(probe: LsofProbe(timeout: 20))
        let verdicts = await liveness.verdicts(for: [directory])
        XCTAssertTrue(verdicts[directory.path]?.isInUse ?? false,
                      "got \(String(describing: verdicts[directory.path]))")
    }

    // MARK: - lsof output parsing

    func testParsesFieldOutputAndAttributesTheCommand() {
        let output = "p58273\ncSafari\nf9\nn/Users/me/Downloads/movie.crdownload\n"
        XCTAssertEqual(LsofProbe.parse(output),
                       [SafetyPolicy.canonical("/Users/me/Downloads/movie.crdownload"): "Safari"])
    }

    func testParseIgnoresNonAbsoluteAndNonPathRecords() {
        let output = "p1\nclaunchd\nncwd\nn/private/var/db\n"
        XCTAssertEqual(LsofProbe.parse(output), [SafetyPolicy.canonical("/private/var/db"): "launchd"])
    }

    // MARK: - Cleaner integration

    private func item(_ url: URL, ruleID: String = "user-caches", identity: FileIdentity? = nil) -> ScanItem {
        ScanItem(
            ruleID: ruleID, category: .systemJunk, url: url, displayName: url.lastPathComponent,
            detail: "", size: 1, fileCount: 1, newestModification: nil,
            tier: .safe, domain: .user, identity: identity
        )
    }

    func testCleanerRefusesToDeleteSomethingInUse() async throws {
        let file = try write("Library/Caches/app/live.bin")
        let recorder = RecordingRemover()
        let cleaner = Cleaner(
            policy: SafetyPolicy(home: home), trashRemover: recorder,
            liveness: FileLiveness(probe: StubProbe(open: [file.path: "SomeApp"]))
        )
        let session = await cleaner.clean(items: [item(file)], source: .smartScan, permanentDelete: false)
        XCTAssertTrue(recorder.removed.isEmpty, "nothing may be deleted while a process holds it")
        XCTAssertEqual(session.items.count, 0)
        XCTAssertTrue(session.errors.contains { $0.contains("still in use") && $0.contains("SomeApp") },
                      "errors were: \(session.errors)")
    }

    /// For an in-flight download an inconclusive probe is not good enough.
    func testCleanerKeepsAPartialDownloadWhenLivenessIsUnknown() async throws {
        let file = try write("Downloads/movie.crdownload")
        let recorder = RecordingRemover()
        let cleaner = Cleaner(
            policy: SafetyPolicy(home: home), trashRemover: recorder,
            liveness: FileLiveness(probe: StubProbe(failureReason: "lsof did not finish in time"))
        )
        let session = await cleaner.clean(
            items: [item(file, ruleID: "incomplete-downloads")], source: .smartScan, permanentDelete: false
        )
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertTrue(session.errors.contains { $0.contains("could not confirm it is idle") },
                      "errors were: \(session.errors)")
    }

    /// An ordinary cache still goes when the probe cannot answer — refusing
    /// everything on an inconclusive probe would make the tool useless.
    func testCleanerStillClearsAnOrdinaryCacheWhenLivenessIsUnknown() async throws {
        let file = try write("Library/Caches/app/blob.bin")
        let recorder = RecordingRemover()
        let cleaner = Cleaner(
            policy: SafetyPolicy(home: home), trashRemover: recorder,
            liveness: FileLiveness(probe: StubProbe(failureReason: "lsof is not available"))
        )
        let session = await cleaner.clean(items: [item(file)], source: .smartScan, permanentDelete: false)
        XCTAssertEqual(recorder.removed.map(\.lastPathComponent), ["blob.bin"])
        XCTAssertTrue(session.errors.isEmpty, "errors were: \(session.errors)")
    }

    // MARK: - Rename-and-recreate (TOCTOU)

    func testCleanerRefusesAPathThatWasRecreatedSinceTheScan() async throws {
        let file = try write("Library/Caches/app/blob.bin")
        let scanned = try XCTUnwrap(FileIdentity.current(of: file))

        // Same path, different object — as if the folder were rotated between
        // the scan and the click.
        try fm.removeItem(at: file)
        try Data("different".utf8).write(to: file)
        let now = try XCTUnwrap(FileIdentity.current(of: file))
        try XCTSkipIf(now == scanned, "the filesystem reused the inode; nothing to assert")

        let recorder = RecordingRemover()
        let cleaner = Cleaner(
            policy: SafetyPolicy(home: home), trashRemover: recorder,
            liveness: FileLiveness(probe: StubProbe())
        )
        let session = await cleaner.clean(
            items: [item(file, identity: scanned)], source: .smartScan, permanentDelete: false
        )
        XCTAssertTrue(recorder.removed.isEmpty, "the reviewed object is gone; do not delete its replacement")
        XCTAssertTrue(session.errors.contains { $0.contains("changed since the scan") },
                      "errors were: \(session.errors)")
    }

    func testCleanerDeletesWhenTheIdentityStillMatches() async throws {
        let file = try write("Library/Caches/app/blob.bin")
        let scanned = try XCTUnwrap(FileIdentity.current(of: file))
        let recorder = RecordingRemover()
        let cleaner = Cleaner(
            policy: SafetyPolicy(home: home), trashRemover: recorder,
            liveness: FileLiveness(probe: StubProbe())
        )
        let session = await cleaner.clean(
            items: [item(file, identity: scanned)], source: .smartScan, permanentDelete: false
        )
        XCTAssertEqual(recorder.removed.map(\.lastPathComponent), ["blob.bin"])
        XCTAssertTrue(session.errors.isEmpty, "errors were: \(session.errors)")
    }

    func testItemsWithoutARecordedIdentityStillClean() async throws {
        let file = try write("Library/Caches/app/blob.bin")
        let recorder = RecordingRemover()
        let cleaner = Cleaner(
            policy: SafetyPolicy(home: home), trashRemover: recorder,
            liveness: FileLiveness(probe: StubProbe())
        )
        let session = await cleaner.clean(items: [item(file)], source: .smartScan, permanentDelete: false)
        XCTAssertEqual(recorder.removed.count, 1)
        XCTAssertTrue(session.errors.isEmpty)
    }

    // MARK: - Rule hardening

    func testPartialDownloadRulesAreNeverSafeTier() {
        let rules = RuleCatalog.rules(home: home, includeSystemDomain: false)
            .filter { $0.id == "incomplete-downloads" || $0.id == "incomplete-brew-downloads" }
        XCTAssertEqual(rules.count, 2, "both partial-download rules should exist")
        for rule in rules {
            XCTAssertEqual(rule.tier, .review,
                           "\(rule.id) must not be pre-selected or auto-trimmed — a transfer may be resuming")
        }
    }

    /// Every rule that targets a partially-written thing must go through the
    /// conclusive-idle gate, whatever its tier.
    func testEveryPartialInstallRuleRequiresAConclusiveIdleVerdict() {
        let rules = RuleCatalog.rules(home: home, includeSystemDomain: false)
            .filter { $0.id.contains("incomplete") }
        XCTAssertFalse(rules.isEmpty)
        for rule in rules {
            XCTAssertTrue(Cleaner.rulesRequiringConclusiveIdle.contains(rule.id),
                          "\(rule.id) targets partial data and must require a conclusive idle verdict")
        }
    }

    func testRequiresConclusiveIdleCoversPartialsAndDatabases() {
        let base = URL(fileURLWithPath: "/tmp")
        XCTAssertTrue(Cleaner.requiresConclusiveIdle(item(base.appending(path: "a.crdownload"))))
        XCTAssertTrue(Cleaner.requiresConclusiveIdle(item(base.appending(path: "x.db-shm"))))
        XCTAssertTrue(Cleaner.requiresConclusiveIdle(item(base.appending(path: "state.vscdb"))))
        XCTAssertTrue(Cleaner.requiresConclusiveIdle(
            item(base.appending(path: "whatever"), ruleID: "incomplete-brew-downloads")))
        XCTAssertFalse(Cleaner.requiresConclusiveIdle(item(base.appending(path: "Cache"))))
    }
}
