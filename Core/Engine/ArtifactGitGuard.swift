import Foundation

/// Decides whether a folder *named* like build output (`build`, `dist`,
/// `target`, `Pods`, …) really is regenerable, or is content someone checked in.
///
/// The name alone is not evidence. electron-builder keeps app icons and
/// entitlements in a committed `build/`; GitHub JavaScript actions commit
/// `dist/`; some teams commit `Pods/`. "Regenerates on next build" is false
/// for all of them, and deleting one throws away files the build cannot
/// recreate (and any local edits to them).
///
/// Read-only: runs `git ls-files`, never anything that writes.
public enum ArtifactGitGuard {

    public enum Verdict: Sendable, Equatable {
        /// No enclosing repository, so there is nothing for Git to vouch for.
        case notInRepository
        /// Inside a repository and Git tracks nothing under it.
        case untracked
        /// Git tracks at least one file under it — keep.
        case tracked
        /// The folder holds a repository of its own — keep.
        case nestedRepository
        /// Inside a repository, but Git could not answer — keep.
        case unverified(String)

        /// True only when deleting the folder loses nothing Git knows about.
        public var isRegenerable: Bool {
            self == .notInRepository || self == .untracked
        }

        public var reason: String {
            switch self {
            case .notInRepository, .untracked: "regenerable"
            case .tracked: "tracked by Git"
            case .nestedRepository: "contains its own Git repository"
            case .unverified(let why): "could not check Git (\(why))"
            }
        }
    }

    /// Runs `git` with the given arguments. Injectable for tests.
    public typealias GitRunner = @Sendable (_ arguments: [String]) -> ProcessResult

    /// Per-candidate limit. A huge index answers in well under a second; this
    /// only stops one wedged probe from stalling the whole scan.
    static let probeTimeout: TimeInterval = 10

    public static func verdict(for url: URL, git: GitRunner? = defaultGit) -> Verdict {
        let fm = FileManager()
        if holdsNestedRepository(url, fm: fm) { return .nestedRepository }
        guard enclosingRepository(of: url, fm: fm) != nil else { return .notInRepository }
        guard let git else { return .unverified("Git is not installed") }

        // Run *inside* the candidate: ls-files then lists only paths under the
        // working directory, with Git resolving the case itself — so `Build/`
        // on disk still matches a tracked `build/x` on a case-insensitive
        // volume, without pathspec quoting.
        let result = git(["--no-optional-locks", "-C", url.path, "ls-files", "-z"])
        switch result.status {
        case 0:
            return result.stdout.isEmpty ? .untracked : .tracked
        case ProcessRunner.timedOutStatus:
            return .unverified("timed out")
        default:
            // A `.git` exists above us yet Git refuses (dubious ownership, a
            // broken index, a worktree whose parent moved…). Not knowing is
            // not the same as "untracked".
            let message = result.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(result.status)"
            return .unverified(message)
        }
    }

    public static func verdictAsync(for url: URL, git: GitRunner? = defaultGit) async -> Verdict {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: verdict(for: url, git: git))
            }
        }
    }

    /// A `.git` at the top of the folder or one level down. Flutter's `build/`
    /// and vendored dependency folders can contain a checkout; deeper scans
    /// would mean walking every `node_modules`, which is the cost we avoid.
    static func holdsNestedRepository(_ url: URL, fm: FileManager) -> Bool {
        if fm.fileExists(atPath: url.appending(path: ".git").path) { return true }
        guard let children = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return false }
        return children.contains { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && fm.fileExists(atPath: child.appending(path: ".git").path)
        }
    }

    /// The nearest ancestor holding a `.git` entry (a directory, or the file a
    /// linked worktree uses).
    static func enclosingRepository(of url: URL, fm: FileManager) -> URL? {
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        while dir.path != "/" && !dir.path.isEmpty {
            if fm.fileExists(atPath: dir.appending(path: ".git").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The real Git, or nil when only Apple's `/usr/bin/git` install shim is
    /// present — invoking the shim pops a "install developer tools" dialog,
    /// once per candidate.
    public static let defaultGit: GitRunner? = {
        guard let git = resolvedGitPath() else { return nil }
        return { arguments in ProcessRunner.runBlocking(git, arguments, timeout: probeTimeout) }
    }()

    static func resolvedGitPath() -> String? {
        let fm = FileManager()
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            return path
        }
        let select = ProcessRunner.runBlocking("/usr/bin/xcode-select", ["-p"], timeout: 5)
        guard select.status == 0, !select.stdout.isEmpty,
              fm.isExecutableFile(atPath: select.stdout + "/usr/bin/git") else { return nil }
        return "/usr/bin/git"
    }
}
