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
        "brave-browser": "com.brave.browser",
        "vivaldi": "com.vivaldi.vivaldi",
        "code": "com.microsoft.vscode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "claude": "com.anthropic.claudefordesktop",
        "notion": "notion.id",
        "slack": "com.tinyspeck.slackmacgap",
        "discord": "com.hnc.discord",
        "microsoft teams": "com.microsoft.teams2",
        "obsidian": "md.obsidian",
        "figma": "com.figma.desktop",
        "spotify": "com.spotify.client",
        "linear": "com.linear",
        // Compiler module caches are owned by Xcode's toolchain.
        "clang": "com.apple.dt.xcode",
        "yarn": "",
        "homebrew": "",
    ]

    /// `running` = lowercased bundle ids; `names` = lowercased localized app
    /// names (Electron apps store data under their display name, e.g.
    /// "Notion", not their bundle id, so a name match is the only reliable
    /// signal for them).
    public static func isOwnedByRunningApp(_ url: URL, running: Set<String>, names: Set<String> = []) -> Bool {
        guard !running.isEmpty || !names.isEmpty else { return false }
        let lowered = Set(running.map { $0.lowercased() })
        let loweredNames = Set(names.map { $0.lowercased() })

        for component in url.pathComponents.reversed() {
            var name = component.lowercased()
            if name.hasSuffix(".savedstate") { name = String(name.dropLast(11)) }
            if name.hasSuffix(".binarycookies") { name = String(name.dropLast(14)) }
            if lowered.contains(name) { return true }
            if loweredNames.contains(name) { return true }
            if let mapped = nameToBundleID[name], !mapped.isEmpty, lowered.contains(mapped) {
                return true
            }
        }
        return false
    }
}
