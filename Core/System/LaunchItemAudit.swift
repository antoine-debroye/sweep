import Foundation

/// A launch item or privileged helper whose owner appears to be gone.
public struct LaunchItemFinding: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case launchAgent, launchDaemon, privilegedHelper
        /// A live process executing out of an uninstalled app's leftover data.
        /// Produced by `OrphanScanner`, which is the only place that knows the
        /// folder's owner is actually gone — "a process running under
        /// Application Support" on its own is completely normal (CLI tools and
        /// helper agents live there), so this audit does not guess at it.
        case backgroundItem

        public var label: String {
            switch self {
            case .launchAgent: "Launch agent"
            case .launchDaemon: "Launch daemon"
            case .privilegedHelper: "Privileged helper"
            case .backgroundItem: "Background item"
            }
        }
    }

    public let url: URL
    public let kind: Kind
    public let label: String
    public let target: String?
    public let reason: String

    public var id: String { url.path }

    public init(url: URL, kind: Kind, label: String, target: String?, reason: String) {
        self.url = url
        self.kind = kind
        self.label = label
        self.target = target
        self.reason = reason
    }
}

/// Reports orphaned launch items and privileged helpers. **Read-only by
/// design** — it never deletes a plist, never calls `launchctl`, and never
/// touches the installer receipt database.
///
/// Why report-only: a LaunchDaemon and its helper in
/// `/Library/PrivilegedHelperTools` are root-owned, and removing one without
/// the other (or without unloading it) leaves a system in a half-configured
/// state that is harder to diagnose than the original leftover. Sweep surfaces
/// them with a Reveal action and lets the user decide.
public enum LaunchItemAudit {

    public struct Roots: Sendable {
        public var userAgents: URL
        public var systemAgents: URL
        public var systemDaemons: URL
        public var privilegedHelpers: URL

        public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            userAgents = home.appending(path: "Library/LaunchAgents")
            systemAgents = URL(fileURLWithPath: "/Library/LaunchAgents")
            systemDaemons = URL(fileURLWithPath: "/Library/LaunchDaemons")
            privilegedHelpers = URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
        }
    }

    public static func audit(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        index: InstalledAppIndex,
        roots: Roots? = nil
    ) -> [LaunchItemFinding] {
        let roots = roots ?? Roots(home: home)
        var findings: [LaunchItemFinding] = []
        var referencedTargets = Set<String>()

        let sources: [(URL, LaunchItemFinding.Kind)] = [
            (roots.userAgents, .launchAgent),
            (roots.systemAgents, .launchAgent),
            (roots.systemDaemons, .launchDaemon),
        ]

        for (root, kind) in sources {
            for plist in plists(in: root) {
                if Task.isCancelled { return findings }
                guard let item = LaunchItem(url: plist) else { continue }
                if var program = item.program {
                    // `~/bin/tool` in a plist the user wrote: judge the file it
                    // names, not a literal "~" folder.
                    if program == "~" || program.hasPrefix("~/") {
                        program = home.path + program.dropFirst()
                    }
                    referencedTargets.insert(SafetyPolicy.canonical(program))
                    if !FileManager().fileExists(atPath: program) {
                        findings.append(LaunchItemFinding(
                            url: plist, kind: kind, label: item.label,
                            target: program,
                            reason: "its program is missing: \(program)"
                        ))
                    }
                }
                // No Program / ProgramArguments / BundleProgram key at all: the
                // plist may be driven by a MachServices bundle or be malformed.
                // We cannot tell whether it is orphaned, so we say nothing.
            }
        }

        for helper in files(in: roots.privilegedHelpers) {
            if Task.isCancelled { return findings }
            guard !referencedTargets.contains(SafetyPolicy.canonical(helper.path)) else { continue }
            let name = helper.lastPathComponent
            guard vendorIsAbsent(bundleID: name, home: home, index: index) else { continue }
            findings.append(LaunchItemFinding(
                url: helper, kind: .privilegedHelper, label: name, target: nil,
                reason: "no launch item references it and no app for \(name) is installed"
            ))
        }

        return findings.sorted { $0.label < $1.label }
    }

    /// True when nothing installed claims this helper's id or its vendor.
    static func vendorIsAbsent(bundleID name: String, home: URL, index: InstalledAppIndex) -> Bool {
        let lowered = name.lowercased()
        guard OrphanScanner.looksLikeBundleID(name) else { return false }
        if lowered.hasPrefix("com.apple.") { return false }
        if index.bundleIDs.contains(lowered) || index.runningBundleIDs.contains(lowered) { return false }
        if let vendor = OrphanScanner.vendorPrefix(lowered) {
            let activeVendors = Set(index.bundleIDs.union(index.runningBundleIDs).compactMap(OrphanScanner.vendorPrefix))
            if activeVendors.contains(vendor) { return false }
        }
        if let token = ResidueIndex.vendorToken(lowered), index.tokens.contains(token) { return false }
        return !AppResidueScanner.isInstalledElsewhere(lowered, home: home, candidate: nil, index: index)
    }

    static func plists(in root: URL) -> [URL] {
        files(in: root).filter { $0.pathExtension == "plist" }
    }

    static func files(in root: URL) -> [URL] {
        (try? FileManager().contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// A parsed launch-item plist.
    struct LaunchItem {
        let label: String
        let program: String?

        init?(url: URL) {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = plist as? [String: Any] else { return nil }
            label = (dictionary["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            program = Self.programPath(dictionary)
        }

        /// `Program`, else the first element of `ProgramArguments`.
        ///
        /// `BundleProgram` is deliberately ignored: it is relative to a bundle
        /// this audit doesn't resolve, so reporting on it would be guesswork. A
        /// plist with none of these keys yields `nil` and produces no finding —
        /// a shell probe that treated a plist-reader error string as a path is
        /// exactly how this produced a false "orphaned" verdict during design.
        static func programPath(_ dictionary: [String: Any]) -> String? {
            var candidate: String?
            if let program = dictionary["Program"] as? String, !program.isEmpty {
                candidate = program
            } else if let arguments = dictionary["ProgramArguments"] as? [String],
                      let first = arguments.first, !first.isEmpty {
                candidate = first
            }
            // A bare command (`sh`, `node`) is looked up on a PATH this audit
            // cannot reproduce, so its absence proves nothing.
            guard let candidate, candidate.contains("/") else { return nil }
            return candidate
        }
    }
}
