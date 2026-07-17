import Foundation

/// Decides whether a junk folder belongs to an app that is currently running,
/// so live caches and saved states can be skipped during cleaning.
public enum RunningAppGuard {
    /// Known cache-folder names that don't equal the app's bundle id.
    static let nameToBundleID: [String: String] = [
        "chrome": "com.google.chrome",
        "google": "com.google.chrome",
        "firefox": "org.mozilla.firefox",
        "arc": "company.thebrowser.browser",
        "microsoft edge": "com.microsoft.edgemac",
        "bravesoftware": "com.brave.browser",
        "vivaldi": "com.vivaldi.vivaldi",
        "yarn": "",
        "homebrew": "",
    ]

    public static func isOwnedByRunningApp(_ url: URL, running: Set<String>) -> Bool {
        guard !running.isEmpty else { return false }
        let lowered = Set(running.map { $0.lowercased() })

        for component in url.pathComponents.reversed() {
            var name = component.lowercased()
            if name.hasSuffix(".savedstate") { name = String(name.dropLast(11)) }
            if name.hasSuffix(".binarycookies") { name = String(name.dropLast(14)) }
            if lowered.contains(name) { return true }
            if let mapped = nameToBundleID[name], !mapped.isEmpty, lowered.contains(mapped) {
                return true
            }
        }
        return false
    }
}
