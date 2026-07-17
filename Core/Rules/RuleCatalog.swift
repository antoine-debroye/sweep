import Foundation

/// Builds the concrete set of cleaning rules for a given home directory.
/// Home is injectable so tests can point the whole engine at a fixture tree.
public enum RuleCatalog {

    public static func rules(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeSystemDomain: Bool = true
    ) -> [CleaningRule] {
        let lib = home.appending(path: "Library")
        var rules: [CleaningRule] = []

        // MARK: System junk (user domain)

        rules.append(CleaningRule(
            id: "user-caches",
            category: .systemJunk,
            title: "App caches",
            detail: "Per-app caches in ~/Library/Caches. Apps rebuild these on demand.",
            paths: [lib.appending(path: "Caches")],
            excludeNames: ["com.apple.bird", "cloudkit", "com.apple.cloudkit", "com.apple.fileprovider", "homebrew"],
            minAgeDays: 0,
            skipRunningApps: true,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "user-logs",
            category: .systemJunk,
            title: "Logs & diagnostics",
            detail: "App logs, diagnostic and crash reports in ~/Library/Logs.",
            paths: [lib.appending(path: "Logs")],
            minAgeDays: 3,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "saved-state",
            category: .systemJunk,
            title: "Saved window states",
            detail: "Window restoration snapshots for apps you haven't opened lately.",
            paths: [lib.appending(path: "Saved Application State")],
            minAgeDays: 7,
            skipRunningApps: true,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "crash-reporter",
            category: .systemJunk,
            title: "Crash reporter data",
            detail: "Old crash-reporter bookkeeping.",
            paths: [lib.appending(path: "Application Support/CrashReporter")],
            minAgeDays: 0,
            tier: .safe
        ))
        if let userCacheDir = darwinUserDirectory(kind: "C") {
            rules.append(CleaningRule(
                id: "quicklook-thumbnails",
                category: .systemJunk,
                title: "QuickLook thumbnails",
                detail: "Preview thumbnail cache. Rebuilt automatically.",
                paths: [URL(fileURLWithPath: userCacheDir).appending(path: "com.apple.QuickLook.thumbnailcache")],
                contentsOnly: false,
                minAgeDays: 0,
                tier: .safe
            ))
        }
        if let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"], !tmpDir.isEmpty {
            rules.append(CleaningRule(
                id: "user-temp",
                category: .systemJunk,
                title: "Temporary files",
                detail: "Old files in the per-user temporary folder. Apps that are running may still use recent ones.",
                paths: [URL(fileURLWithPath: tmpDir)],
                minAgeDays: 3,
                tier: .review
            ))
        }

        // MARK: Browsers (cache only — never profiles, cookies, history)

        rules.append(CleaningRule(
            id: "browser-caches",
            category: .browsers,
            title: "Browser caches",
            detail: "Disk caches of installed browsers. Pages reload from the network.",
            paths: [
                lib.appending(path: "Caches/com.apple.Safari"),
                lib.appending(path: "Containers/com.apple.Safari/Data/Library/Caches"),
                lib.appending(path: "Caches/Google/Chrome"),
                lib.appending(path: "Caches/Firefox"),
                lib.appending(path: "Caches/Arc"),
                lib.appending(path: "Caches/company.thebrowser.Browser"),
                lib.appending(path: "Caches/Microsoft Edge"),
                lib.appending(path: "Caches/BraveSoftware"),
                lib.appending(path: "Caches/Vivaldi"),
                lib.appending(path: "Caches/com.operasoftware.Opera"),
            ],
            contentsOnly: false,
            minAgeDays: 0,
            skipRunningApps: true,
            tier: .safe,
            requiresFullDiskAccess: true
        ))

        // MARK: Developer junk

