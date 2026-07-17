import SwiftUI
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

    var section: AppSection = .dashboard
    var fullDiskAccess = false
    var disk: DiskSnapshot?
    var lifetimeFreed: Int64 = 0
    var lastClean: Date?

    private var autoTrim: AutoTrimScheduler?
    private var bootstrapped = false

    init() {
        smartClean = SmartCleanModel()
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
    }

    func refreshDisk() {
        disk = DiskStats.root()
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
        return disk.available < Int64(settings.lowDiskThresholdGB) * 1_000_000_000
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
