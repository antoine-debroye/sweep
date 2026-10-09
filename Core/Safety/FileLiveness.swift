import Foundation

/// What a liveness probe concluded about a path.
///
/// Three states, not two, and the distinction is load-bearing: "nothing holds
/// this open" and "I could not find out" must never collapse into the same
/// answer, because only the first one may authorize a deletion.
public enum LivenessVerdict: Sendable, Equatable {
    /// A process holds this path (or something inside it) open.
    case inUse(command: String?)
    /// Nothing holds it open. `completeProcessView` records whether the probe
    /// could see other users' processes; when false, a *root* daemon holding
    /// the file would not have been noticed.
    case idle(completeProcessView: Bool)
    /// The probe could not answer — missing tool, timeout, unreadable output.
    case unknown(reason: String)

    public var isInUse: Bool {
        if case .inUse = self { return true }
        return false
    }

    public var isConclusivelyIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var describedBlocker: String? {
        if case .inUse(let command) = self { return command }
        return nil
    }
}

/// Which paths are currently held open. Injected so tests never shell out.
public protocol OpenHandleProbing: Sendable {
    /// Paths held open, mapped to the command holding them. `files` are matched
    /// exactly; `directories` are matched recursively (a handle on anything
    /// inside counts).
    func openPaths(files: [URL], directories: [URL]) async -> ProbeOutcome

    /// Whether the probe can observe processes belonging to other users.
    func processViewIsComplete() async -> Bool
}

public struct ProbeOutcome: Sendable {
    /// Canonical open path -> command name.
    public var openPaths: [String: String]
    /// Set when the probe could not be trusted to have answered fully.
    public var failureReason: String?

    public init(openPaths: [String: String] = [:], failureReason: String? = nil) {
        self.openPaths = openPaths
        self.failureReason = failureReason
    }
}

/// `lsof`-backed probe.
public struct LsofProbe: OpenHandleProbing {
    public static let executable = "/usr/sbin/lsof"
    public let timeout: TimeInterval
    /// lsof takes a while on huge trees; probe in chunks so one enormous
    /// directory cannot blow the whole budget.
    public let batchSize: Int

    public init(timeout: TimeInterval = 5, batchSize: Int = 24) {
        self.timeout = timeout
        self.batchSize = batchSize
    }

    /// An unprivileged `lsof` on macOS silently omits other users' processes
    /// and still exits 0, so "no records" is ambiguous unless we first confirm
    /// we can see a process we know exists and is root-owned: launchd, pid 1.
    public func processViewIsComplete() async -> Bool {
        guard FileManager().isExecutableFile(atPath: Self.executable) else { return false }
        let result = await ProcessRunner.run(Self.executable, ["-F", "pu", "-p", "1"], timeout: timeout)
        guard result.status == 0 else { return false }
        // Field output for a root process carries a "u0" (uid 0) record.
        return result.stdout.split(separator: "\n").contains { $0 == "u0" }
    }

    public func openPaths(files: [URL], directories: [URL]) async -> ProbeOutcome {
        guard FileManager().isExecutableFile(atPath: Self.executable) else {
            return ProbeOutcome(failureReason: "lsof is not available")
        }
        var open: [String: String] = [:]
        var failure: String?

        for chunk in chunked(directories) {
            var arguments = ["-F", "pcn"]
            for directory in chunk { arguments += ["+D", directory.path] }
            let outcome = await invoke(arguments)
            open.merge(outcome.openPaths) { current, _ in current }
            if let reason = outcome.failureReason { failure = reason }
        }
        for chunk in chunked(files) {
            let arguments = ["-F", "pcn", "--"] + chunk.map(\.path)
            let outcome = await invoke(arguments)
            open.merge(outcome.openPaths) { current, _ in current }
            if let reason = outcome.failureReason { failure = reason }
        }
        return ProbeOutcome(openPaths: open, failureReason: failure)
    }

    private func chunked(_ urls: [URL]) -> [[URL]] {
        guard !urls.isEmpty else { return [] }
        return stride(from: 0, to: urls.count, by: batchSize).map {
            Array(urls[$0 ..< min($0 + batchSize, urls.count)])
        }
    }