        let dev = lib.appending(path: "Developer")
        rules.append(CleaningRule(
            id: "xcode-derived-data",
            category: .developer,
            title: "Xcode derived data",
            detail: "Per-project build caches. Xcode rebuilds them on next build.",
            paths: [dev.appending(path: "Xcode/DerivedData")],
            minAgeDays: 7,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "xcode-archives",
            category: .developer,
            title: "Xcode archives",
            detail: "App archives from past releases. Only remove ones you no longer need.",
            paths: [dev.appending(path: "Xcode/Archives")],
            minAgeDays: 60,
            tier: .review
        ))
        rules.append(CleaningRule(
            id: "xcode-device-support",
            category: .developer,
            title: "Device support files",
            detail: "Debug symbols for old iOS/watchOS versions. Re-synced when a device connects.",
            paths: [
                dev.appending(path: "Xcode/iOS DeviceSupport"),
                dev.appending(path: "Xcode/watchOS DeviceSupport"),
                dev.appending(path: "Xcode/tvOS DeviceSupport"),
            ],
            minAgeDays: 90,
            tier: .review
        ))
        rules.append(CleaningRule(
            id: "simulator-caches",
            category: .developer,
            title: "Simulator caches",
            detail: "CoreSimulator cache data.",
            paths: [dev.appending(path: "CoreSimulator/Caches")],
            minAgeDays: 7,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "js-package-caches",
            category: .developer,
            title: "JavaScript package caches",
            detail: "npm, Yarn and Bun download caches. Packages re-download on demand.",
            paths: [
                home.appending(path: ".npm/_cacache"),
                lib.appending(path: "Caches/Yarn"),
                home.appending(path: ".yarn/berry/cache"),
                home.appending(path: ".bun/install/cache"),
                lib.appending(path: "Caches/deno"),
            ],
            contentsOnly: false,
            minAgeDays: 14,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "pnpm-store",
            category: .developer,
            title: "pnpm store",
            detail: "Content-addressable package store. Safe, but every project re-downloads on next install.",
            paths: [lib.appending(path: "pnpm/store"), home.appending(path: ".pnpm-store")],
            contentsOnly: false,
            minAgeDays: 30,
            tier: .review
        ))
        rules.append(CleaningRule(
            id: "python-caches",
            category: .developer,
            title: "Python caches",
            detail: "pip and uv wheel caches.",
            paths: [
                lib.appending(path: "Caches/pip"),
                lib.appending(path: "Caches/uv"),
                home.appending(path: ".cache/pip"),
                home.appending(path: ".cache/uv"),
            ],
            contentsOnly: false,
            minAgeDays: 14,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "rust-cargo-cache",
            category: .developer,
            title: "Cargo registry cache",
            detail: "Downloaded crate archives. Cargo re-fetches what a build needs.",
            paths: [home.appending(path: ".cargo/registry/cache")],
            contentsOnly: false,
            minAgeDays: 30,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "go-build-cache",
            category: .developer,
            title: "Go build cache",
            paths: [lib.appending(path: "Caches/go-build")],
            contentsOnly: false,
            minAgeDays: 14,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "jvm-caches",
            category: .developer,
            title: "Gradle & Maven caches",
            detail: "Dependency caches. Large builds will re-download on next run.",
            paths: [home.appending(path: ".gradle/caches"), home.appending(path: ".m2/repository")],
            contentsOnly: false,
            minAgeDays: 30,
            tier: .review
        ))
        rules.append(CleaningRule(
            id: "cocoapods-cache",
            category: .developer,
            title: "CocoaPods cache",
            paths: [lib.appending(path: "Caches/CocoaPods")],
            contentsOnly: false,
            minAgeDays: 30,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "swiftpm-cache",
            category: .developer,
            title: "Swift Package Manager cache",
            paths: [lib.appending(path: "Caches/org.swift.swiftpm")],
            contentsOnly: false,
            minAgeDays: 14,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "homebrew-cache",
            category: .developer,
            title: "Homebrew downloads",
            detail: "Cached bottle downloads. Homebrew re-fetches on demand.",
            paths: [lib.appending(path: "Caches/Homebrew")],
            minAgeDays: 14,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "mole-cache",
            category: .developer,
            title: "mole cache",
            detail: "Cache from the mole cleanup tool. Regenerated on next run.",
            paths: [home.appending(path: ".cache/mole")],
            contentsOnly: false,
            minAgeDays: 7,
            tier: .safe
        ))

        // MARK: Code editors (Cursor, VS Code) — Electron caches, never user state

