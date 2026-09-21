import SwiftUI
import AppKit
import SweepCore

@MainActor
@Observable
final class SmartCleanModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case cleaning
        case done
    }

    var phase: Phase = .idle
    var itemsByCategory: [CleanCategory: [ScanItem]] = [:]
    var activeCategories: Set<CleanCategory> = []
    var seenCategories: Set<CleanCategory> = []
    var selection: Set<String> = []
    var expandedCategory: CleanCategory?
    var runningTotal: Int64 = 0
    var scanDuration: TimeInterval = 0
    var cleanProgress: CleanProgress?
    var lastSession: CleanSession?
    var undoResult: String?
    /// Leftovers that were found but can't be cleaned yet because something is
    /// still running out of them.
    var blockedLeftovers: [LaunchItemFinding] = []

    private var scanTask: Task<Void, Never>?
    private var seenPaths: Set<String> = []

    var allItems: [ScanItem] {
        itemsByCategory.values.flatMap { $0 }
    }

    var categories: [CleanCategory] {
        itemsByCategory.keys.sorted { $0.sortOrder < $1.sortOrder }
    }

    var selectedItems: [ScanItem] {
        allItems.filter { selection.contains($0.id) }
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    func items(in category: CleanCategory) -> [ScanItem] {
        (itemsByCategory[category] ?? []).sorted { $0.size > $1.size }
    }

    func selectedSize(in category: CleanCategory) -> Int64 {
        items(in: category).filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    // MARK: - Groups
    //
    // Several paths can belong to one departed app (its Application Support
    // folder, caches, preferences, HTTP storage…). They stay separate
    // `ScanItem`s — selection, cleaning and undo are all per-path — and are only
    // *displayed* together, keyed on `ScanItem.group`.

    struct ItemGroup: Identifiable {
        let id: String
        let items: [ScanItem]
        var size: Int64 { items.reduce(0) { $0 + $1.size } }
        var title: String { items.first?.group?.capitalized ?? id }
    }

    /// Grouped items first (largest group first), then everything ungrouped.
    func groups(in category: CleanCategory) -> (groups: [ItemGroup], ungrouped: [ScanItem]) {
        let all = items(in: category)
        let grouped = Dictionary(grouping: all.filter { $0.group != nil }) { $0.group! }
        let groups = grouped
            .map { ItemGroup(id: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.size > $1.size }
        return (groups, all.filter { $0.group == nil })
    }

    /// nil when partially selected, for a tri-state checkbox.
    func groupSelectionState(_ group: ItemGroup) -> Bool? {
        let selected = group.items.filter { selection.contains($0.id) }.count
        if selected == 0 { return false }
        if selected == group.items.count { return true }
        return nil
    }

    func setGroup(_ group: ItemGroup, selected: Bool) {
        for item in group.items {
            if selected { selection.insert(item.id) } else { selection.remove(item.id) }
        }
    }

    // MARK: - Scan

    func startScan(model: AppModel) {
        guard phase != .scanning else { return }
        phase = .scanning
        itemsByCategory = [:]
        selection = []
        seenPaths = []
        seenCategories = []
        runningTotal = 0
        undoResult = nil
        blockedLeftovers = []
        model.checkFullDiskAccess()

        let running = RunningApps.snapshot()
        let engine = ScanEngine(policy: model.policy, whitelist: model.settings.whitelist,
                                runningBundleIDs: running.bundleIDs, runningAppNames: running.names)
        let rules = RuleCatalog.rules()
        let devFolders = model.settings.devFolders.map { URL(fileURLWithPath: $0) }
        let policy = model.policy

        scanTask = Task { [weak self] in
            guard let self else { return }

            for await event in engine.scan(rules: rules) {
                guard !Task.isCancelled else { return }
                switch event {
                case .categoryStarted(let category):
                    self.activeCategories.insert(category)
                    self.seenCategories.insert(category)
                case .item(let item):
                    self.ingest(item)
                case .categoryFinished(let category):
                    self.activeCategories.remove(category)
                case .finished(let report):
                    self.scanDuration = report.duration
                }
            }

            // Second pass: heuristic scanners (orphans, project artifacts).
            self.activeCategories.insert(.appLeftovers)
            self.activeCategories.insert(.projectArtifacts)
            self.seenCategories.insert(.appLeftovers)
            self.seenCategories.insert(.projectArtifacts)

            // A nested inventory (depth 2+, including /Applications/Utilities)
            // is what stops a suite install such as
            // /Applications/Adobe Acrobat DC/Acrobat Distiller.app from being
            // mistaken for uninstalled — the flat scan misses those entirely.
            let installed = await AppInventory.scanNested()
            let index = InstalledAppIndex.live(
                apps: installed,
                runningBundleIDs: running.bundleIDs,
                runningAppNames: running.names,
                runningExecutablePaths: running.executablePaths
            )

            let extras = await Task.detached(priority: .userInitiated) { () -> (OrphanScanner.Result, [ScanItem]) in
                let leftovers = OrphanScanner.scanDetailed(index: index, policy: policy)
                let artifacts = ProjectArtifactScanner.scan(devFolders: devFolders, minAgeDays: 30, policy: policy)
                return (leftovers, artifacts)
            }.value

            guard !Task.isCancelled else { return }
            self.blockedLeftovers = extras.0.blocked
            for item in extras.0.items { self.ingest(item) }
            for item in extras.1 { self.ingest(item) }
            self.activeCategories.remove(.appLeftovers)
            self.activeCategories.remove(.projectArtifacts)

            self.phase = .results
        }
    }

    private func ingest(_ item: ScanItem) {
        // Dynamic rules can overlap (an Electron cache also sits under a
        // sandbox container); offer each path once.
        guard seenPaths.insert(item.url.path).inserted else { return }
        itemsByCategory[item.category, default: []].append(item)
        runningTotal += item.size
        if item.tier == .safe {
            selection.insert(item.id)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = itemsByCategory.isEmpty ? .idle : .results
    }

    // MARK: - Selection

    func toggle(_ item: ScanItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func categorySelectionState(_ category: CleanCategory) -> Bool? {
        let items = items(in: category)
        let selected = items.filter { selection.contains($0.id) }.count
        if selected == 0 { return false }
        if selected == items.count { return true }
        return nil
    }

    func setCategory(_ category: CleanCategory, selected: Bool) {
        for item in items(in: category) {
            if selected {
                selection.insert(item.id)
            } else {
                selection.remove(item.id)
            }
        }
    }

    // MARK: - Clean

    func clean(model: AppModel) {
        let items = selectedItems
        guard !items.isEmpty, phase == .results else { return }
        phase = .cleaning
        cleanProgress = nil

        Task {
            let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist, privileged: model.broker)
            let session = await cleaner.clean(
                items: items,
                source: .smartScan,
                permanentDelete: model.settings.permanentDelete
            ) { [weak self] progress in
                Task { @MainActor in
                    // Each progress event hops the actor on its own Task, which
                    // the runtime may reorder; only apply forward progress so
                    // the bar never jumps backwards.
                    guard let self else { return }
                    if progress.completed >= (self.cleanProgress?.completed ?? 0) {
                        self.cleanProgress = progress
                    }
                }
            }
            await model.history.add(session)
            self.lastSession = session
            self.phase = .done
            model.refreshDisk()
            await model.refreshHistorySummary()
            if model.settings.notificationsEnabled, session.totalFreed > 0 {
                // "Freed" is only true once the Trash is emptied; until then
                // the bytes are still on disk and the free-space figure has
                // not moved. Say what actually happened.
                let verb = model.settings.permanentDelete ? "Deleted" : "Moved"
                let tail = model.settings.permanentDelete
                    ? "Permanent delete is on, so this can't be undone."
                    : "It's in the Trash — undo any time from History, or empty the Trash to reclaim the space."
                Notifier.post(
                    title: "Sweep finished",
                    body: "\(verb) \(session.totalFreed.sweepBytes). \(tail)"
                )
            }
        }
    }

    func undoLastClean(model: AppModel) {
        guard let session = lastSession else { return }
        Task {
            let result = await model.history.undo(sessionID: session.id)
            undoResult = "Restored \(result.restored) item\(result.restored == 1 ? "" : "s")"
                + (result.missing > 0 ? " · \(result.missing) no longer in Trash" : "")
            await model.refreshHistorySummary()
        }
    }

    func reset() {
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
        itemsByCategory = [:]
        selection = []
        runningTotal = 0
        cleanProgress = nil
        lastSession = nil
        undoResult = nil
    }
}
