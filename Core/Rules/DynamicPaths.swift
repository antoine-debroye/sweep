import Foundation

/// Path discovery for rules whose targets depend on what is installed: sandbox
/// containers, Chromium profiles, Electron apps, versioned tool installs. Pure
/// read-only directory listing; every function returns only paths that exist.
/// Home is injectable so the whole catalog can be pointed at a fixture tree.
public enum DynamicPaths {

    // MARK: - Sandboxed containers

    /// Apple sandboxed daemons/apps whose container caches are known to be
    /// regenerable (the list mole ships). Every other `com.apple.*` container
    /// is left alone: some hold state that is expensive or impossible to rebuild.
    static let appleContainerCacheAllowlist: Set<String> = [
        "com.apple.mediaanalysisd",
        "com.apple.photoanalysisd",
        "com.apple.wallpaper.agent",
        "com.apple.wallpaper.extension.image",
        "com.apple.AppStore",
        "com.apple.stocks",
        "com.apple.geod",
        "com.apple.AvatarUI.AvatarPickerMemojiPicker",
        "com.apple.AMPArtworkAgent",
        "com.apple.CoreDevice.CoreDeviceService",
        "com.apple.NeptuneOneExtension",
        "com.apple.iBooksX",
        "com.apple.podcasts",
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    /// Apple containers whose `Data/tmp` mole clears (download leftovers).
    static let appleContainerTmpAllowlist: Set<String> = [
        "com.apple.mediaanalysisd",
        "com.apple.configurator.xpc.InternetService",
        "com.apple.wallpaper.extension.aerials",
        "com.apple.geod",
        "com.apple.AppleMediaServicesUI.UtilityExtension",
        "com.apple.podcasts",
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    /// Containers with dedicated rules elsewhere, or that must never be
    /// touched by the generic sweep.
    static let containerDenylist: Set<String> = [
        "com.apple.safari",            // browser rule
        "com.apple.mail",              // mail rule (attachments only)
        "com.docker.docker",           // VM disk lives here; docker prune instead
        "com.utmapp.utm",              // VM images
        "com.microsoft.onedrive-mac",  // sync client state
    ]

    public static func containerCacheRoots(home: URL) -> [URL] {
        containerRoots(home: home, subpath: "Data/Library/Caches", appleAllowlist: appleContainerCacheAllowlist)
    }

    public static func containerLogRoots(home: URL) -> [URL] {
        containerRoots(home: home, subpath: "Data/Library/Logs", appleAllowlist: [])
    }

    public static func containerTmpRoots(home: URL) -> [URL] {
        containerRoots(home: home, subpath: "Data/tmp", appleAllowlist: appleContainerTmpAllowlist)
    }

    private static func containerRoots(home: URL, subpath: String, appleAllowlist: Set<String>) -> [URL] {
        let root = home.appending(path: "Library/Containers")
        return directories(in: root).compactMap { container in
            let id = container.lastPathComponent
            let lowered = id.lowercased()
            if lowered.hasPrefix("com.apple.safari") || containerDenylist.contains(lowered) { return nil }
            if lowered.hasPrefix("com.apple."), !appleAllowlist.contains(lowered) { return nil }
            let target = container.appending(path: subpath)
            return isDirectory(target) ? target : nil
        }
    }

    // MARK: - Group containers

    public struct GroupContainerJunk: Sendable {
        public var caches: [URL] = []
        public var logs: [URL] = []
        public var tmp: [URL] = []
    }

    /// Cache/log/tmp folders inside third-party group containers. Apple's own
    /// group containers and anything a File Provider sync client owns are
    /// skipped (the latter is also hard-protected by `SafetyPolicy`).
    public static func groupContainerJunk(home: URL) -> GroupContainerJunk {
        let fm = FileManager()
        let root = home.appending(path: "Library/Group Containers")
        var junk = GroupContainerJunk()
        for container in directories(in: root) {
            let name = container.lastPathComponent.lowercased()
            if name.contains("com.apple.") || name.contains("onedrive") { continue }
            if fm.fileExists(atPath: container.appending(path: "File Provider Storage").path) { continue }
            for sub in ["Library/Caches", "Caches"] where isDirectory(container.appending(path: sub)) {
                junk.caches.append(container.appending(path: sub))
            }
            for sub in ["Library/Logs", "Logs"] where isDirectory(container.appending(path: sub)) {
                junk.logs.append(container.appending(path: sub))
            }
            for sub in ["tmp", "Library/tmp"] where isDirectory(container.appending(path: sub)) {
                junk.tmp.append(container.appending(path: sub))
            }
        }
        return junk
    }

    // MARK: - Chromium browsers

    /// Chromium-based browser data roots relative to ~/Library/Application Support.
    static let chromiumRoots: [String] = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
        "BraveSoftware/Brave-Browser", "BraveSoftware/Brave-Browser-Beta", "BraveSoftware/Brave-Browser-Nightly",
        "Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev", "Microsoft Edge Canary",
        "Vivaldi", "Arc/User Data", "Arc",
    ]

    /// Per-profile subfolders that are pure caches (rebuilt silently).
    static let chromiumProfileSafeSubdirs = [
        "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "GraphiteDawnCache", "Application Cache",
    ]
    /// Root-level caches shared by all profiles.
    static let chromiumRootSafeSubdirs = [
        "ShaderCache", "GrShaderCache", "GraphiteDawnCache", "GPUPersistentCache",
        "component_crx_cache", "extensions_crx_cache", "Crashpad/completed",
    ]
    /// Regenerable but with a visible cost: offline web-app data reloads, the
    /// on-device AI model (multi-GB) re-downloads. Surfaced, never pre-selected.
    static let chromiumRootReviewSubdirs = [
        "OptGuideOnDeviceModel", "OptGuideOnDeviceClassifierModel", "optimization_guide_model_store",
    ]

    public struct ChromiumJunk: Sendable {
        public var safe: [URL] = []
        public var review: [URL] = []
    }

    public static func chromiumJunk(home: URL) -> ChromiumJunk {
        let support = home.appending(path: "Library/Application Support")
        var junk = ChromiumJunk()
        for relative in chromiumRoots {
            let root = support.appending(path: relative)
            guard isDirectory(root) else { continue }
            for sub in chromiumRootSafeSubdirs where isDirectory(root.appending(path: sub)) {
                junk.safe.append(root.appending(path: sub))
            }
            for sub in chromiumRootReviewSubdirs where isDirectory(root.appending(path: sub)) {
                junk.review.append(root.appending(path: sub))
            }
            for profile in directories(in: root) where isChromiumProfile(profile.lastPathComponent) {
                for sub in chromiumProfileSafeSubdirs where isDirectory(profile.appending(path: sub)) {
                    junk.safe.append(profile.appending(path: sub))
                }
                let swCache = profile.appending(path: "Service Worker/CacheStorage")
                if isDirectory(swCache) { junk.review.append(swCache) }
            }
        }
        // Firefox keeps a secondary cache inside the profile.
        let firefoxProfiles = support.appending(path: "Firefox/Profiles")
        for profile in directories(in: firefoxProfiles) where isDirectory(profile.appending(path: "cache2")) {
            junk.safe.append(profile.appending(path: "cache2"))
        }
        return junk
    }

    static func isChromiumProfile(_ name: String) -> Bool {
        name == "Default" || name == "Guest Profile" || name == "System Profile" || name.hasPrefix("Profile ")
    }

    // MARK: - Electron apps

    /// Folders that identify a Chromium/Electron data directory.
    static let electronMarkers = ["Code Cache", "GPUCache", "Partitions", "Cache/Cache_Data"]
    /// Cache-only subfolders (safe). `Cache`/`CachedData` are only offered when
    /// a marker proves the folder is an Electron profile — some non-Electron
    /// apps keep real data in a folder called "Cache".
    static let electronSafeSubdirs = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "GraphiteDawnCache", "CachedData", "Crashpad/completed",
    ]
    /// Apps with dedicated, finer-grained rules, and browsers (Chromium rule).
    static let electronSkipList: Set<String> = [
        "cursor", "code", "code - insiders", "google", "bravesoftware", "microsoft edge",
        "microsoft edge beta", "microsoft edge dev", "microsoft edge canary",
        "vivaldi", "arc", "chromium", "firefox",
    ]

