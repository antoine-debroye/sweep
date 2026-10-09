import Foundation

/// The background jobs an app runs — login-item helpers, bundled agents, its
/// launch agents — and stopping them before the app is removed.
///
/// Without this an uninstall fails half-way: the helper keeps executing from
/// inside the bundle, the open-handle gate (rightly) refuses to trash a bundle
/// that is in use, and the user is left with "still in use" and no idea what
/// is using it. Or, for an agent whose plist is trashed, launchd keeps the job
/// loaded until logout.
public enum AppBackgroundJobs {

    /// launchd labels the app provably owns:
    /// - each login-item helper in `Contents/Library/LoginItems` (its bundle id
    ///   is its label),
    /// - each agent plist the bundle ships in `Contents/Library/LaunchAgents`
    ///   (registered through SMAppService),
    /// - the `Label` of each launch-agent plist being removed with it.
    /// Apple's own labels are never included.
    public static func ownedLabels(appURL: URL, removingAgentPlists agents: [URL]) -> [String] {
        let fm = FileManager()
        var labels: [String] = []

        let loginItems = appURL.appending(path: "Contents/Library/LoginItems")
        for helper in (try? fm.contentsOfDirectory(at: loginItems, includingPropertiesForKeys: nil)) ?? []
        where helper.pathExtension == "app" {
            if let id = Bundle(url: helper)?.bundleIdentifier { labels.append(id) }
        }

        let bundled = appURL.appending(path: "Contents/Library/LaunchAgents")
        let bundledPlists = ((try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "plist" }
        for plist in bundledPlists + agents {
            if let label = label(of: plist) { labels.append(label) }
        }

        var seen = Set<String>()
        return labels.filter { !$0.lowercased().hasPrefix("com.apple.") && seen.insert($0).inserted }
    }

    static func label(of plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["Label"] as? String
    }

    /// Executables currently running from inside the bundle.
    public static func processesInside(_ appURL: URL, running: Set<String> = RunningProcesses.executablePaths()) -> [String] {
        let prefix = SafetyPolicy.canonical(appURL.path) + "/"
        return running.filter { SafetyPolicy.canonical($0).hasPrefix(prefix) }.sorted()
    }

    public typealias Launchctl = @Sendable (_ arguments: [String]) async -> ProcessResult

    public static let defaultLaunchctl: Launchctl = { arguments in
        await ProcessRunner.run("/bin/launchctl", arguments, timeout: 10)
    }

    /// Stops every label that is loaded in this user's GUI session. Labels
    /// that aren't loaded are skipped; a failure is reported, not retried.
    public static func stop(
        labels: [String],
        uid: uid_t = getuid(),
        launchctl: Launchctl = defaultLaunchctl
    ) async -> (stopped: [String], failed: [String]) {
        var stopped: [String] = []
        var failed: [String] = []
        for label in labels {
            let target = "gui/\(uid)/\(label)"
            guard await launchctl(["print", target]).status == 0 else { continue }
            if await launchctl(["bootout", target]).status == 0 {
                stopped.append(label)
            } else {
                failed.append(label)
            }
        }
        return (stopped, failed)
    }
}
