import Foundation
import Observation

/// User-defaults-backed app settings, observable by SwiftUI.
@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore()

    private let defaults: UserDefaults

    public var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }
    public var autoTrimEnabled: Bool { didSet { defaults.set(autoTrimEnabled, forKey: "autoTrimEnabled") } }
    public var autoTrimMinAgeDays: Int { didSet { defaults.set(autoTrimMinAgeDays, forKey: "autoTrimMinAgeDays") } }
    public var autoTrimIntervalHours: Int { didSet { defaults.set(autoTrimIntervalHours, forKey: "autoTrimIntervalHours") } }
    public var lowDiskThresholdGB: Int { didSet { defaults.set(lowDiskThresholdGB, forKey: "lowDiskThresholdGB") } }
    public var permanentDelete: Bool { didSet { defaults.set(permanentDelete, forKey: "permanentDelete") } }
    public var whitelist: [String] { didSet { defaults.set(whitelist, forKey: "whitelist") } }
    public var devFolders: [String] { didSet { defaults.set(devFolders, forKey: "devFolders") } }
    public var lastAutoTrim: Date? { didSet { defaults.set(lastAutoTrim, forKey: "lastAutoTrim") } }
    public var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        self.autoTrimEnabled = defaults.object(forKey: "autoTrimEnabled") as? Bool ?? true
        self.autoTrimMinAgeDays = defaults.object(forKey: "autoTrimMinAgeDays") as? Int ?? 30
        self.autoTrimIntervalHours = defaults.object(forKey: "autoTrimIntervalHours") as? Int ?? 24
        self.lowDiskThresholdGB = defaults.object(forKey: "lowDiskThresholdGB") as? Int ?? 15
        self.permanentDelete = defaults.bool(forKey: "permanentDelete")
        self.whitelist = defaults.stringArray(forKey: "whitelist") ?? []
        self.devFolders = defaults.stringArray(forKey: "devFolders") ?? SettingsStore.detectDevFolders()
        self.lastAutoTrim = defaults.object(forKey: "lastAutoTrim") as? Date
        self.notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    private static func detectDevFolders() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["Developer", "Projects", "Code", "dev", "src", "workspace"]
        return candidates
            .map { home.appending(path: $0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}
