import Foundation

// MARK: - Residue index

/// One shallow listing of every Library root that apps scatter data across,
/// indexed by bundle id and by vendor token. Built once per scan; no sizing.
struct ResidueIndex: Sendable {
    /// Lowercased bundle id -> the paths that carry it.
    let byBundleID: [String: [URL]]
    /// Normalized vendor token ("figma") -> the bundle ids seen under it.
    let byVendorToken: [String: Set<String>]
    /// Paths referenced by a launch item whose files still exist — program
    /// arguments, log destinations, working directories.
    ///
    /// This is what separates "an app's abandoned data" from "a tool the user
    /// still runs". A launchd job needs no `.app` bundle, so every
    /// no-app-installed evidence channel fires on one: a personal script under
    /// `~/Library/Application Support/<name>/` driven by
    /// `~/Library/LaunchAgents/<id>.plist` looks exactly like a leftover. It is
    /// the opposite — it is live, and offering to delete it would break the
    /// user's own automation.
    let launchReferencedPaths: Set<String>
    /// Lowercased labels of launch items that still resolve. Their preferences
    /// and support data belong to a live job, not to a departed app.
    let liveLaunchLabels: Set<String>
    /// Normalized *last* bundle-id component ("synctool") -> the bundle ids
    /// seen under it. Some publishers name the folder after the app rather than
    /// the vendor (`com.example.synctool` + a `sync-tool` folder), so the vendor
    /// token alone would never connect them. Filtered hard: short and generic
    /// last components ("app", "mail", "helper") identify nobody and would
    /// happily link unrelated data together.
    let byAppToken: [String: Set<String>]

    static let roots = [
        "Application Support", "Caches", "Containers", "Saved Application State",
        "HTTPStorages", "WebKit", "Preferences", "Logs", "Group Containers",
        "Application Scripts", "LaunchAgents", "Cookies",
    ]

    /// Last bundle-id components that name a role, not a product.
    static let genericAppComponents: Set<String> = [
        "desktop", "mail", "client", "helper", "agent", "updater", "service", "daemon",
        "framework", "extension", "widget", "launcher", "installer", "uninstaller",
        "sync", "share", "main", "core", "shared", "browser", "app", "macos", "plugin",
        "notifications", "quicklook", "finderextension", "safariextension",
    ]

    static let strippableSuffixes = [
        ".plist.lockfile", ".binarycookies", ".savedState", ".plist", ".dua", ".sfl3", ".sfl2",
    ]