        let cursorSupport = lib.appending(path: "Application Support/Cursor")
        rules.append(CleaningRule(
            id: "cursor-caches",
            category: .developer,
            title: "Cursor caches",
            detail: "Cursor's regenerable disk caches. Not your settings, chats or extensions.",
            paths: [
                cursorSupport.appending(path: "Cache"),
                cursorSupport.appending(path: "CachedData"),
                cursorSupport.appending(path: "Code Cache"),
                cursorSupport.appending(path: "GPUCache"),
                cursorSupport.appending(path: "CachedExtensionVSIXs"),
                cursorSupport.appending(path: "Service Worker/CacheStorage"),
                cursorSupport.appending(path: "logs"),
            ],
            contentsOnly: false,
            minAgeDays: 3,
            skipRunningApps: true,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "cursor-db-backup",
            category: .developer,
            title: "Cursor state backup",
            detail: "Stale backup of Cursor's state database. Cursor rewrites it; your live data is untouched.",
            paths: [cursorSupport.appending(path: "User/globalStorage/state.vscdb.backup")],
            contentsOnly: false,
            minAgeDays: 1,
            skipRunningApps: true,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "cursor-workspace-storage",
            category: .developer,
            title: "Cursor workspace history",
            detail: "Per-workspace state and local history. Regenerable, but you may lose local file history.",
            paths: [
                cursorSupport.appending(path: "User/workspaceStorage"),
                cursorSupport.appending(path: "User/History"),
            ],
            contentsOnly: false,
            minAgeDays: 14,
            skipRunningApps: true,
            tier: .review
        ))
        let codeSupport = lib.appending(path: "Application Support/Code")
        rules.append(CleaningRule(
            id: "vscode-caches",
            category: .developer,
            title: "VS Code caches",
            detail: "VS Code's regenerable disk caches.",
            paths: [
                codeSupport.appending(path: "Cache"),
                codeSupport.appending(path: "CachedData"),
                codeSupport.appending(path: "Code Cache"),
                codeSupport.appending(path: "GPUCache"),
                codeSupport.appending(path: "logs"),
            ],
            contentsOnly: false,
            minAgeDays: 3,
            skipRunningApps: true,
            tier: .safe
        ))

        // MARK: Electron app caches — only the cache subfolders, never user data

        let electronApps = ["Notion", "Slack", "discord", "Microsoft Teams", "obsidian", "Figma", "Linear", "Spotify"]
        let electronCacheSubdirs = ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"]
        var electronPaths: [URL] = []
        for app in electronApps {
            let base = lib.appending(path: "Application Support/\(app)")
            for sub in electronCacheSubdirs {
                electronPaths.append(base.appending(path: sub))
            }
        }
        rules.append(CleaningRule(
            id: "electron-app-caches",
            category: .developer,
            title: "Desktop app caches",
            detail: "Web caches from Electron apps (Notion, Slack, Discord…). Never their local data or documents.",
            paths: electronPaths,
            contentsOnly: false,
            minAgeDays: 7,
            skipRunningApps: true,
            tier: .safe
        ))
        rules.append(CleaningRule(
            id: "claude-desktop-vm-bundles",
            category: .developer,
            title: "Claude local-agent VM images",
            detail: "Downloaded VM images for Claude Desktop's local agent. Re-downloaded when needed.",
            paths: [lib.appending(path: "Application Support/Claude/vm_bundles")],
            contentsOnly: false,
            minAgeDays: 7,
            tier: .review
        ))

        // MARK: Mobile toolchains (Android emulators & SDK)

        rules.append(CleaningRule(
            id: "android-avd",
            category: .developer,
            title: "Android emulators",
            detail: "Android Virtual Devices. Each is a full emulator instance you can recreate in Android Studio.",
            paths: [home.appending(path: ".android/avd")],
            contentsOnly: true,
            extensions: ["avd"],
            minAgeDays: 0,
            tier: .review
        ))
        rules.append(CleaningRule(
            id: "android-sdk-images",
            category: .developer,
            title: "Android SDK images",
            detail: "Downloaded system images and NDK versions. Re-downloadable via the SDK manager.",
            paths: [
                lib.appending(path: "Android/sdk/system-images"),
                lib.appending(path: "Android/sdk/ndk"),
            ],
            contentsOnly: false,
            minAgeDays: 30,
            tier: .review
        ))

        // MARK: Installers

        rules.append(CleaningRule(
            id: "installers",
            category: .installers,
            title: "Installer files",
            detail: "Disk images and installer packages sitting in Downloads.",
            paths: [home.appending(path: "Downloads")],
            extensions: ["dmg", "pkg", "iso", "xip", "mpkg"],
            minAgeDays: 7,
            tier: .review
        ))

        // MARK: Mail & media

