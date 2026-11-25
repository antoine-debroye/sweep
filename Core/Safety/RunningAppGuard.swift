import Foundation

/// Decides whether a junk folder belongs to an app that is currently running,
/// so live caches and saved states can be skipped during cleaning.
public enum RunningAppGuard {
    /// Known cache-folder names that don't equal the app's bundle id.
    static let nameToBundleID: [String: String] = [
        "chrome": "com.google.chrome",
        // Each browser channel is its own app with its own data folder. A
        // channel running alone must protect its own caches.
        "chrome beta": "com.google.chrome.beta",
        "chrome dev": "com.google.chrome.dev",
        "chrome canary": "com.google.chrome.canary",
        "chromium": "org.chromium.chromium",
        "firefox": "org.mozilla.firefox",
        "arc": "company.thebrowser.browser",
        "microsoft edge": "com.microsoft.edgemac",
        "microsoft edge beta": "com.microsoft.edgemac.beta",
        "microsoft edge dev": "com.microsoft.edgemac.dev",
        "microsoft edge canary": "com.microsoft.edgemac.canary",
        "brave-browser": "com.brave.browser",
        "brave-browser-beta": "com.brave.browser.beta",
        "brave-browser-nightly": "com.brave.browser.nightly",
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

    /// Vendor folders shared by every channel of a browser (`Google/…`,
    /// `BraveSoftware/…`). Any running channel claims them: the folder above a
    /// channel's data is that channel's data too.
    static let vendorFamilies: [String: String] = [
        "google": "com.google.chrome",
        "bravesoftware": "com.brave.browser",
    ]

    /// Creative Cloud's resident helpers: running whenever Adobe software is
    /// installed, so they cannot count as "an Adobe app is in use".
    static let adobeBackgroundPrefixes = [
        "com.adobe.acc", "com.adobe.ccx", "com.adobe.cclibrary", "com.adobe.ccd",
        "com.adobe.adobecreativecloud", "com.adobe.creativecloud", "com.adobe.agsservice",
        "com.adobe.arm", "com.adobe.coresync", "com.adobe.adobeipc", "com.adobe.adobe_ipc",
        "com.adobe.adobeupdate", "com.adobe.adoberesourcesynchronizer",
    ]

    static func isAdobeApp(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        guard id.hasPrefix("com.adobe.") else { return false }
        return !adobeBackgroundPrefixes.contains { id.hasPrefix($0) }
    }

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
            // Adobe apps share `Caches/Adobe` and each other's `com.adobe.*`
            // caches (Mole I-21/I-26). Any running Adobe app holds them all;
            // Creative Cloud's always-on background agents do not, or the
            // caches could never be cleaned.
            if name == "adobe" || name.hasPrefix("com.adobe.") {
                if lowered.contains(where: isAdobeApp) { return true }
            }
            if let family = vendorFamilies[name],
               lowered.contains(where: { $0 == family || $0.hasPrefix(family + ".") }) {
                return true
            }
        }
        return false
    }
}