    static func build(home: URL) -> ResidueIndex {
        let fm = FileManager()
        let lib = home.appending(path: "Library")
        var byBundleID: [String: [URL]] = [:]
        var byVendorToken: [String: Set<String>] = [:]
        var byAppToken: [String: Set<String>] = [:]
        let live = launchItemLiveness(home: home)

        for root in roots {
            let url = lib.appending(path: root)
            guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let bundleID = normalizedBundleID(entry.lastPathComponent)
                guard let bundleID, !bundleID.hasPrefix("com.apple.") else { continue }
                byBundleID[bundleID, default: []].append(entry)
                if let vendor = vendorToken(bundleID) {
                    byVendorToken[vendor, default: []].insert(bundleID)
                }
                if let app = appToken(bundleID) {
                    byAppToken[app, default: []].insert(bundleID)
                }
            }
        }
        return ResidueIndex(
            byBundleID: byBundleID,
            byVendorToken: byVendorToken,
            launchReferencedPaths: live.paths,
            liveLaunchLabels: live.labels,
            byAppToken: byAppToken
        )
    }

    /// Strips the wrapper suffix and returns the lowercased bundle id, or nil if
    /// the entry name isn't reverse-DNS shaped.
    static func normalizedBundleID(_ fileName: String) -> String? {
        var name = fileName
        for suffix in strippableSuffixes where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        guard OrphanScanner.looksLikeBundleID(name) else { return nil }
        return name.lowercased()
    }

    /// Second reverse-DNS component, normalized: "com.figma.Desktop" -> "figma".
    static func vendorToken(_ bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let token = NameToken.normalize(parts[1])
        guard token.count >= 3, !NameToken.genericComponents.contains(token) else { return nil }
        return token
    }

    /// Last reverse-DNS component, normalized: "com.example.synctool" -> "synctool".
    static func appToken(_ bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 3, let last = parts.last else { return nil }
        let token = NameToken.normalize(last)
        guard token.count >= 5,
              !NameToken.genericComponents.contains(token),
              !genericAppComponents.contains(token) else { return nil }
        return token
    }

    /// Bundle ids linked to a folder name, by vendor component or by app component.
    func bundleIDs(forToken token: String) -> Set<String> {
        (byVendorToken[token] ?? []).union(byAppToken[token] ?? [])
    }

    /// True when a launch item points at something inside `folder`.
    func isReferencedByLaunchItem(_ folder: URL) -> Bool {
        guard !launchReferencedPaths.isEmpty else { return false }
        let path = SafetyPolicy.canonical(folder.path)
        return launchReferencedPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// True when this bundle id is the label of a launch item that still
    /// resolves.
    func isLiveLaunchLabel(_ bundleID: String) -> Bool {
        liveLaunchLabels.contains(bundleID.lowercased())
    }

    /// Existing paths named by launch items, and the labels of the items that
    /// named them.
    static func launchItemLiveness(home: URL) -> (paths: Set<String>, labels: Set<String>) {
        let fm = FileManager()
        let roots = [
            home.appending(path: "Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
        ]
        var referenced = Set<String>()
        var labels = Set<String>()
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: entry),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dictionary = plist as? [String: Any] else { continue }
                var candidates: [String] = []
                if let program = dictionary["Program"] as? String { candidates.append(program) }
                if let arguments = dictionary["ProgramArguments"] as? [String] { candidates += arguments }
                for key in ["StandardOutPath", "StandardErrorPath", "WorkingDirectory"] {
                    if let value = dictionary[key] as? String { candidates.append(value) }
                }
                for candidate in candidates where candidate.hasPrefix("/") {
                    guard fm.fileExists(atPath: candidate) else { continue }
                    referenced.insert(SafetyPolicy.canonical(candidate))
                    // The plist itself is part of what keeps this alive.
                    referenced.insert(SafetyPolicy.canonical(entry.path))
                    let label = (dictionary["Label"] as? String)
                        ?? entry.deletingPathExtension().lastPathComponent
                    labels.insert(label.lowercased())
                }
            }
        }
        return (referenced, labels)
    }
}

// MARK: - Leftover / stale-data scanner

/// Finds two things the reverse-DNS orphan pass structurally cannot see:
///
/// **A.** Folders named after an app's *display* name ("Figma") whose owning app
/// is gone. Every Electron app and many native ones store data this way, so the
/// bundle-id-only pass misses their bulk entirely.
///
/// **B.** Dead per-app subfolders one level inside a *live vendor's* folder
/// ("Adobe/AcroCef" while Creative Cloud is installed). Vendor-level suppression
/// is correct — deleting the whole `Adobe` folder could break a running app —
/// but it must not make every stale byte underneath invisible forever.
///
/// Everything emitted is `.review`: surfaced, never pre-selected, never
/// auto-trimmed.
enum AppResidueScanner {

    // MARK: Deny-lists

    /// Apple-owned folders in Application Support. These are not app leftovers
    /// and several have matching reverse-DNS residue, so name evidence alone
    /// would happily offer them.
    static let appleOwnedNames: Set<String> = [
        "addressbook", "crashreporter", "animoji", "diskimages", "knowledge", "clouddocs",
        "fileprovider", "logs", "spotlight", "controlcenter", "syncservices",
        "differentialprivacy", "mobilesync", "callhistorydb", "callhistorytransactions",
        "networkserviceproxy", "icdd", "sesstorage", "appstore", "assistant", "avatars",
        "bird", "caldav", "configurationprofiles", "coresimulator", "icloud", "passes",
        "siri", "storekit", "textinput", "facetime", "music", "appstatekeeper",
        "intelligenceflow", "networkoptimizer", "com", "apple",
    ]