    public struct ElectronJunk: Sendable {
        public var safe: [URL] = []
        /// Offline web-app storage and log folders.
        public var review: [URL] = []
    }

    public static func electronJunk(home: URL) -> ElectronJunk {
        let support = home.appending(path: "Library/Application Support")
        var junk = ElectronJunk()
        for app in directories(in: support) {
            let name = app.lastPathComponent.lowercased()
            if electronSkipList.contains(name) || name.hasPrefix("com.apple.") { continue }
            guard electronMarkers.contains(where: { isDirectory(app.appending(path: $0)) }) else { continue }
            collectElectronProfile(app, into: &junk)
            if isDirectory(app.appending(path: "logs")) { junk.review.append(app.appending(path: "logs")) }
            // Electron session partitions (Notion, Claude, Cursor) mirror the
            // top-level layout one level down.
            for partition in directories(in: app.appending(path: "Partitions")) {
                collectElectronProfile(partition, into: &junk)
            }
        }
        return junk
    }

    private static func collectElectronProfile(_ dir: URL, into junk: inout ElectronJunk) {
        for sub in electronSafeSubdirs where isDirectory(dir.appending(path: sub)) {
            junk.safe.append(dir.appending(path: sub))
        }
        let swCache = dir.appending(path: "Service Worker/CacheStorage")
        if isDirectory(swCache) { junk.review.append(swCache) }
    }

