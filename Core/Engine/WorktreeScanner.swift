import Foundation

public enum WorktreeState: String, Sendable, Equatable {
    /// git resolves it and there are no uncommitted changes → safe to reclaim.
    case clean
    /// git resolves it and there ARE uncommitted changes → protect (locked).
    case dirty
    /// git can't resolve it (its parent repo lost the registration): a dead
    /// worktree holding orphaned files → reclaimable, but clearly labeled.
    case orphaned
    /// git failed for some other reason → can't verify, so locked to be safe.
    case unverified

    /// Only clean and orphaned worktrees may be selected for removal.
    public var isSelectable: Bool { self == .clean || self == .orphaned }
    public var isLocked: Bool { !isSelectable }
}

public struct AgentWorktree: Sendable, Identifiable, Equatable {
    public let id: String
    public let url: URL
    public let name: String
    public let branch: String?
    public let state: WorktreeState
    public let dirtyCount: Int
    public let size: Int64
    public let lastModified: Date?

    public init(url: URL, name: String, branch: String?, state: WorktreeState, dirtyCount: Int, size: Int64, lastModified: Date?) {
        self.id = url.path
        self.url = url
        self.name = name
        self.branch = branch
        self.state = state
        self.dirtyCount = dirtyCount
        self.size = size
        self.lastModified = lastModified
    }

    /// True only for worktrees holding known uncommitted work.
    public var isDirty: Bool { state == .dirty }

    public var scanItem: ScanItem {
        let note: String
        switch state {
        case .clean: note = branch.map { "branch \($0)" } ?? "clean worktree"
        case .orphaned: note = "orphaned worktree (git metadata missing)"
        case .dirty: note = "uncommitted changes"
        case .unverified: note = "could not verify"
        }
        return ScanItem(
            ruleID: "agent-worktree",
            category: .projectArtifacts,
            url: url,
            displayName: name,
            detail: note,
            size: size,
            fileCount: 1,
            newestModification: lastModified,
            tier: .explicitOnly,
            domain: .user
        )
    }
}

/// Finds AI-agent git worktrees (Claude Code creates them under
/// `<project>/.claude/worktrees/<name>`) and flags which ones hold uncommitted
/// work. Read-only: it runs `git status`, never deletes.
public enum WorktreeScanner {
    static let containerName = "worktrees"
    static let pruneNames: Set<String> = [
        "node_modules", "target", "build", "dist", "Pods", ".next", ".nuxt",
        ".venv", "venv", "DerivedData", ".gradle", "vendor",
    ]

    public static func scan(devFolders: [URL], policy: SafetyPolicy, maxDepth: Int = 6) async -> [AgentWorktree] {
        let claude = findWorktreeDirs(devFolders: devFolders, policy: policy, maxDepth: maxDepth)
        let codex = findCodexWorktrees(home: policy.home, policy: policy)
        let jobs: [(URL, String?)] = claude.map { ($0, nil) } + codex.map { ($0, "Codex › \($0.lastPathComponent)") }
        var results: [AgentWorktree] = []
        // A handful at a time: each one sizes a full checkout and runs git
        // twice, and there can be dozens.
        await withTaskGroup(of: AgentWorktree?.self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<min(8, jobs.count) {
                guard let (url, name) = pending.next() else { break }
                group.addTask { await describe(url, name: name) }
            }
            for await wt in group {
                if let wt { results.append(wt) }
                if let (url, name) = pending.next() {
                    group.addTask { await describe(url, name: name) }
                }
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    static func findWorktreeDirs(devFolders: [URL], policy: SafetyPolicy, maxDepth: Int) -> [URL] {
        let fm = FileManager()
        var found: [URL] = []
        var seenContainers = Set<String>()

        for root in devFolders {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return found }
                if enumerator.level > maxDepth { enumerator.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = url.lastPathComponent
                if pruneNames.contains(name) { enumerator.skipDescendants(); continue }

                if name == containerName,
                   url.deletingLastPathComponent().lastPathComponent == ".claude" {
                    guard seenContainers.insert(url.standardizedFileURL.path).inserted else {
                        enumerator.skipDescendants(); continue
                    }
                    let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                    for kid in kids {
                        guard (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                              !policy.isProtected(kid) else { continue }
                        found.append(kid)
                    }
                    enumerator.skipDescendants()   // never walk into the checkouts
                }
            }
        }
        return found
    }

    /// The Codex app keeps every worktree under one fixed container outside
    /// any project, so the dev-folder walk never reaches it. A checkout is a
    /// folder with a `.git` entry, directly in the container or one level
    /// down (a per-task folder holding the repo).
    static func findCodexWorktrees(home: URL, policy: SafetyPolicy) -> [URL] {
        let fm = FileManager()
        let container = home.appending(path: ".codex/worktrees")
        // A symlinked container could point anywhere; don't follow it.
        guard (try? container.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return [] }
        func subdirectories(_ dir: URL) -> [URL] {
            let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
            return kids.filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true && !policy.isProtected($0)
            }
        }
        var found: [URL] = []
        for child in subdirectories(container) {
            if fm.fileExists(atPath: child.appending(path: ".git").path) {
                found.append(child)
            } else {
                found += subdirectories(child).filter { fm.fileExists(atPath: $0.appending(path: ".git").path) }
            }
        }
        return found
    }

    static func describe(_ url: URL, name: String? = nil) async -> AgentWorktree? {
        let stats = DirectorySizer.stats(of: url)
        guard stats.size > 0 else { return nil }

        let status = await ProcessRunner.run("/usr/bin/git", ["-C", url.path, "status", "--porcelain"])
        let dirtyLines = status.stdout.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let state: WorktreeState
        if status.status == 0 {
            state = dirtyLines.isEmpty ? .clean : .dirty
        } else {
            // A worktree whose parent repo no longer registers it (renamed or
            // deleted) is a dead directory of orphaned files — reclaimable.
            // Any other git failure means we can't verify → stay locked.
            let err = (status.stderr + status.stdout).lowercased()
            state = (err.contains("not a git repository") || err.contains("no such file"))
                ? .orphaned : .unverified
        }

        let branchResult = await ProcessRunner.run("/usr/bin/git", ["-C", url.path, "rev-parse", "--abbrev-ref", "HEAD"])
        let branch = branchResult.status == 0 && !branchResult.stdout.isEmpty ? branchResult.stdout : nil

        let project = url
            .deletingLastPathComponent()   // .../worktrees
            .deletingLastPathComponent()   // .../.claude
            .deletingLastPathComponent()   // project root
            .lastPathComponent

        return AgentWorktree(
            url: url,
            name: name ?? "\(project)/\(url.lastPathComponent)",
            branch: branch,
            state: state,
            dirtyCount: dirtyLines.count,
            size: stats.size,
            lastModified: stats.newestModification
        )
    }
}
