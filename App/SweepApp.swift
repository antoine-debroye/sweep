import SwiftUI
import SweepCore

@main
struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .task { await model.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1120, height: 720)

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the "Uninstall with Sweep" Finder service (declared in
        // Info.plist under NSServices).
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar so auto-trim can do its job.
        false
    }
}
