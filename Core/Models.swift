import Foundation

// MARK: - Categories

public enum CleanCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case systemJunk
    case browsers
    case developer
    case projectArtifacts
    case appLeftovers
    case installers
    case mailMedia
    case systemDomain
    case trash
    case largeFiles
    case aiModels

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemJunk: "System Junk"
        case .browsers: "Browser Caches"
        case .developer: "Developer Junk"
        case .projectArtifacts: "Project Artifacts"
        case .appLeftovers: "App Leftovers"
        case .installers: "Installers"
        case .mailMedia: "Mail & Media"
        case .systemDomain: "System Files"
        case .trash: "Trash"
        case .largeFiles: "Large Files"
        case .aiModels: "AI Models"
        }
    }

    public var symbol: String {
        switch self {
        case .systemJunk: "internaldrive"
        case .browsers: "safari"
        case .developer: "hammer"
        case .projectArtifacts: "shippingbox"
        case .appLeftovers: "puzzlepiece.extension"
        case .installers: "arrow.down.circle"
        case .mailMedia: "envelope"
        case .systemDomain: "lock.shield"
        case .trash: "trash"
        case .largeFiles: "doc.badge.clock"
        case .aiModels: "brain"
        }
    }

    public var blurb: String {
        switch self {
        case .systemJunk: "Caches, logs, crash reports and saved window states that macOS rebuilds automatically."
        case .browsers: "Web caches from Safari, Chrome, Firefox and friends. Never cookies, history or passwords."
        case .developer: "Xcode derived data, package manager caches, simulator junk."
        case .projectArtifacts: "node_modules, build folders and virtualenvs in projects you haven't touched in a while."
        case .appLeftovers: "Data left behind by apps that are no longer installed."
        case .installers: "Old .dmg, .pkg and archive files sitting in Downloads and Desktop."
        case .mailMedia: "Mail attachment caches and old device backups."
        case .systemDomain: "System-level caches and logs. Needs administrator access; removed permanently."
        case .trash: "Files already in your Trash."
        case .largeFiles: "Big files you reviewed and removed yourself."
        case .aiModels: "Local LLM and ML models from Ollama, LM Studio and Hugging Face. Re-downloadable."
        }
    }

    /// Presentation order in scan results.
    public var sortOrder: Int {
        switch self {
        case .systemJunk: 0
        case .browsers: 1
        case .developer: 2
        case .projectArtifacts: 3
        case .installers: 4
        case .appLeftovers: 5
        case .mailMedia: 6
        case .trash: 7
        case .systemDomain: 8
        case .largeFiles: 9
        case .aiModels: 10
        }
    }
}

// MARK: - Safety tiers

public enum SafetyTier: String, Codable, Sendable, Comparable {
    /// Regenerable junk. Pre-selected in the UI, eligible for auto-trim.
    case safe
    /// Regenerable but with a cost (re-downloads, re-indexing) or heuristic
    /// matches. Never pre-selected, never auto-trimmed.
    case review
    /// Meaningful data (device backups, app uninstalls). Only cleaned through
    /// a dedicated, explicit flow.
    case explicitOnly

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .explicitOnly: "Explicit"
        }
    }

    private var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .explicitOnly: 2
        }
    }

    public static func < (lhs: SafetyTier, rhs: SafetyTier) -> Bool { lhs.rank < rhs.rank }
}

public enum RuleDomain: String, Codable, Sendable {
    /// Files owned by the current user; cleaned directly, Trash-first.
    case user
    /// Root-owned locations; cleaned through the privileged helper, permanently.
    case system
}

// MARK: - Appearance

/// The window appearance the user has chosen. `system` follows macOS; the App
/// layer maps this to a SwiftUI `ColorScheme?` (`system` → `nil`). Kept here,
/// free of SwiftUI, so `Core` — including `SettingsStore` — stays UI-agnostic.
public enum AppAppearance: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

// MARK: - Rules

public struct CleaningRule: Sendable, Identifiable {
    public let id: String
    public let category: CleanCategory
    public let title: String
    public let detail: String
    /// Absolute locations this rule covers. Missing paths are skipped silently.
    public let paths: [URL]
    /// true → each child of the path becomes a scan item (the folder itself is
    /// never deleted). false → the path itself is a single scan item.
    public let contentsOnly: Bool
    /// With contentsOnly, include only regular files (used for /var/log where
    /// daemons expect their subdirectories to survive).
    public let filesOnly: Bool
    /// With contentsOnly, restrict children to these lowercase extensions.
    public let extensions: Set<String>?
    /// Child names (exact, case-insensitive) that are never offered.
    public let excludeNames: Set<String>
    /// An item is only offered when nothing inside it was modified in the last
    /// N days. 0 disables the gate.
    public let minAgeDays: Int
    /// Items smaller than this are not worth a row (keeps sweeps over hundreds
    /// of sandbox scratch folders from flooding the results). 0 = no floor.
    public let minItemBytes: Int64
    /// Skip items that belong to an app that is currently running (cache and
    /// saved-state folders named after the app's bundle id).
    public let skipRunningApps: Bool
    public let tier: SafetyTier
    public let domain: RuleDomain
    public let requiresFullDiskAccess: Bool
    /// Items are removed permanently even in Trash-first mode (used for the
    /// Trash category itself and for system-domain paths).
    public let forcePermanent: Bool

