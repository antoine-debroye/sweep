import Foundation

/// Identity-based protection, as opposed to the path-based protection in
/// `SafetyPolicy`.
///
/// Some software must not be touched because of *what it is*, not where it
/// lives. Three distinct classes, because they need three different answers:
///
///  - **Security agents** (EDR, MDM, VPN posture clients). Removing these
///    breaks a managed Mac's compliance and can lock the user out of corporate
///    resources; several also reinstall themselves and leave a half-configured
///    system behind. They must be removed through the vendor's tool or the MDM,
///    never by a cleaner.
///  - **Data-sensitive apps** whose *data* is irreplaceable even though the app
///    itself is replaceable — password managers (local vaults, recovery keys)
///    and input methods (a learned dictionary built over years). Uninstalling
///    the app is the user's call; sweeping its data as "leftovers" is not.
///  - **System-critical bundles** that are not Apple-signed but keep the
///    machine usable.
public enum BundleProtection {

    /// Endpoint security, device management and network posture agents.
    public static let securityAgentPrefixes: [String] = [
        "com.crowdstrike.",
        "com.sentinelone.", "com.sentinel-labs.",
        "com.eset.",
        "com.jamf.", "com.jamfsoftware.",
        "com.paloaltonetworks.",
        "com.cisco.anyconnect", "com.cisco.secureclient",
        "com.microsoft.wdav",          // Defender for Endpoint
        "com.sophos.",
        "com.mcafee.", "com.trellix.",
        "com.carbonblack.", "com.vmware.carbonblack.",
        "com.symantec.", "com.broadcom.",
        "com.trendmicro.",
        "com.kandji.", "com.addigy.", "com.mosyle.", "com.fleetdm.", "io.fleetdm.",
        "com.zscaler.", "com.netskope.",
        "com.okta.mobile", "com.beyondtrust.",
        "com.malwarebytes.",
    ]

    /// Apps whose data must survive a cleanup even when the app is gone.
    /// Patterns support a leading and/or trailing `*`.
    public static let dataSensitivePatterns: [String] = [
        // Password managers and authenticators — a local vault or recovery
        // key is not regenerable.
        "com.1password.*", "com.agilebits.*",
        "com.bitwarden.*", "com.dashlane.*", "com.lastpass.*",
        "com.keepassx.*", "org.keepassx.*", "org.keepassxc.*",
        "com.enpass.*", "in.sinew.*",
        "com.authy.*", "com.yubico.*", "com.stripe.*authenticator*",
        "com.apple.keychainaccess",
        // Input methods — the user's learned dictionary.
        "*.inputmethod", "*.inputmethod.*", "*inputmethod*", "*IME",
        "im.rime.*", "com.googlecode.rimeime.*",
        // Disk encryption / key material.
        "com.veracrypt.*", "org.gnupg.*", "com.gpgtools.*",
        // Local-first notes and databases people would not expect a cleaner
        // to touch.
        "md.obsidian", "com.devonthink.*", "net.shinyfrog.bear",
    ]

    /// Non-Apple bundles the machine depends on.
    public static let systemCriticalPrefixes: [String] = [
        "com.apple.",
        "com.vmware.fusion", "com.parallels.desktop",
        "org.virtualbox.app.virtualbox",
        "com.docker.docker",
    ]

    public static func isSecurityAgent(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return securityAgentPrefixes.contains { id.hasPrefix($0.lowercased()) }
    }

    public static func isSystemCritical(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return systemCriticalPrefixes.contains { id.hasPrefix($0.lowercased()) }
    }

    /// Whether this bundle's *data* is off limits to cleanup.
    public static func isDataSensitive(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return dataSensitivePatterns.contains { matches(pattern: $0.lowercased(), id) }
    }

    /// Whether a folder or file name looks like data belonging to a
    /// data-sensitive app. Used where only a display name is available.
    public static func nameLooksDataSensitive(_ name: String) -> Bool {
        let token = NameToken.normalize(name)
        guard token.count >= 3 else { return false }
        return dataSensitiveNameTokens.contains(token)
    }

    static let dataSensitiveNameTokens: Set<String> = [
        "1password", "onepassword", "agilebits", "bitwarden", "dashlane", "lastpass",
        "keepassx", "keepassxc", "enpass", "authy", "yubico", "yubikey",
        "keychain", "keychains", "gnupg", "gpg", "gpgtools", "veracrypt",
        "rime", "squirrel", "inputmethod", "obsidian", "devonthink", "bear",
    ]

    /// Glob with optional leading/trailing `*`. Deliberately minimal: a full
    /// pattern engine would be more power than these lists need, and more to
    /// get wrong.
    static func matches(pattern: String, _ id: String) -> Bool {
        let hasPrefixWildcard = pattern.hasPrefix("*")
        let hasSuffixWildcard = pattern.hasSuffix("*")
        var core = pattern
        if hasPrefixWildcard { core.removeFirst() }
        if hasSuffixWildcard, !core.isEmpty { core.removeLast() }
        guard !core.isEmpty else { return true }
        switch (hasPrefixWildcard, hasSuffixWildcard) {
        case (true, true): return id.contains(core)
        case (true, false): return id.hasSuffix(core)
        case (false, true): return id.hasPrefix(core)
        case (false, false): return id == core
        }
    }
}
