import SwiftUI
import AppKit
import SweepCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var quickCleaning = false
    @State private var quickCleanResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Sweep", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                if let disk = model.disk {
                    Text("\(disk.available.sweepBytes) free")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = model.memory.current {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Theme.pressureColor(snapshot.usedFraction))
                        .frame(width: 8, height: 8)
                    Text("Memory \(Int(snapshot.usedFraction * 100))% · \(snapshot.pressure.label)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let freed = model.memory.lastFlushFreed {
                        Text("+\(freed.sweepMemory)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.mint)
                    }
                }
            }

            Divider()

            menuButton("Open Sweep", symbol: "macwindow") {
                openMain()
            }
            menuButton("Smart Scan", symbol: "magnifyingglass") {
                openMain(section: .smartClean)
                if model.smartClean.phase == .idle {
                    model.smartClean.startScan(model: model)
                }
            }
            menuButton(model.memory.flushing ? "Flushing RAM…" : "Flush RAM", symbol: "bolt.fill", disabled: model.memory.flushing) {
                model.memory.flush(model: model)
            }
            menuButton(quickCleaning ? "Quick cleaning…" : "Quick Clean (safe junk)", symbol: "sparkles", disabled: quickCleaning) {
                quickClean()
            }

            if let result = quickCleanResult {
                Text(result)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.mint)
            }

            if model.updater.updateAvailable {
                Divider()
                Button {
                    openMain(section: .settings)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accentGradient)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Update available")
                                .font(.system(size: 12.5, weight: .semibold))
                            if let release = model.updater.availableRelease {
                                Text(release.displayName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                if model.settings.autoTrimEnabled {
                    Text("Auto-trim on" + (model.settings.lastAutoTrim.map { " · last \($0.sweepRelative)" } ?? ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Auto-trim off")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 270)
    }

    private func openMain(section: AppSection? = nil) {
        if let section { model.section = section }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func menuButton(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .background(.clear)
    }

    /// Safe-tier-only clean with the auto-trim age gate — same guarantees as
    /// background trims: Trash-first, logged in History.
    private func quickClean() {
        quickCleaning = true
        quickCleanResult = nil
        Task {
            let running = RunningApps.snapshot()
            let engine = ScanEngine(policy: model.policy, whitelist: model.settings.whitelist,
                                    runningBundleIDs: running.bundleIDs, runningAppNames: running.names)
            let rules = RuleCatalog.autoTrimRules(minAgeDays: model.settings.autoTrimMinAgeDays)
            let report = await engine.scanReport(rules: rules)
            guard !report.items.isEmpty else {
                quickCleanResult = "Nothing old enough to clean."
                quickCleaning = false
                return
            }
            let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist)
            let session = await cleaner.clean(items: report.items, source: .menuBar, permanentDelete: false)
            await model.history.add(session)
            await model.refreshHistorySummary()
            model.refreshDisk()
            quickCleanResult = "Freed \(session.totalFreed.sweepBytes) (in Trash)"
            quickCleaning = false
        }
    }
}
