import SwiftUI
import AppKit
import Security
import SweepCore

/// Reads an app's code-signing Team Identifier — used to find team-scoped app
/// groups (`<TEAMID>.com.vendor…`) during a deep uninstall search. Synchronous,
/// no special entitlement; mirrors the SecCode usage in the privileged helper.
enum CodeSigning {
    static func teamIdentifier(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

@MainActor
@Observable
final class UninstallerModel {
    var apps: [InstalledApp] = []
    var loading = false
    var selected: InstalledApp?
    var leftovers: [ScanItem] = []
    var leftoverSelection: Set<String> = []
    var findingLeftovers = false
    /// Why leftovers were withheld (another installed copy shares them).
    var leftoverNote: String?
    var uninstalling = false
    var statusMessage: String?
    var appSizes: [String: Int64] = [:]
    var matchDepth: MatchDepth = .enhanced {
        didSet {
            guard oldValue != matchDepth, let app = selected else { return }
            findLeftovers(for: app)
        }
    }

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
        leftoverNote = nil
        statusMessage = nil
        findLeftovers(for: app)
    }

    private func findLeftovers(for app: InstalledApp) {
        findingLeftovers = true
        let depth = matchDepth
        Task.detached(priority: .userInitiated) { [bundleID = app.bundleID, name = app.name, url = app.url] in
            let teamID = CodeSigning.teamIdentifier(for: url)
            // Every copy with this bundle id shares the same Library data.
            // While another one is installed the data is still in use, so it
            // is listed for the user to decide but nothing is pre-selected.
            let others = OtherAppCopies.find(bundleID: bundleID, excluding: url)
            let found = LeftoverFinder.find(bundleID: bundleID, appName: name, teamID: teamID, depth: depth, appURL: url)
            await MainActor.run { [weak self] in
                guard let self, self.selected?.bundleID == bundleID else { return }
                self.leftoverNote = others.note(appName: name)
                self.leftovers = found
                // Pre-select confident matches only; heuristic ".review" hits are
                // left unchecked for the user to opt into.
                self.leftoverSelection = others.isEmpty
                    ? Set(found.filter { $0.tier != .review }.map(\.id))
                    : []
                self.findingLeftovers = false
            }
        }
    }

    /// Selects an app by URL that may not be in the scanned `apps` list yet
    /// (e.g. arriving from the Finder "Uninstall with Sweep" service).
    func selectExternal(url: URL) {
        let app: InstalledApp
        if let existing = apps.first(where: { $0.url == url }) {
            app = existing
        } else if let built = AppInventory.installedApp(at: url) {
            app = built
            apps.insert(built, at: 0)
        } else {
            statusMessage = "That doesn't look like an app Sweep can uninstall."
            return
        }
        computeSize(for: app)
        select(app)
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleID }
    }

