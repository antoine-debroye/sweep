import AppKit
import SweepCore

/// Bridges the openWindow SwiftUI action out to non-view code (the Finder
/// service handler), so it can reopen the main window when Sweep is running in
/// the menu bar with no window. `RootView` installs `open` while it's alive.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: ((String) -> Void)?
}

/// Handles the "Uninstall with Sweep" Finder service. macOS activates the app
/// and calls `uninstallApp(_:userData:error:)` on the main thread with the
/// selected `.app` bundle(s) on the pasteboard.
final class ServiceProvider: NSObject {
    @objc func uninstallApp(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard let appURL = urls.first(where: { $0.pathExtension == "app" }) else {
            error.pointee = "Sweep can only uninstall applications." as NSString
            return
        }
        // The service is delivered on the main thread; hop to the main actor to
        // touch the (main-actor-isolated) app model.
        Task { @MainActor in
            AppModel.shared?.handleExternalUninstall(url: appURL)
        }
    }
}

// MARK: - Running apps snapshot

/// Bundle ids and display names of running apps, both lowercased, for the
/// scan engine's running-app guard.
enum RunningApps {
    struct Snapshot {
        let bundleIDs: Set<String>
        let names: Set<String>
    }

    @MainActor
    static func snapshot() -> Snapshot {
        let apps = NSWorkspace.shared.runningApplications
        let ids = Set(apps.compactMap { $0.bundleIdentifier?.lowercased() })
        var names = Set(apps.compactMap { $0.localizedName?.lowercased() })
        // The bundle's file name is what Application Support folders are
        // usually named after ("Code" vs localized "Visual Studio Code").
        for app in apps {
            if let name = app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() {
                names.insert(name)
            }
        }
        return Snapshot(bundleIDs: ids, names: names)
    }
}