    // MARK: - Versioned tool installs

    /// Version directories under `root` that are neither the newest `keep`
    /// nor the one an active symlink (e.g. ~/.local/bin/claude) resolves into.
    /// Also keeps any version named in `pinnedVersions`.
    public static func staleVersionDirs(
        root: URL,
        activeLink: URL? = nil,
        pinnedVersions: Set<String> = [],
        keep: Int = 1
    ) -> [URL] {
        // Claude Code stores each version as a single executable file, Cursor
        // Agent as a folder — accept both.
        let versions = entries(in: root)
        guard versions.count > keep else { return [] }
        var keepNames = pinnedVersions
        if let activeLink {
            let resolved = activeLink.resolvingSymlinksInPath().path
            let rootPath = root.resolvingSymlinksInPath().path
            if resolved.hasPrefix(rootPath + "/") {
                let rest = resolved.dropFirst(rootPath.count + 1)
                if let first = rest.split(separator: "/").first { keepNames.insert(String(first)) }
            }
        }
        let sorted = versions.sorted { compareVersions($0.lastPathComponent, $1.lastPathComponent) == .orderedDescending }
        for dir in sorted.prefix(keep) { keepNames.insert(dir.lastPathComponent) }
        return sorted.filter { !keepNames.contains($0.lastPathComponent) }
    }