    func uninstall(model: AppModel) {
        guard let app = selected, !uninstalling else { return }
        guard !isRunning(app) else {
            statusMessage = "\(app.name) is running. Quit it first, then try again."
            return
        }
        // Identity-level refusal (security agents, platform dependencies) on
        // top of the path-level check.
        if let reason = UninstallGuard.verdict(for: app).reason {
            statusMessage = reason
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
        blocked = []
        launchItems = []
        Task {
            let running = RunningApps.snapshot()
            // Nested so that suite installs (/Applications/Adobe Acrobat DC/…,
            // /Applications/Utilities/…) count as installed and their data is
            // never mistaken for a leftover.
            let installed = await AppInventory.scanNested()
            let index = InstalledAppIndex.live(
                apps: installed,
                runningBundleIDs: running.bundleIDs,
                runningAppNames: running.names,
                runningExecutablePaths: running.executablePaths
            )
            let found = await Task.detached(priority: .userInitiated) {
                (OrphanScanner.scanDetailed(index: index), LaunchItemAudit.audit(index: index))
            }.value
            self.orphans = found.0.items
            self.blocked = found.0.blocked
            self.launchItems = found.1
            self.scanningOrphans = false
        }
    }

    /// Items grouped by departed app for display. Selection stays per-path.
    var orphanGroups: (groups: [(id: String, items: [ScanItem])], ungrouped: [ScanItem]) {
        let grouped = Dictionary(grouping: orphans.filter { $0.group != nil }) { $0.group! }
        let groups = grouped
            .map { (id: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { lhs, rhs in
                lhs.items.reduce(Int64(0)) { $0 + $1.size } > rhs.items.reduce(Int64(0)) { $0 + $1.size }
            }
        return (groups, orphans.filter { $0.group == nil })
    }

    /// Leftovers found but not offered: something is running out of them.
    var blocked: [LaunchItemFinding] = []
    /// Orphaned launch items and privileged helpers. Reported only — Sweep does
    /// not unload jobs, delete root-owned helpers or rewrite receipts.
    var launchItems: [LaunchItemFinding] = []

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

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Search depth", selection: Binding(
                        get: { uninstaller.matchDepth },
                        set: { uninstaller.matchDepth = $0 }
                    )) {
                        ForEach(MatchDepth.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(uninstaller.matchDepth.blurb)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                if let note = uninstaller.leftoverNote, !uninstaller.findingLeftovers {
                    Label(note, systemImage: "square.on.square")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.amber)
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
                            if item.tier == .review {
                                SafetyBadge(tier: item.tier)
                            }
                            ByteText(bytes: item.size, font: .system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)

                if let handoff = VendorUninstaller.handoff(for: app) {
                    VendorHandoffBanner(handoff: handoff)
                }

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
                    .disabled(uninstaller.uninstalling || !UninstallGuard.verdict(for: app).isAllowed)
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
                    let split = uninstaller.orphanGroups
                    ForEach(split.groups, id: \.id) { group in
                        OrphanGroupRow(groupID: group.id, items: group.items)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(split.ungrouped) { item in
                        OrphanItemRow(item: item)
                            .listRowSeparator(.hidden)
                    }
                    if !uninstaller.blocked.isEmpty || !uninstaller.launchItems.isEmpty {
                        Section("Needs your attention — Sweep won't touch these") {
                            ForEach(uninstaller.blocked + uninstaller.launchItems) { finding in
                                FindingRow(finding: finding)
                                    .listRowSeparator(.hidden)
                            }
                        }
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
                        // Review-tier rows are heuristic; the user opts into
                        // those one at a time rather than in bulk.
                        uninstaller.orphanSelection = Set(
                            uninstaller.orphans.filter { $0.tier != .review }.map(\.id)
                        )
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


// MARK: - Leftover rows

/// One departed app's data as a single collapsible unit. The children stay
/// individually selectable because cleaning and undo are per-path.
private struct OrphanGroupRow: View {
    @Environment(AppModel.self) private var model
    let groupID: String
    let items: [ScanItem]
    @State private var expanded = false

    private var uninstaller: UninstallerModel { model.uninstaller }
    private var size: Int64 { items.reduce(0) { $0 + $1.size } }
    private var allSelected: Bool {
        items.allSatisfy { uninstaller.orphanSelection.contains($0.id) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(items) { item in
                OrphanItemRow(item: item).padding(.leading, 6)
            }
        } label: {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { allSelected },
                    set: { on in
                        for item in items {
                            if on { uninstaller.orphanSelection.insert(item.id) }
                            else { uninstaller.orphanSelection.remove(item.id) }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text(items.first?.group?.capitalized ?? groupID)
                        .font(.system(size: 12, weight: .semibold))
                    Text(items.count == 1 ? "1 location" : "\(items.count) locations")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SafetyBadge(tier: items.first?.tier ?? .review)
                ByteText(bytes: size, font: .system(size: 11.5, weight: .semibold, design: .rounded))
            }
        }
    }
}

private struct OrphanItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem

    private var uninstaller: UninstallerModel { model.uninstaller }

    var body: some View {
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
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}

/// Read-only finding: a leftover blocked by a live process, an orphaned launch
/// item, or an orphaned privileged helper. Deliberately has no delete action —
/// unloading launchd jobs and removing root-owned helpers needs the user.
private struct FindingRow: View {
    let finding: LaunchItemFinding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(finding.kind.label): \(finding.label)")
                    .font(.system(size: 12, weight: .medium))
                Text(finding.reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([finding.url])
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.small)
        }
    }
}


// MARK: - Vendor uninstaller hand-off

/// Shown when deleting the app bundle is the wrong way to remove this app.
///
/// Suites like Adobe spread themselves across several Applications folders,
/// `/Library/Application Support` and a set of launch items and privileged
/// helpers, most of which Sweep cannot reach. Pointing at the vendor's own
/// uninstaller removes all of it, which is a better outcome than Sweep
/// deleting the one part it can see.
private struct VendorHandoffBanner: View {
    let handoff: UninstallHandoff

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if case .vendorTool(let url, let label) = handoff {
                Button(label) { NSWorkspace.shared.open(url) }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var title: String {
        switch handoff {
        case .vendorTool: "This app ships its own uninstaller"
        case .managedByVendor(let vendor, _): "\(vendor) has to remove this"
        }
    }

    private var detail: String {
        switch handoff {
        case .vendorTool(let url, _):
            "Using \(url.deletingPathExtension().lastPathComponent) also removes the shared components and "
                + "daemons that live outside this app bundle, which Sweep cannot reach."
        case .managedByVendor(_, let guidance):
            guidance
        }
    }
}
