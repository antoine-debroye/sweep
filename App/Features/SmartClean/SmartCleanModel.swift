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

            let installed = await AppInventory.scan()
            let installedIDs = Set(installed.map(\.bundleID))
            let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

            let extraItems = await Task.detached(priority: .userInitiated) { () -> [ScanItem] in
                var extras = OrphanScanner.scan(installedBundleIDs: installedIDs, runningBundleIDs: runningIDs)
                extras += ProjectArtifactScanner.scan(devFolders: devFolders, minAgeDays: 30, policy: policy)
                return extras
            }.value

            guard !Task.isCancelled else { return }
            for item in extraItems { self.ingest(item) }
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
                let tail = model.settings.permanentDelete
                    ? "Permanent delete is on, so this can't be undone."
                    : "Everything is in the Trash — undo any time from History."
                Notifier.post(
                    title: "Sweep finished",
                    body: "Freed \(session.totalFreed.sweepBytes). \(tail)"
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
