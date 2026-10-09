import XCTest
@testable import SweepCore

/// Folders named like build output are only regenerable when Git has nothing
/// invested in them. These run against a real `git` in a temp repository.
final class ArtifactGitGuardTests: XCTestCase {
    var root: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        try XCTSkipIf(ArtifactGitGuard.defaultGit == nil, "Git is not installed")
        root = fm.temporaryDirectory.appending(path: "sweep-gitguard-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    @discardableResult
    private func write(_ relative: String, ageDays: Int = 0) throws -> URL {
        let url = root.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4096).write(to: url)
        if ageDays > 0 {
            let date = Date().addingTimeInterval(-Double(ageDays) * 86_400)
            var item = url
            while item.path.count > root.path.count {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
                item = item.deletingLastPathComponent()
            }
        }
        return url
    }

    private func git(_ args: String..., in dir: URL) {
        let result = ProcessRunner.runBlocking("/usr/bin/git", ["-C", dir.path] + args, timeout: 20)
        XCTAssertEqual(result.status, 0, "git \(args.joined(separator: " ")): \(result.stderr)")
    }

    /// repo/ with a checked-in build/ (electron-builder style), an untracked
    /// node_modules/ and an ignored dist/.
    private func makeRepo() throws -> URL {
        let repo = root.appending(path: "app")
        try write("app/package.json")
        try write("app/build/icon.icns")
        try write("app/build/entitlements.plist")
        try write("app/node_modules/left-pad/index.js")
        try write("app/dist/main.js")
        try "node_modules/\ndist/\n".write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        git("init", "-q", in: repo)
        git("add", "package.json", ".gitignore", "build", in: repo)
        return repo
    }

    func testTrackedBuildFolderIsKeptAndUntrackedOnesAreNot() throws {
        let repo = try makeRepo()
        XCTAssertEqual(ArtifactGitGuard.verdict(for: repo.appending(path: "build")), .tracked)
        XCTAssertEqual(ArtifactGitGuard.verdict(for: repo.appending(path: "node_modules")), .untracked)
        XCTAssertEqual(ArtifactGitGuard.verdict(for: repo.appending(path: "dist")), .untracked)
    }

    /// APFS is case-insensitive: the folder may be reached as `Build` while Git
    /// recorded `build/…`. Running inside the folder lets Git resolve it.
    func testTrackingIsMatchedRegardlessOfCase() throws {
        let repo = try makeRepo()
        XCTAssertEqual(ArtifactGitGuard.verdict(for: repo.appending(path: "BUILD")), .tracked)
    }

    func testFolderOutsideAnyRepositoryNeedsNoGit() throws {
        try write("scratch/target/debug/app")
        let neverCalled: ArtifactGitGuard.GitRunner = { _ in
            XCTFail("git must not run outside a repository")
            return ProcessResult(status: 1, stdout: "", stderr: "")
        }
        XCTAssertEqual(ArtifactGitGuard.verdict(for: root.appending(path: "scratch/target"), git: neverCalled),
                       .notInRepository)
    }

    func testNestedRepositoryInsideBuildOutputIsKept() throws {
        try write("plain/build/flutter_assets/a.bin")
        try write("plain/build/vendored/README")
        git("init", "-q", in: root.appending(path: "plain/build/vendored"))
        XCTAssertEqual(ArtifactGitGuard.verdict(for: root.appending(path: "plain/build")), .nestedRepository)
    }

    func testInconclusiveGitKeepsTheFolder() throws {
        let repo = try makeRepo()
        let refusing: ArtifactGitGuard.GitRunner = { _ in
            ProcessResult(status: 128, stdout: "", stderr: "fatal: detected dubious ownership in repository")
        }
        let timingOut: ArtifactGitGuard.GitRunner = { _ in
            ProcessResult(status: ProcessRunner.timedOutStatus, stdout: "", stderr: "")
        }
        let target = repo.appending(path: "node_modules")
        XCTAssertFalse(ArtifactGitGuard.verdict(for: target, git: refusing).isRegenerable)
        XCTAssertEqual(ArtifactGitGuard.verdict(for: target, git: timingOut), .unverified("timed out"))
        XCTAssertFalse(ArtifactGitGuard.verdict(for: target, git: nil).isRegenerable,
                       "no Git inside a repository means we cannot vouch for it")
    }

    func testProjectScanOffersOnlyRegenerableArtifacts() throws {
        _ = try makeRepo()
        let policy = SafetyPolicy(home: root)
        let found = ProjectArtifactScanner.scan(devFolders: [root], minAgeDays: 0, policy: policy)
            .map { $0.url.lastPathComponent }
        XCTAssertTrue(found.contains("node_modules"))
        XCTAssertTrue(found.contains("dist"))
        XCTAssertFalse(found.contains("build"), "a checked-in build/ is not build output")
    }

    /// The scan's verdict can be minutes old by the time the user clicks.
    func testCleanerRechecksGitBeforeRemovingAnArtifact() async throws {
        let repo = try makeRepo()
        let build = repo.appending(path: "build")
        let item = ScanItem(
            ruleID: ProjectArtifactScanner.ruleID, category: .projectArtifacts, url: build,
            displayName: "app/build", detail: "", size: 8192, fileCount: 2,
            newestModification: nil, tier: .review, domain: .user
        )
        let recorder = RecordingRemover()
        let cleaner = Cleaner(policy: SafetyPolicy(home: root), trashRemover: recorder,
                              permanentRemover: recorder, liveness: FileLiveness(probe: IdleProbe()))
        let session = await cleaner.clean(items: [item], source: .devCleaner, permanentDelete: false)
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertTrue(session.errors.contains { $0.contains("tracked by Git") }, "\(session.errors)")
    }
}

/// Reports every path idle with a complete process view.
private struct IdleProbe: OpenHandleProbing {
    func openPaths(files: [URL], directories: [URL]) async -> ProbeOutcome {
        ProbeOutcome(openPaths: [:])
    }
    func processViewIsComplete() async -> Bool { true }
}