    /// Shared language/toolchain/runtime data. Not owned by any one app, so
    /// "no app answers to this name" is meaningless for them.
    static let sharedRuntimeNames: Set<String> = [
        "electron", "cef", "go", "turborepo", "codex", "antigravity", "reactnativedevtools",
        "node", "npm", "pnpm", "yarn", "bun", "pip", "rustup", "cargo", "gradle", "jetbrains",
        "homebrew", "docker", "nvidia", "python", "chromium",
    ]

    // MARK: Part A

    struct Cluster {
        let token: String
        let displayName: String
        let members: [URL]
        let reason: String
    }

    /// Classification of one `Application Support` child.
    enum Candidate {
        /// Its owning app is gone — offer the whole cluster.
        case leftover(Cluster)
        /// Its owning app is gone, but a process is still executing from inside
        /// the folder. Reported, never offered: deleting data underneath a live
        /// process is not a clean-up, and the user has to stop it first.
        case blockedByRunningProcess(Cluster, executable: String)
        /// A vendor folder whose vendor still has an installed app. Not a
        /// leftover, but its subfolders are Part B candidates.
        case liveVendorFolder(URL, token: String)
        case skip
    }

    struct Output {
        var items: [ScanItem] = []
        /// Leftovers that cannot be cleaned yet because something is running
        /// out of them.
        var blocked: [LaunchItemFinding] = []
    }

    static func scan(
        home: URL,
        index: InstalledAppIndex,
        residue: ResidueIndex,
        policy: SafetyPolicy,
        minAgeDays: Int = 14,
        minClusterBytes: Int64 = 1_000_000,
        staleMinAgeDays: Int = 180,
        staleMinBytes: Int64 = 50_000_000
    ) -> Output {
        let support = home.appending(path: "Library/Application Support")
        var output = Output()
        var vendorFolders: [(URL, String)] = []

        for candidate in DynamicPaths.directories(in: support) {
            if Task.isCancelled { return output }
            switch classify(candidate, home: home, index: index, residue: residue, policy: policy) {
            case .leftover(let cluster):
                output.items += clusterItems(
                    cluster, policy: policy, minAgeDays: minAgeDays, minBytes: minClusterBytes
                )
            case .blockedByRunningProcess(let cluster, let executable):
                output.blocked.append(LaunchItemFinding(
                    url: candidate,
                    kind: .backgroundItem,
                    label: cluster.displayName,
                    target: executable,
                    reason: "\(cluster.reason), but \(URL(fileURLWithPath: executable).lastPathComponent) "
                        + "is running from this folder — quit it and remove its login item, then rescan"
                ))
            case .liveVendorFolder(let url, let token):
                vendorFolders.append((url, token))
            case .skip:
                continue
            }
        }

        for (folder, token) in vendorFolders {
            if Task.isCancelled { return output }
            output.items += staleSubfolderItems(
                in: folder, vendorToken: token, index: index, residue: residue, policy: policy,
                minAgeDays: staleMinAgeDays, minBytes: staleMinBytes
            )
        }
        return output
    }