    public init(
        id: String,
        category: CleanCategory,
        title: String,
        detail: String = "",
        paths: [URL],
        contentsOnly: Bool = true,
        filesOnly: Bool = false,
        extensions: Set<String>? = nil,
        excludeNames: Set<String> = [],
        minAgeDays: Int = 0,
        minItemBytes: Int64 = 0,
        skipRunningApps: Bool = false,
        tier: SafetyTier,
        domain: RuleDomain = .user,
        requiresFullDiskAccess: Bool = false,
        forcePermanent: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.paths = paths
        self.contentsOnly = contentsOnly
        self.filesOnly = filesOnly
        self.extensions = extensions
        self.excludeNames = Set(excludeNames.map { $0.lowercased() })
        self.minAgeDays = minAgeDays
        self.minItemBytes = minItemBytes
        self.skipRunningApps = skipRunningApps
        self.tier = tier
        self.domain = domain
        self.requiresFullDiskAccess = requiresFullDiskAccess
        self.forcePermanent = forcePermanent
    }
}

// MARK: - Scan results

public struct ScanItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let ruleID: String
    public let category: CleanCategory
    public let url: URL
    public let displayName: String
    public let detail: String
    public let size: Int64
    public let fileCount: Int
    public let newestModification: Date?
    public let tier: SafetyTier
    public let domain: RuleDomain
    public let forcePermanent: Bool
    /// Display-only cluster key. Items that belong to the same uninstalled app
    /// (its Application Support folder, caches, preferences, …) share one key so
    /// the UI can show them as a single collapsible unit. `nil` everywhere else.
    /// Selection and cleaning stay strictly per-path — `id` is unaffected.
    public let group: String?
    /// Identity of the object as scanned. `Cleaner` refuses to delete a path
    /// whose identity no longer matches, so a rename-and-recreate between the
    /// scan and the click cannot redirect the deletion onto something new.
    public let identity: FileIdentity?

    public init(
        ruleID: String,
        category: CleanCategory,
        url: URL,
        displayName: String,
        detail: String,
        size: Int64,
        fileCount: Int,
        newestModification: Date?,
        tier: SafetyTier,
        domain: RuleDomain,
        forcePermanent: Bool = false,
        group: String? = nil,
        identity: FileIdentity? = nil
    ) {
        self.id = ruleID + "|" + url.path
        self.ruleID = ruleID
        self.category = category
        self.url = url
        self.displayName = displayName
        self.detail = detail
        self.size = size
        self.fileCount = fileCount
        self.newestModification = newestModification
        self.tier = tier
        self.domain = domain
        self.forcePermanent = forcePermanent
        self.group = group
        self.identity = identity
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: ScanItem, rhs: ScanItem) -> Bool { lhs.id == rhs.id }
}

public struct ScanReport: Sendable {
    public let items: [ScanItem]
    public let startedAt: Date
    public let duration: TimeInterval

    public init(items: [ScanItem], startedAt: Date, duration: TimeInterval) {
        self.items = items
        self.startedAt = startedAt
        self.duration = duration
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    public func items(in category: CleanCategory) -> [ScanItem] {
        items.filter { $0.category == category }.sorted { $0.size > $1.size }
    }

    public var categories: [CleanCategory] {
        Array(Set(items.map(\.category))).sorted { $0.sortOrder < $1.sortOrder }
    }
}

public enum ScanEvent: Sendable {
    case categoryStarted(CleanCategory)
    case item(ScanItem)
    case categoryFinished(CleanCategory)
    case finished(ScanReport)
}

// MARK: - Clean sessions (history / undo)

public enum CleanSource: String, Codable, Sendable {
    case smartScan
    case autoTrim
    case uninstall
    case largeFiles
    case devCleaner
    case menuBar
    case aiModels
    case diskExplorer

    public var label: String {
        switch self {
        case .smartScan: "Smart Clean"
        case .autoTrim: "Auto-Trim"
        case .uninstall: "Uninstall"
        case .largeFiles: "Large Files"
        case .devCleaner: "Dev Cleaner"
        case .menuBar: "Quick Clean"
        case .aiModels: "AI Models"
        case .diskExplorer: "Disk Explorer"
        }
    }
}

public struct CleanedItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public let originalPath: String
    /// Location in the Trash, when Trash-first was used. nil → permanent.
    public var trashPath: String?
    public let size: Int64
    public let displayName: String
    public let category: CleanCategory

    public init(originalPath: String, trashPath: String?, size: Int64, displayName: String, category: CleanCategory) {
        self.id = UUID()
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.size = size
        self.displayName = displayName
        self.category = category
    }
}

public struct CleanSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let source: CleanSource
    public var items: [CleanedItem]
    public let errors: [String]
    public var undone: Bool

    public init(date: Date, source: CleanSource, items: [CleanedItem], errors: [String]) {
        self.id = UUID()
        self.date = date
        self.source = source
        self.items = items
        self.errors = errors
        self.undone = false
    }

    public var totalFreed: Int64 { items.reduce(0) { $0 + $1.size } }
    public var restorableCount: Int { items.filter { $0.trashPath != nil }.count }
}
