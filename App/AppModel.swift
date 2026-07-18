import SwiftUI
import AppKit
import SweepCore
import UserNotifications

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case smartClean
    case memory
    case uninstaller
    case largeFiles
    case aiModels
    case devCleaner
    case optimize
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .smartClean: "Smart Clean"
        case .memory: "Memory"
        case .uninstaller: "Apps"
        case .largeFiles: "Large Files"
        case .aiModels: "AI Models"
        case .devCleaner: "Dev Cleaner"
        case .optimize: "Optimize"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .smartClean: "sparkles"
        case .memory: "memorychip"
        case .uninstaller: "square.grid.2x2"
        case .largeFiles: "doc.badge.clock"
        case .aiModels: "brain"
        case .devCleaner: "hammer"
        case .optimize: "wand.and.stars"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    /// The live app model, so non-SwiftUI entry points (the Finder service via
    /// `AppDelegate`) can reach it. Held strongly by `SweepApp`'s `@State`.
    /// (Static — not tracked by `@Observable`, which only tracks instance state.)
    static private(set) weak var shared: AppModel?

    let settings = SettingsStore.shared
    let broker = PrivilegeBroker()
    let history = HistoryStore.shared
    let policy = SafetyPolicy()

    let smartClean: SmartCleanModel
    let memory = MemoryModel()
    let uninstaller = UninstallerModel()
    let largeFiles = LargeFilesModel()
    let aiModels = AIModelsModel()
    let devCleaner = DevCleanerModel()
    let optimize = OptimizeModel()
    let updater: UpdateChecker

    var section: AppSection = .dashboard
    var fullDiskAccess = false
    /// Set by the Finder "Uninstall with Sweep" service; `RootView` consumes it
    /// once the window is up and routes to the uninstaller.
    var pendingExternalUninstall: URL?
    var disk: DiskSnapshot?
    var lifetimeFreed: Int64 = 0
    var lastClean: Date?
    /// True while a manual "Run auto-trim now" is in flight. Observed by the UI;
    /// `AutoTrimScheduler` isn't `@Observable`, so its own `running` flag can't
    /// drive SwiftUI directly.
    private(set) var autoTrimRunning = false

    private var autoTrim: AutoTrimScheduler?
    private var bootstrapped = false

    init() {
        smartClean = SmartCleanModel()
        updater = UpdateChecker(settings: settings)
        AppModel.shared = self
    }

    /// Entry point for the Finder service: validate the bundle, route the UI to
    /// the uninstaller, and bring a window forward (Sweep may be menu-bar only).
    func handleExternalUninstall(url: URL) {
        guard UninstallGuard.mayRemoveAppBundle(url) else { return }
        pendingExternalUninstall = url
        section = .uninstaller
        // Only reopen if the main window is gone (menu-bar-only state); otherwise
        // `RootView.onChange` picks up the pending URL in the existing window.
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !hasVisibleWindow { WindowOpener.shared.open?("main") }
        NSApp.activate(ignoringOtherApps: true)
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        checkFullDiskAccess()
        refreshDisk()
        broker.refreshHelperState()
        memory.startSampling()
        await refreshHistorySummary()

        let scheduler = AutoTrimScheduler(model: self)
        autoTrim = scheduler
        scheduler.start()

        // Quietly check for an app update in the background (only if the user has
        // stored a token and left auto-check on). Errors stay silent here.
        if settings.autoUpdateCheckEnabled, GitHubTokenStore.hasToken {
            Task { await updater.check(manual: false) }
        }
    }

    func refreshDisk() {
        disk = DiskStats.root()
    }

    /// Runs an auto-trim immediately (same Safe-tier, Trash-first pass the
    /// scheduler performs). The scheduler logs to History and refreshes stats.
    func runAutoTrimNow() async {
        guard let autoTrim, !autoTrimRunning else { return }
        autoTrimRunning = true
        defer { autoTrimRunning = false }
        await autoTrim.run(reason: "manual")
    }

    func refreshHistorySummary() async {
        lifetimeFreed = await history.lifetimeFreed()
        lastClean = await history.lastCleanDate()
    }

    /// Full Disk Access probe: the per-user TCC database is unreadable without
    /// the FDA grant, regardless of POSIX permissions.
    func checkFullDiskAccess() {
        let probes = [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        fullDiskAccess = probes.contains { path in
            FileManager.default.fileExists(atPath: path) && FileHandle(forReadingAtPath: path) != nil
        }
    }

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    var lowDiskSpace: Bool {
        guard let disk else { return false }
        // Compare against space including reclaimable purgeable (the figure macOS
        // itself calls "available for important usage"). The honest `available`
        // shown in the UI is lower; using it here would fire auto-trim whenever
        // purgeable space is high even though the disk isn't really full.
        return disk.opportunisticAvailable < Int64(settings.lowDiskThresholdGB) * 1_000_000_000
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