    static func classify(
        _ candidate: URL,
        home: URL,
        index: InstalledAppIndex,
        residue: ResidueIndex,
        policy: SafetyPolicy
    ) -> Candidate {
        let name = candidate.lastPathComponent
        // Reverse-DNS names belong to the existing OrphanScanner pass. Leaving
        // them there is what keeps the "every path offered once" invariant.
        guard !OrphanScanner.looksLikeBundleID(name) else { return .skip }
        guard !policy.isProtected(candidate) else { return .skip }

        let token = NameToken.normalize(name)
        guard token.count >= 3 else { return .skip }
        let variants = NameToken.variants(name)
        guard variants.isDisjoint(with: appleOwnedNames), !name.hasPrefix("com.apple.") else { return .skip }
        guard variants.isDisjoint(with: sharedRuntimeNames) else { return .skip }
        // A password vault or an input method's learned dictionary is not
        // regenerable, so its data is never offered even once the app is gone.
        guard !BundleProtection.nameLooksDataSensitive(name) else { return .skip }
        guard !RunningAppGuard.isOwnedByRunningApp(
            candidate, running: index.runningBundleIDs, names: index.runningNames
        ) else { return .skip }
        // Driven by a launch item that still resolves: a live tool, not a
        // leftover. A launchd job needs no .app bundle, so every "no app is
        // installed" channel would otherwise fire on the user's own scripts.
        guard !residue.isReferencedByLaunchItem(candidate) else { return .skip }

        // Curated folder -> bundle-id map, shared with RunningAppGuard. This is
        // both the strongest evidence channel AND the explicit suppression for
        // folders whose name doesn't resemble their app: "Code" -> VS Code,
        // "Google" -> Chrome. Because those ids resolve while the app is
        // installed, they suppress themselves.
        func verdict(_ reason: String) -> Candidate {
            let cluster = Cluster(
                token: token, displayName: name,
                members: clusterMembers(candidate, token: token, residue: residue, home: home, index: index),
                reason: reason
            )
            // Checked only once evidence says the owner is gone. Checking it
            // earlier would flag every CLI tool and helper agent that legitimately
            // runs from its own folder under Application Support.
            if let executable = index.runningExecutable(in: candidate) {
                return .blockedByRunningProcess(cluster, executable: executable)
            }
            return .leftover(cluster)
        }

        if let mapped = variants.compactMap({ RunningAppGuard.nameToBundleID[$0] }).first(where: { !$0.isEmpty }) {
            if isInstalledElsewhere(mapped, home: home, candidate: candidate, index: index) {
                return .skip   // deliberately NOT a Part B candidate: this folder
                               // is the live app's own data, not a vendor folder.
            }
            return verdict("no app for \(mapped) is installed")
        }

        // An installed/running app answers to this name -> live data.
        if index.matchesInstalledApp(name: name) {
            // Distinguish "this folder is that app's own data" (Cursor, Dropbox)
            // from "this folder is a vendor's shared folder while one of its
            // apps is installed" (Adobe, Microsoft). Only the latter gets a
            // Part B pass; descending into a live app's own data risks offering
            // its settings or local history.
            if index.isVendorOnlyMatch(name: name) {
                return .liveVendorFolder(candidate, token: token)
            }
            return .skip
        }

        // Orphaned reverse-DNS residue linked to this folder name.
        do {
            let ids = variants.reduce(into: Set<String>()) { $0.formUnion(residue.bundleIDs(forToken: $1)) }
            let orphaned = ids.filter { id in
                !index.bundleIDs.contains(id) && !index.runningBundleIDs.contains(id)
                    && !isInstalledElsewhere(id, home: home, candidate: candidate, index: index)
            }
            if !orphaned.isEmpty {
                return verdict("no app for \(orphaned.sorted().joined(separator: ", ")) is installed")
            }
        }

        // A staged app bundle inside the folder whose id nothing installed
        // claims — how Electron auto-updaters (Figma) leave themselves behind.
        if let staged = stagedOrphanBundleID(in: candidate, home: home, index: index) {
            return verdict("contains an app bundle (\(staged)) that isn't installed")
        }

        return .skip
    }