    /// Semantic comparison when both names parse as versions, otherwise a
    /// natural ("Finder-style") string comparison so "2026.04.17-x" sorts sanely.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let l = SemanticVersion(lhs), let r = SemanticVersion(rhs) {
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        }
        return lhs.localizedStandardCompare(rhs)
    }

    /// Extension folders the editor itself has marked obsolete
    /// (`<extensions>/.obsolete` is a JSON object keyed by folder name, each
    /// value `true` while the folder awaits removal).
    public static func obsoleteExtensionDirs(extensionsRoot: URL) -> [URL] {
        let marker = extensionsRoot.appending(path: ".obsolete")
        guard let data = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted().compactMap { name in
            // Only an explicit `true` is a removal mark; anything else is a
            // format we don't understand, so the folder stays.
            guard (object[name] as? Bool) == true else { return nil }
            guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
            let dir = extensionsRoot.appending(path: name)
            return isDirectory(dir) ? dir : nil
        }
    }

    /// ZIP downloads that contain an app or installer (many apps ship as
    /// `.zip`, not `.dmg`). Dataless iCloud placeholders are skipped — reading
    /// one would download it.
    public static func installerArchives(in folder: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isUbiquitousItemKey]
        let entries = (try? FileManager().contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        return entries.filter { url in
            guard url.pathExtension.lowercased() == "zip",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isUbiquitousItem != true,
                  let size = values.fileSize, size >= 1_000_000,
                  Int64(values.totalFileAllocatedSize ?? 0) * 2 >= Int64(size) else { return false }
            return ZipListing.looksLikeInstaller(url)
        }
    }

    /// Playwright browser builds (`chromium-1248`, `firefox-1555`…) that no
    /// project still uses.
    ///
    /// Each `playwright install` leaves a file in `.links` holding the path of
    /// that project's `playwright-core`, whose `browsers.json` names the exact
    /// revisions it launches. A build referenced by any live project is kept,
    /// and so is the newest build of each browser. If a link points at a
    /// project that exists but can't be read, nothing is offered: Sweep can't
    /// tell what that project needs.
    public static func unusedPlaywrightBrowsers(root: URL) -> [URL] {
        let fm = FileManager()
        let builds = directories(in: root).compactMap { url -> (url: URL, family: String, revision: Int)? in
            let name = url.lastPathComponent
            guard let dash = name.lastIndex(of: "-"),
                  let revision = Int(name[name.index(after: dash)...]) else { return nil }
            return (url, String(name[..<dash]), revision)
        }
        guard !builds.isEmpty else { return [] }

        var referenced: Set<String> = []
        let links = (try? fm.contentsOfDirectory(at: root.appending(path: ".links"), includingPropertiesForKeys: nil)) ?? []
        for link in links {
            guard let target = try? String(contentsOf: link, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { continue }
            let core = URL(fileURLWithPath: target)
            // Project deleted: Playwright's own cleanup drops this link too.
            guard fm.fileExists(atPath: core.path) else { continue }
            guard let names = playwrightBuildNames(core.appending(path: "browsers.json")) else { return [] }
            referenced.formUnion(names)
        }

        let newest = Dictionary(grouping: builds, by: \.family).compactMapValues { $0.max { $0.revision < $1.revision }?.url }
        return builds
            .filter { !referenced.contains($0.url.lastPathComponent) && newest[$0.family] != $0.url }
            .map(\.url)
    }

    /// Folder names a `browsers.json` resolves to (`chromium-headless-shell`
    /// revision 1248 lives in `chromium_headless_shell-1248`), or nil when the
    /// file can't be read.
    static func playwrightBuildNames(_ browsersJSON: URL) -> Set<String>? {
        struct Manifest: Decodable {
            struct Browser: Decodable { let name: String; let revision: String }
            let browsers: [Browser]
        }
        guard let data = try? Data(contentsOf: browsersJSON),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return Set(manifest.browsers.map { $0.name.replacingOccurrences(of: "-", with: "_") + "-" + $0.revision })
    }

    /// Codex runtime folders that never finished installing (no `runtime.json`).
    public static func incompleteCodexRuntimes(home: URL) -> [URL] {
        let root = home.appending(path: ".cache/codex-runtimes")
        return directories(in: root).filter {
            !FileManager().fileExists(atPath: $0.appending(path: "runtime.json").path)
        }
    }

    // MARK: - Xcode

    /// Device-support folders beyond the newest `keep` per platform, by
    /// modification date (the ones Xcode synced most recently are kept).
    public static func staleDeviceSupport(home: URL, keep: Int = 2) -> [URL] {
        let dev = home.appending(path: "Library/Developer/Xcode")
        var stale: [URL] = []
        for platform in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport",
                         "macOS DeviceSupport"] {
            let dirs = directories(in: dev.appending(path: platform))
            guard dirs.count > keep else { continue }
            let byDate = dirs.sorted { modificationDate($0) > modificationDate($1) }
            stale += byDate.dropFirst(keep)
        }
        return stale
    }

    /// Rebuildable data inside shut-down simulators: caches (PosterBoard's
    /// lock-screen renders among them), the unified-log store, downloaded
    /// MobileAsset content and scratch space. A device regenerates all of it
    /// on its next boot.
    ///
    /// All or nothing: if any device is not shut down, or any device's state
    /// cannot be read, nothing is offered. A booted simulator shares
    /// CoreSimulator services with the others, and a probe we could not
    /// finish is not a verdict (Mole I-16).
    public static func idleSimulatorDeviceData(home: URL) -> [URL] {
        let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices")
        let leaves = [
            "data/Library/Caches",
            "data/var/db/diagnostics",
            "data/var/db/uuidtext",
            "data/private/var/MobileAsset",
            "data/tmp",
        ]
        var found: [URL] = []
        for device in directories(in: devices) {
            guard let state = simulatorState(of: device) else { return [] }
            guard state == simulatorShutdownState else { return [] }
            let root = device.resolvingSymlinksInPath().path
            for leaf in leaves {
                let url = device.appending(path: leaf)
                guard isDirectory(url), !isSymlink(url) else { continue }
                // Never follow a link out of the device: every component of
                // the leaf must resolve inside the device folder.
                guard url.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { continue }
                found.append(url)
            }
        }
        return found
    }

    /// CoreSimulator's `state` in device.plist: 1 = Shutdown, 3 = Booted.
    static let simulatorShutdownState = 1

    static func simulatorState(of device: URL) -> Int? {
        guard let data = try? Data(contentsOf: device.appending(path: "device.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        return (dictionary["state"] as? NSNumber)?.intValue
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    // MARK: - Helpers

    static func directories(in root: URL) -> [URL] {
        let fm = FileManager()
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { entry in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Non-hidden, non-symlink children (files and directories).
    static func entries(in root: URL) -> [URL] {
        let fm = FileManager()
        guard let list = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return list
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager().fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
