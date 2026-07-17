import XCTest
@testable import SweepCore

final class WorktreeScannerTests: XCTestCase {
    var devRoot: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        try XCTSkipUnless(fm.isExecutableFile(atPath: "/usr/bin/git"), "git not available")
        devRoot = fm.temporaryDirectory.appending(path: "sweep-wt-\(UUID().uuidString)")
        try fm.createDirectory(at: devRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: devRoot)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) async -> ProcessResult {
        await ProcessRunner.run("/usr/bin/git", ["-C", dir.path] + args)
    }

    /// Makes `<project>/.claude/worktrees/<name>` a git repo with one file,
    /// optionally leaving an uncommitted file to simulate a dirty worktree.
    private func makeWorktree(project: String, name: String, dirty: Bool) async throws {
        let wt = devRoot.appending(path: "\(project)/.claude/worktrees/\(name)")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try "committed".data(using: .utf8)!.write(to: wt.appending(path: "tracked.txt"))
        await git(["init", "-q"], in: wt)
        await git(["add", "."], in: wt)
        await git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], in: wt)
        if dirty {
            try "uncommitted work".data(using: .utf8)!.write(to: wt.appending(path: "wip.txt"))
        }
    }

    func testDirtyWorktreeIsFlaggedAndCleanIsSelectable() async throws {
        try await makeWorktree(project: "Flowclone", name: "clean-branch", dirty: false)
        try await makeWorktree(project: "Meeting_Recorder", name: "wip-branch", dirty: true)

        let policy = SafetyPolicy()
        let trees = await WorktreeScanner.scan(devFolders: [devRoot], policy: policy)
        XCTAssertEqual(trees.count, 2, "both worktrees should be found")

        let clean = try XCTUnwrap(trees.first { $0.name.hasSuffix("clean-branch") })
        let dirty = try XCTUnwrap(trees.first { $0.name.hasSuffix("wip-branch") })

        XCTAssertEqual(clean.state, .clean, "a committed worktree must be clean → selectable")
        XCTAssertTrue(clean.state.isSelectable)
        XCTAssertEqual(dirty.state, .dirty, "an uncommitted worktree must be flagged → locked")
        XCTAssertTrue(dirty.state.isLocked)
        XCTAssertGreaterThan(dirty.dirtyCount, 0)
        XCTAssertEqual(dirty.scanItem.tier, .explicitOnly)
        XCTAssertEqual(clean.scanItem.category, .projectArtifacts)
    }

    func testOrphanedWorktreeIsReclaimableNotLocked() async throws {
        // A worktree whose .git points at a repo that no longer registers it
        // (renamed/deleted parent) — git can't resolve it → orphaned, selectable.
        let wt = devRoot.appending(path: "Renamed/.claude/worktrees/stale-branch")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try "orphaned build output".data(using: .utf8)!.write(to: wt.appending(path: "artifact.bin"))
        try "gitdir: /nonexistent/repo/.git/worktrees/stale-branch"
            .data(using: .utf8)!.write(to: wt.appending(path: ".git"))

        let trees = await WorktreeScanner.scan(devFolders: [devRoot], policy: SafetyPolicy())
        let orphan = try XCTUnwrap(trees.first { $0.name.hasSuffix("stale-branch") })
        XCTAssertEqual(orphan.state, .orphaned)
        XCTAssertTrue(orphan.state.isSelectable, "orphaned worktrees are dead dirs → reclaimable")
    }

    func testNonWorktreeDirsAreIgnored() async throws {
        // A plain project folder with no .claude/worktrees yields nothing.
        try fm.createDirectory(at: devRoot.appending(path: "PlainProject/src"), withIntermediateDirectories: true)
        let trees = await WorktreeScanner.scan(devFolders: [devRoot], policy: SafetyPolicy())
        XCTAssertTrue(trees.isEmpty)
    }
}