    /// Whether a bundle id resolves to a *real installation*.
    ///
    /// Critical subtlety: auto-updating apps stage a copy of themselves inside
    /// their own support folder, and LaunchServices registers it. Figma's
    /// `com.figma.universalLinks` and `com.figma.agent` both resolve to
    /// `~/Library/Application Support/Figma/…app`. Treating that as "installed"
    /// is what hides the leftover — and is why `Caches/com.figma.agent` was
    /// suppressed before this change. A bundle living in the user's Library, in
    /// the candidate itself, in the Trash, or in a temp dir is not an install.
    /// The exception stays narrow on purpose: /opt, /usr/local, Setapp and
    /// external volumes still count, which is the safety net for apps outside
    /// the inventory roots.
    static func isInstalledElsewhere(
        _ bundleID: String, home: URL, candidate: URL?, index: InstalledAppIndex
    ) -> Bool {
        if index.bundleIDs.contains(bundleID.lowercased()) { return true }
        guard let url = index.resolveBundleID(bundleID) else { return false }
        let path = SafetyPolicy.canonical(url.path)
        let library = SafetyPolicy.canonical(home.appending(path: "Library").path)
        if path.hasPrefix(library + "/") { return false }
        if let candidate, path.hasPrefix(SafetyPolicy.canonical(candidate.path) + "/") { return false }
        if path.contains("/.trash/") || path.hasPrefix("/private/var/folders/") { return false }
        return true
    }