        rules.append(CleaningRule(
            id: "mail-downloads",
            category: .mailMedia,
            title: "Mail attachment cache",
            detail: "Attachments Mail has cached locally. Originals stay on the mail server.",
            paths: [lib.appending(path: "Containers/com.apple.mail/Data/Library/Mail Downloads")],
            minAgeDays: 14,
            tier: .review,
            requiresFullDiskAccess: true
        ))
        rules.append(CleaningRule(
            id: "ios-backups",
            category: .mailMedia,
            title: "iPhone & iPad backups",
            detail: "Full device backups. Only remove backups of devices you no longer own or back up elsewhere.",
            paths: [lib.appending(path: "Application Support/MobileSync/Backup")],
            minAgeDays: 0,
            tier: .explicitOnly
        ))

        // MARK: Orphan tool dotfiles (stale only)

        rules.append(CleaningRule(
            id: "home-tool-dotfiles",
            category: .appLeftovers,
            title: "Stale tool folders",
            detail: "Home-folder state from dev tools you may no longer use. Only shown when untouched for a month.",
            paths: [
                home.appending(path: ".codeium"),
                home.appending(path: ".antigravity"),
                home.appending(path: ".agents"),
                home.appending(path: ".cagent"),
                home.appending(path: ".aspnet"),
            ],
            contentsOnly: false,
            minAgeDays: 30,
            tier: .review
        ))

        // MARK: Trash

        rules.append(CleaningRule(
            id: "trash",
            category: .trash,
            title: "Trash",
            detail: "Emptying the Trash removes these permanently.",
            paths: [home.appending(path: ".Trash")],
            minAgeDays: 0,
            tier: .safe,
            forcePermanent: true
        ))

        // MARK: System domain (privileged, permanent)

        if includeSystemDomain {
            rules.append(CleaningRule(
                id: "system-caches",
                category: .systemDomain,
                title: "System caches",
                detail: "Machine-wide caches in /Library/Caches. Removed permanently with administrator access.",
                paths: [URL(fileURLWithPath: "/Library/Caches")],
                excludeNames: ["com.apple.aned", "com.apple.iconservices.store"],
                minAgeDays: 14,
                tier: .review,
                domain: .system,
                forcePermanent: true
            ))
            rules.append(CleaningRule(
                id: "system-logs",
                category: .systemDomain,
                title: "System logs",
                detail: "Machine-wide logs in /Library/Logs.",
                paths: [URL(fileURLWithPath: "/Library/Logs")],
                minAgeDays: 7,
                tier: .review,
                domain: .system,
                forcePermanent: true
            ))
            rules.append(CleaningRule(
                id: "var-log",
                category: .systemDomain,
                title: "Unix log files",
                detail: "Rotated log files in /var/log. Folders are preserved.",
                paths: [URL(fileURLWithPath: "/private/var/log")],
                filesOnly: true,
                minAgeDays: 7,
                tier: .review,
                domain: .system,
                forcePermanent: true
            ))
        }

        return rules
    }

    /// Rules eligible for background auto-trim: Safe tier, user domain, with
    /// the age gate raised to `minAgeDays` (default 30) and the Trash category
    /// excluded (emptying the Trash behind the user's back is out of bounds).
    public static func autoTrimRules(home: URL = FileManager.default.homeDirectoryForCurrentUser, minAgeDays: Int) -> [CleaningRule] {
        rules(home: home, includeSystemDomain: false)
            .filter { $0.tier == .safe && $0.domain == .user && $0.category != .trash && !$0.forcePermanent }
            .map { rule in
                CleaningRule(
                    id: rule.id,
                    category: rule.category,
                    title: rule.title,
                    detail: rule.detail,
                    paths: rule.paths,
                    contentsOnly: rule.contentsOnly,
                    filesOnly: rule.filesOnly,
                    extensions: rule.extensions,
                    excludeNames: rule.excludeNames,
                    minAgeDays: max(rule.minAgeDays, minAgeDays),
                    skipRunningApps: true,
                    tier: rule.tier,
                    domain: rule.domain,
                    requiresFullDiskAccess: rule.requiresFullDiskAccess,
                    forcePermanent: rule.forcePermanent
                )
            }
    }

    /// Per-user darwin directory (confstr): kind "C" = cache, "T" = temp.
    private static func darwinUserDirectory(kind: String) -> String? {
        guard let tmp = ProcessInfo.processInfo.environment["TMPDIR"], tmp.contains("/T") else { return nil }
        // TMPDIR is .../<hash>/T/ — the cache sibling lives at .../<hash>/C/
        let base = (tmp as NSString).standardizingPath
        guard base.hasSuffix("/T") else { return nil }
        let parent = (base as NSString).deletingLastPathComponent
        let dir = parent + "/" + kind
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }
}
