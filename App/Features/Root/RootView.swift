import SwiftUI
import SweepCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Section {
                    sidebarRow(.dashboard)
                    sidebarRow(.smartClean)
                    sidebarRow(.memory)
                } header: {
                    Text("Clean")
                }
                Section {
                    sidebarRow(.uninstaller)
                    sidebarRow(.largeFiles)
                    sidebarRow(.devCleaner)
                    sidebarRow(.optimize)
                } header: {
                    Text("Tools")
                }
                Section {
                    sidebarRow(.history)
                    sidebarRow(.settings)
                } header: {
                    Text("Sweep")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
        .sheet(isPresented: .constant(!model.settings.hasCompletedOnboarding)) {
            OnboardingView()
                .environment(model)
        }
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            Image(systemName: section.symbol)
                .foregroundStyle(model.section == section ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.secondary))
        }
        .tag(section)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .dashboard: DashboardView()
        case .smartClean: SmartCleanView()
        case .memory: MemoryView()
        case .uninstaller: UninstallerView()
        case .largeFiles: LargeFilesView()
        case .devCleaner: DevCleanerView()
        case .optimize: OptimizeView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let disk = model.disk {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(disk.available.sweepBytes) free")
                            .font(.system(size: 11, weight: .semibold))
                        ProgressView(value: disk.usedFraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(Theme.pressureColor(disk.usedFraction))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