    static func stagedOrphanBundleID(in folder: URL, home: URL, index: InstalledAppIndex) -> String? {
        let fm = FileManager()
        var directories = [folder]
        if let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            directories += children.filter { $0.pathExtension != "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        for directory in directories {
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                guard let bundleID = Bundle(url: entry)?.bundleIdentifier?.lowercased() else { continue }
                guard !bundleID.hasPrefix("com.apple.") else { continue }
                if !index.bundleIDs.contains(bundleID),
                   !index.runningBundleIDs.contains(bundleID),
                   !isInstalledElsewhere(bundleID, home: home, candidate: folder, index: index) {
                    return bundleID
                }
            }
        }
        return nil
    }

    /// The candidate folder plus every other path that belongs to the same
    /// departed app: residue of its orphaned bundle ids, and same-named folders
    /// in the sibling Library roots.
    static func clusterMembers(
        _ candidate: URL, token: String, residue: ResidueIndex, home: URL, index: InstalledAppIndex
    ) -> [URL] {
        let fm = FileManager()
        let lib = home.appending(path: "Library")
        var members = [candidate]
        var seen = Set([SafetyPolicy.canonical(candidate.path)])

        func add(_ url: URL) {
            guard seen.insert(SafetyPolicy.canonical(url.path)).inserted else { return }
            members.append(url)
        }

        let memberIDs = NameToken.variants(candidate.lastPathComponent)
            .reduce(into: Set<String>()) { $0.formUnion(residue.bundleIDs(forToken: $1)) }
        for id in memberIDs {
            guard !index.bundleIDs.contains(id), !index.runningBundleIDs.contains(id) else { continue }
            guard !isInstalledElsewhere(id, home: home, candidate: candidate, index: index) else { continue }
            for url in residue.byBundleID[id] ?? [] { add(url) }
        }

        let variants = NameToken.variants(candidate.lastPathComponent)
        for root in ResidueIndex.roots where root != "Application Support" {
            let url = lib.appending(path: root)
            guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let bare = entry.deletingPathExtension().lastPathComponent
                if !variants.isDisjoint(with: NameToken.variants(bare)) { add(entry) }
            }
        }
        return members
    }

    static func clusterItems(
        _ cluster: Cluster, policy: SafetyPolicy, minAgeDays: Int, minBytes: Int64
    ) -> [ScanItem] {
        var measured: [(URL, DirectoryStats)] = []
        var total: Int64 = 0
        var primaryNewest: Date?

        for member in cluster.members {
            guard !policy.isProtected(member) else { continue }
            let stats = DirectorySizer.stats(of: member, ignoringHiddenEntries: true)
            guard stats.size > 0 else { continue }
            if member == cluster.members.first { primaryNewest = stats.newestModification }
            measured.append((member, stats))
            total += stats.size
        }

        guard total >= minBytes else { return [] }
        // The age gate is a second line only — evidence has already shown the
        // owning app is absent — and it reads the *primary* folder's date, not
        // the newest across the cluster.
        //
        // Two separate questions, two separate mechanisms: "is this data stale"
        // is the age gate; "is something still using it" is the running-process
        // check in `classify`. Folding them together made a departed app's
        // background helper rewriting its cache hold the whole cluster hostage —
        // including in the most common case of all, cleaning up right after an
        // uninstall, when every cache still carries today's date.
        if minAgeDays > 0, let primaryNewest,
           primaryNewest > Date().addingTimeInterval(-Double(minAgeDays) * 86_400) {
            return []
        }

        return measured.map { member, stats in
            ScanItem(
                ruleID: "orphan-app",
                category: .appLeftovers,
                url: member,
                displayName: ScanEngine.displayName(for: member),
                detail: detailLine(location: locationLabel(member), reason: cluster.reason, date: stats.newestModification),
                size: stats.size,
                fileCount: stats.fileCount,
                newestModification: stats.newestModification,
                tier: .review,
                domain: .user,
                group: cluster.token,
                identity: FileIdentity.current(of: member)
            )
        }
    }

    // MARK: Part B

    /// Dead per-app subfolders inside a vendor folder whose vendor is still
    /// installed. The age gate is the load-bearing evidence here: a folder
    /// inside a *live* vendor's support directory that hasn't been written in
    /// six months isn't in use by anything.
    static func staleSubfolderItems(
        in folder: URL, vendorToken: String, index: InstalledAppIndex, residue: ResidueIndex,
        policy: SafetyPolicy, minAgeDays: Int, minBytes: Int64
    ) -> [ScanItem] {
        let children = DynamicPaths.directories(in: folder)
        // A single-child folder is one app's own data, not a vendor share.
        guard children.count >= 2 else { return [] }

        let cutoff = Date().addingTimeInterval(-Double(minAgeDays) * 86_400)
        var items: [ScanItem] = []
        for child in children {
            if Task.isCancelled { return items }
            let name = child.lastPathComponent
            let token = NameToken.normalize(name)
            guard token.count >= 3, !policy.isProtected(child) else { continue }
            let variants = NameToken.variants(name)
            guard variants.isDisjoint(with: appleOwnedNames),
                  variants.isDisjoint(with: sharedRuntimeNames) else { continue }
            guard !BundleProtection.nameLooksDataSensitive(name) else { continue }
            guard !index.matchesInstalledApp(name: name) else { continue }
            guard variants.allSatisfy({ RunningAppGuard.nameToBundleID[$0] == nil }) else { continue }
            guard !RunningAppGuard.isOwnedByRunningApp(
                child, running: index.runningBundleIDs, names: index.runningNames
            ) else { continue }
            guard !index.hostsRunningProcess(in: child) else { continue }
            guard !residue.isReferencedByLaunchItem(child) else { continue }

            let stats = DirectorySizer.stats(of: child, ignoringHiddenEntries: true)
            guard stats.size >= minBytes else { continue }
            guard let newest = stats.newestModification, newest < cutoff else { continue }

            items.append(ScanItem(
                ruleID: "vendor-stale-subfolder",
                category: .appLeftovers,
                url: child,
                displayName: folder.lastPathComponent + " › " + name,
                detail: detailLine(
                    location: folder.lastPathComponent,
                    reason: "no app named \"\(name)\" is installed",
                    date: newest
                ),
                size: stats.size,
                fileCount: stats.fileCount,
                newestModification: newest,
                tier: .review,
                domain: .user,
                group: vendorToken,
                identity: FileIdentity.current(of: child)
            ))
        }
        return items
    }

    // MARK: Copy

    static func locationLabel(_ url: URL) -> String {
        let components = url.pathComponents
        guard let index = components.lastIndex(of: "Library"), index + 1 < components.count else {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return components[index + 1]
    }

    static func detailLine(location: String, reason: String, date: Date?) -> String {
        var parts = [location, reason]
        if let date {
            parts.append("last change " + Self.formatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
