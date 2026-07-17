import SwiftUI
import AppKit
import SweepCore

@MainActor
@Observable
final class UninstallerModel {
    var apps: [InstalledApp] = []
    var loading = false
    var selected: InstalledApp?
    var leftovers: [ScanItem] = []
    var leftoverSelection: Set<String> = []
    var findingLeftovers = false
    var uninstalling = false
    var statusMessage: String?
    var appSizes: [String: Int64] = [:]

    var orphans: [ScanItem] = []
    var orphanSelection: Set<String> = []
    var scanningOrphans = false

    func load() {
        guard apps.isEmpty, !loading else { return }
        loading = true
        Task {
            self.apps = await AppInventory.scan()
            self.loading = false
        }
    }

    func size(for app: InstalledApp) -> Int64? {
        appSizes[app.id]
    }

    func computeSize(for app: InstalledApp) {
        guard appSizes[app.id] == nil else { return }
        Task.detached(priority: .utility) { [url = app.url, id = app.id] in
            let stats = DirectorySizer.stats(of: url)
            await MainActor.run { [weak self] in
                self?.appSizes[id] = stats.size
            }
        }
    }

    func select(_ app: InstalledApp) {
        selected = app
        leftovers = []
        leftoverSelection = []
        statusMessage = nil
        findingLeftovers = true
        Task.detached(priority: .userInitiated) { [bundleID = app.bundleID, name = app.name] in
            let found = LeftoverFinder.find(bundleID: bundleID, appName: name)
            await MainActor.run { [weak self] in
                guard let self, self.selected?.bundleID == bundleID else { return }
                self.leftovers = found
                self.leftoverSelection = Set(found.map(\.id))
                self.findingLeftovers = false
            }
        }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleID }
    }

    func uninstall(model: AppModel) {
        guard let app = selected, !uninstalling else { return }
        guard !app.isApple else {
            statusMessage = "Apple apps are protected by macOS and can't be uninstalled."
            return
        }
        guard !isRunning(app) else {
            statusMessage = "\(app.name) is running. Quit it first, then try again."
            return
        }
        guard UninstallGuard.mayRemoveAppBundle(app.url) else {
            statusMessage = "Refusing to remove anything that isn't an app in an Applications folder."
            return
        }
        uninstalling = true
        statusMessage = nil

        let appItem = ScanItem(
            ruleID: "uninstall-app",
            category: .appLeftovers,
            url: app.url,
            displayName: app.name + ".app",
            detail: "Application bundle",
            size: appSizes[app.id] ?? 0,
            fileCount: 1,
            newestModification: nil,
            tier: .explicitOnly,
            domain: .user
        )
        let selectedLeftovers = leftovers.filter { leftoverSelection.contains($0.id) }

        Task {
            let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist, privileged: model.broker)
            let session = await cleaner.clean(
                items: [appItem] + selectedLeftovers,
                source: .uninstall,
                permanentDelete: false
            )
            await model.history.add(session)
            await model.refreshHistorySummary()
            self.uninstalling = false
            // Only drop the app from the list if its bundle actually left disk;
            // otherwise the user would see it "gone" while it's still installed.
            let bundleRemoved = session.items.contains { $0.originalPath == app.url.path }
            if session.errors.isEmpty {
                self.statusMessage = "Uninstalled \(app.name) — \(session.totalFreed.sweepBytes) moved to Trash."
            } else {
                self.statusMessage = "Finished with issues: " + session.errors.joined(separator: " · ")
            }
            if bundleRemoved {
                self.apps.removeAll { $0.id == app.id }
                self.selected = nil
                self.leftovers = []
            }
        }
    }

    func scanOrphans() {
        guard !scanningOrphans else { return }
        scanningOrphans = true
        orphans = []
        orphanSelection = []
        Task {
            let installed = await AppInventory.scan()
            let installedIDs = Set(installed.map(\.bundleID))
            let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let found = await Task.detached(priority: .userInitiated) {
                OrphanScanner.scan(installedBundleIDs: installedIDs, runningBundleIDs: runningIDs)
            }.value
            self.orphans = found
            self.scanningOrphans = false
        }
    }

    func cleanOrphans(model: AppModel) {
        let items = orphans.filter { orphanSelection.contains($0.id) }
        guard !items.isEmpty else { return }
        Task {
            let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist, privileged: model.broker)
            let session = await cleaner.clean(items: items, source: .uninstall, permanentDelete: false)
            await model.history.add(session)
            await model.refreshHistorySummary()
            self.orphans.removeAll { session.items.map(\.originalPath).contains($0.url.path) }
            self.statusMessage = "Removed \(session.totalFreed.sweepBytes) of leftover data (in Trash)."
        }
    }
}

