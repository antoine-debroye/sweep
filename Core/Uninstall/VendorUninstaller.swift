import Foundation

/// How an app should be removed when Sweep is not the right tool for the job.
public enum UninstallHandoff: Sendable, Equatable {
    /// The vendor ships an uninstaller and Sweep found it on disk.
    case vendorTool(URL, label: String)
    /// Removal has to go through the vendor or the fleet's management, with no
    /// local tool to launch.
    case managedByVendor(vendor: String, guidance: String)

    public var label: String {
        switch self {
        case .vendorTool(_, let label): label
        case .managedByVendor(let vendor, _): "\(vendor) must be removed by its own tooling"
        }
    }
}

/// Finds the vendor's own uninstaller, for suites that cannot be removed by
/// deleting the app bundle.
///
/// This is the answer to the commonest complaint about cleaners: Adobe ships
/// Creative Cloud across `/Applications/Adobe Creative Cloud`,
/// `/Applications/Utilities/Adobe Creative Cloud`, `/Library/Application
/// Support/Adobe` and seven launch items, so trashing an app bundle removes
/// almost none of it and leaves running daemons behind. The vendor's own
/// uninstaller does the whole job; Sweep's job is to find it and get out of
/// the way.
public enum VendorUninstaller {

    /// Suites whose uninstaller is the only correct route, keyed by bundle-id
    /// prefix, with the folder that usually holds the tool.
    static let knownSuites: [(prefix: String, vendor: String)] = [
        ("com.adobe.", "Adobe"),
        ("com.blackmagic-design.", "Blackmagic Design"),
        ("com.microsoft.autoupdate", "Microsoft AutoUpdate"),
        ("com.parallels.", "Parallels"),
        ("com.vmware.", "VMware"),
        ("com.native-instruments.", "Native Instruments"),
        ("com.avid.", "Avid"),
        ("com.waves.", "Waves"),
    ]

    /// Display names for the security vendors, so user-facing text spells the
    /// brand the way the vendor does rather than title-casing a bundle id.
    static let securityVendorNames: [(prefix: String, vendor: String)] = [
        ("com.crowdstrike.", "CrowdStrike"),
        ("com.sentinelone.", "SentinelOne"), ("com.sentinel-labs.", "SentinelOne"),
        ("com.eset.", "ESET"),
        ("com.jamf.", "Jamf"), ("com.jamfsoftware.", "Jamf"),
        ("com.paloaltonetworks.", "GlobalProtect"),
        ("com.cisco.anyconnect", "Cisco Secure Client"),
        ("com.cisco.secureclient", "Cisco Secure Client"),
        ("com.microsoft.wdav", "Microsoft Defender"),
        ("com.sophos.", "Sophos"), ("com.mcafee.", "McAfee"), ("com.trellix.", "Trellix"),
        ("com.carbonblack.", "Carbon Black"), ("com.vmware.carbonblack.", "Carbon Black"),
        ("com.symantec.", "Symantec"), ("com.broadcom.", "Broadcom"),
        ("com.trendmicro.", "Trend Micro"),
        ("com.kandji.", "Kandji"), ("com.addigy.", "Addigy"), ("com.mosyle.", "Mosyle"),
        ("com.fleetdm.", "Fleet"), ("io.fleetdm.", "Fleet"),
        ("com.zscaler.", "Zscaler"), ("com.netskope.", "Netskope"),
        ("com.okta.mobile", "Okta"), ("com.beyondtrust.", "BeyondTrust"),
        ("com.malwarebytes.", "Malwarebytes"),
    ]

    /// Name patterns vendors use for an uninstaller sitting next to the app.
    static let uninstallerNeedles = ["uninstall", "uninstaller", "remove "]

    public static func handoff(for app: InstalledApp) -> UninstallHandoff? {
        // A security agent has no safe local route: removing it is a fleet
        // decision, and the tool to do it is usually the MDM, not something on
        // this disk.
        if BundleProtection.isSecurityAgent(app.bundleID) {
            return .managedByVendor(
                vendor: vendorName(for: app.bundleID) ?? "This security agent",
                guidance: "Security and device-management agents must be removed through the vendor's "
                    + "installer or your MDM. Deleting the app leaves its system extension and daemons "
                    + "behind and can break compliance."
            )
        }
        // Don't hand an uninstaller off to itself.
        let selfName = app.url.deletingPathExtension().lastPathComponent.lowercased()
        let isItselfAnUninstaller = uninstallerNeedles.contains { selfName.contains($0) }
        if !isItselfAnUninstaller, let tool = discoverTool(near: app.url) {
            return .vendorTool(tool, label: "Open \(tool.deletingPathExtension().lastPathComponent)")
        }
        if let vendor = knownSuites.first(where: { app.bundleID.lowercased().hasPrefix($0.prefix) })?.vendor {
            return .managedByVendor(
                vendor: vendor,
                guidance: "\(vendor) installs shared components outside this app bundle. Use \(vendor)'s "
                    + "own uninstaller so its daemons, launch items and shared frameworks go too."
            )
        }
        return nil
    }

    static func vendorName(for bundleID: String) -> String? {
        let id = bundleID.lowercased()
        if let match = securityVendorNames.first(where: { id.hasPrefix($0.prefix) }) { return match.vendor }
        if let match = knownSuites.first(where: { id.hasPrefix($0.prefix) }) { return match.vendor }
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[1].capitalized
    }

    /// Looks for an uninstaller beside the app — i.e. in the vendor folder the
    /// app was installed into, not in `/Applications` itself, where a match
    /// would belong to some unrelated app.
    static func discoverTool(near appURL: URL) -> URL? {
        let parent = appURL.deletingLastPathComponent()
        let canonicalParent = SafetyPolicy.canonical(parent.path)
        guard canonicalParent != "/applications",
              canonicalParent != SafetyPolicy.canonical(
                  FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path
              ) else { return nil }

        let fm = FileManager()
        guard let entries = try? fm.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        for entry in entries {
            let name = entry.lastPathComponent.lowercased()
            guard uninstallerNeedles.contains(where: { name.contains($0) }) else { continue }
            guard let resolved = resolve(entry) else { continue }
            if resolved.pathExtension == "app" || fm.isExecutableFile(atPath: resolved.path) {
                return resolved
            }
        }
        return nil
    }

    /// Vendors point at their uninstaller in three different ways, and all
    /// three turn up on one real machine: `Uninstall Resolve.app` is a plain
    /// bundle, `Uninstall Adobe Creative Cloud` is a symlink into
    /// `/Applications/Utilities`, and `Acrobat Uninstaller` is a macOS **alias
    /// file**, which is neither of the above and needs bookmark resolution.
    static func resolve(_ url: URL) -> URL? {
        let fm = FileManager()
        if url.pathExtension == "app" || fm.isExecutableFile(atPath: url.path) {
            let resolved = url.resolvingSymlinksInPath()
            if fm.fileExists(atPath: resolved.path) { return resolved }
        }
        if let alias = try? URL(resolvingAliasFileAt: url, options: [.withoutUI]),
           fm.fileExists(atPath: alias.path) {
            return alias
        }
        let resolved = url.resolvingSymlinksInPath()
        return fm.fileExists(atPath: resolved.path) ? resolved : nil
    }
}