    private func invoke(_ arguments: [String]) async -> ProbeOutcome {
        let result = await ProcessRunner.run(Self.executable, arguments, timeout: timeout)
        // 124 = our own timeout; >=128 = killed by a signal. Neither is an
        // answer, and treating them as "nothing is open" is how a clean tool
        // deletes a file out from under a live process.
        if result.status == ProcessRunner.timedOutStatus || result.status >= 128 {
            return ProbeOutcome(failureReason: "lsof did not finish in time")
        }
        // lsof exits 1 both for "no match" and for real errors, so the
        // distinction has to come from the output: field records mean matches,
        // anything on stderr means we cannot trust an empty result.
        if result.status != 0, result.stdout.isEmpty, !result.stderr.isEmpty {
            return ProbeOutcome(failureReason: "lsof reported: \(result.stderr)")
        }
        return ProbeOutcome(openPaths: Self.parse(result.stdout))
    }

    /// Parses `-F pcn` output: one field per line, `p<pid>` / `c<command>` /
    /// `n<path>`, with the process fields preceding the files they own.
    static func parse(_ output: String) -> [String: String] {
        var open: [String: String] = [:]
        var command = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "c": command = value
            case "n" where value.hasPrefix("/"):
                open[SafetyPolicy.canonical(value)] = command
            default: break
            }
        }
        return open
    }
}

/// Decides whether paths are safe to delete right now.
///
/// Sweep's own history is the argument for this existing: a Figma leftover was
/// found with `figma_agent` still executing from inside it, and Homebrew and
/// browser partial downloads are routinely deleted by cleaners while the
/// transfer that owns them is still running.
public struct FileLiveness: Sendable {
    public let probe: OpenHandleProbing

    public init(probe: OpenHandleProbing = LsofProbe()) {
        self.probe = probe
    }

    /// A verdict per requested URL. Directories are probed recursively.
    public func verdicts(for urls: [URL]) async -> [String: LivenessVerdict] {
        guard !urls.isEmpty else { return [:] }
        let fm = FileManager()
        var files: [URL] = []
        var directories: [URL] = []
        var present: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            present.append(url)
            if isDirectory.boolValue { directories.append(url) } else { files.append(url) }
        }
        // A SQLite database is three files. The -shm only exists while a
        // connection is open, but a stale one survives an unclean exit, so its
        // presence proves nothing on its own — the handle check does. Probing
        // the siblings is what stops a live database being judged by its main
        // file alone.
        let probedFiles = files + files.flatMap(Self.sqliteSiblings).filter {
            fm.fileExists(atPath: $0.path)
        }

        let complete = await probe.processViewIsComplete()
        let outcome = await probe.openPaths(files: probedFiles, directories: directories)

        // A path that no longer exists gets no verdict at all: reporting it as
        // idle would read as "checked and safe" for something we never saw.
        var verdicts: [String: LivenessVerdict] = [:]
        for url in present {
            let canonical = SafetyPolicy.canonical(url.path)
            if let command = blocker(for: url, canonical: canonical, in: outcome.openPaths) {
                verdicts[url.path] = .inUse(command: command)
            } else if let reason = outcome.failureReason {
                verdicts[url.path] = .unknown(reason: reason)
            } else {
                verdicts[url.path] = .idle(completeProcessView: complete)
            }
        }
        return verdicts
    }

    /// The command holding this URL, itself or anything beneath it, or one of
    /// its SQLite siblings.
    private func blocker(for url: URL, canonical: String, in open: [String: String]) -> String? {
        if let command = open[canonical] { return command }
        for sibling in Self.sqliteSiblings(of: url) {
            if let command = open[SafetyPolicy.canonical(sibling.path)] { return command }
        }
        let prefix = canonical + "/"
        for (path, command) in open where path.hasPrefix(prefix) { return command }
        return nil
    }

    static func sqliteSiblings(of url: URL) -> [URL] {
        let base = url.path
        // Cover both directions: given "x.db" also probe the journals, and
        // given "x.db-wal" also probe the database itself.
        for suffix in ["-wal", "-shm"] where base.hasSuffix(suffix) {
            let root = URL(fileURLWithPath: String(base.dropLast(suffix.count)))
            return [root, root.appendingPathExtension2("-wal"), root.appendingPathExtension2("-shm")]
                .filter { $0.path != base }
        }
        return [url.appendingPathExtension2("-wal"), url.appendingPathExtension2("-shm")]
    }
}

extension URL {
    /// Appends a raw suffix to the last path component. `appendingPathExtension`
    /// would insert a dot, which is wrong for SQLite's "-wal"/"-shm".
    func appendingPathExtension2(_ suffix: String) -> URL {
        URL(fileURLWithPath: path + suffix)
    }
}