struct UninstallerView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var tab: Tab = .apps
    @State private var confirmingUninstall = false

    enum Tab: String, CaseIterable { case apps = "Installed Apps", orphans = "Leftovers" }

    private var uninstaller: UninstallerModel { model.uninstaller }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                SectionHeader(title: "Apps", subtitle: "Uninstall apps completely — bundle plus every related file.")
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            if let status = uninstaller.statusMessage {
                StatusPill(text: status, color: Theme.azure)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch tab {
            case .apps: appsPane
            case .orphans: orphansPane
            }
        }
        .padding(24)
        .onAppear { uninstaller.load() }
    }

    // MARK: - Apps

    private var appsPane: some View {
        HSplitView {
            VStack(spacing: 8) {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                List(filteredApps, selection: Binding(
                    get: { uninstaller.selected },
                    set: { if let app = $0 { uninstaller.select(app) } }
                )) { app in
                    AppRow(app: app)
                        .tag(app)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 300, idealWidth: 360)

            detailPane
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private var filteredApps: [InstalledApp] {
        guard !search.isEmpty else { return uninstaller.apps }
        return uninstaller.apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let app = uninstaller.selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    AppIconView(url: app.url, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text(app.bundleID + (app.version.map { " · v\($0)" } ?? ""))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if let size = uninstaller.size(for: app) {
                                StatusPill(text: size.sweepBytes, color: Theme.azure)
                            }
                            if let lastUsed = app.lastUsed {
                                StatusPill(text: "Last used \(lastUsed.sweepRelative)", color: Theme.violet)
                            }
                            if uninstaller.isRunning(app) {
                                StatusPill(text: "Running", color: Theme.amber)
                            }
                        }
                    }
                    Spacer()
                }

                Divider()

                HStack {
                    Text("Related files")
                        .font(.system(size: 13, weight: .semibold))
                    if uninstaller.findingLeftovers {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    let total = uninstaller.leftovers
                        .filter { uninstaller.leftoverSelection.contains($0.id) }
                        .reduce(Int64(0)) { $0 + $1.size }
                    Text(total.sweepBytes)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if uninstaller.leftovers.isEmpty && !uninstaller.findingLeftovers {
                    Text("No related files found outside the app bundle.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                List {
                    ForEach(uninstaller.leftovers) { item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { uninstaller.leftoverSelection.contains(item.id) },
                                set: { on in
                                    if on { uninstaller.leftoverSelection.insert(item.id) }
                                    else { uninstaller.leftoverSelection.remove(item.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(item.detail + " · " + item.url.path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(item.url.path)
                            }
                            Spacer()
                            ByteText(bytes: item.size, font: .system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)

                HStack {
                    Spacer()
                    Button {
                        confirmingUninstall = true
                    } label: {
                        if uninstaller.uninstalling {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Uninstall \(app.name)", systemImage: "trash")
                                .frame(minWidth: 150)
                        }
                    }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(uninstaller.uninstalling || app.isApple)
                    .confirmationDialog(
                        "Uninstall \(app.name)?",
                        isPresented: $confirmingUninstall
                    ) {
                        Button("Move to Trash", role: .destructive) {
                            uninstaller.uninstall(model: model)
                        }
                    } message: {
                        Text("The app and \(uninstaller.leftoverSelection.count) related items go to the Trash. You can restore them from History.")
                    }
                }
            }
            .padding(16)
            .onAppear { uninstaller.computeSize(for: app) }
        } else {
            SweepEmptyState(
                symbol: "square.grid.2x2",
                title: "Pick an app",
                message: "Select an app to see everything it has scattered across your Mac."
            )
        }
    }

    // MARK: - Orphans

    private var orphansPane: some View {
        VStack(spacing: 12) {
            if uninstaller.orphans.isEmpty && !uninstaller.scanningOrphans {
                SweepEmptyState(
                    symbol: "puzzlepiece.extension",
                    title: "Find leftover data",
                    message: "Scans your Library for data belonging to apps that are no longer installed."
                )
                Button {
                    uninstaller.scanOrphans()
                } label: {
                    Label("Scan for leftovers", systemImage: "magnifyingglass")
                }
                .buttonStyle(HeroButtonStyle())
                .padding(.bottom, 30)
            } else if uninstaller.scanningOrphans {
                Spacer()
                ProgressView("Scanning Library…")
                Spacer()
            } else {
                List {
                    ForEach(uninstaller.orphans) { item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { uninstaller.orphanSelection.contains(item.id) },
                                set: { on in
                                    if on { uninstaller.orphanSelection.insert(item.id) }
                                    else { uninstaller.orphanSelection.remove(item.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                Text(item.detail + " · " + item.url.path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            SafetyBadge(tier: item.tier)
                            ByteText(bytes: item.size, font: .system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))

                HStack {
                    Text("Double-check anything you don't recognize — these are heuristic matches.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All") {
                        uninstaller.orphanSelection = Set(uninstaller.orphans.map(\.id))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        uninstaller.cleanOrphans(model: model)
                    } label: {
                        let total = uninstaller.orphans
                            .filter { uninstaller.orphanSelection.contains($0.id) }
                            .reduce(Int64(0)) { $0 + $1.size }
                        Label("Clean \(total.sweepBytes)", systemImage: "sparkles")
                    }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(uninstaller.orphanSelection.isEmpty)
                }
            }
        }
    }
}

struct AppRow: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: app.url, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .medium))
                if let lastUsed = app.lastUsed {
                    Text("Used \(lastUsed.sweepRelative)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let size = model.uninstaller.size(for: app) {
                Text(size.sweepBytes)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppIconView: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}
