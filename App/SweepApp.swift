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
                .task { await model.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1120, height: 720)

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar so auto-trim can do its job.
        false
    }
}
