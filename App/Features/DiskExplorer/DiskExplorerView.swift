import SwiftUI
import AppKit
import SweepCore

enum DiskSort: String, CaseIterable, Identifiable {
    case largest, smallest, oldest, newest, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .largest: "Largest"
        case .smallest: "Smallest"
        case .oldest: "Oldest"
        case .newest: "Newest"
        case .name: "Name"
        }
    }
}

@MainActor
@Observable
final class DiskExplorerModel {
    var root = FileManager.default.homeDirectoryForCurrentUser
    var path: [URL] = []                 // folders drilled into below `root`
    var children: [DiskNode] = []
    var loading = false
    var statusMessage: String?

    var sort: DiskSort = .largest
    var minSizeMB = 0
    var foldersOnly = false
    var safeOnly = false
    var cloudOnly = false
    var search = ""

    var selection: Set<String> = []

    private var scanTask: Task<Void, Never>?
    /// Recently-measured levels, keyed by path, so back/forward navigation is instant.
    private var levelCache = DiskLevelCache()

    var currentURL: URL { path.last ?? root }
    var breadcrumb: [URL] { [root] + path }

    // MARK: Navigation

    func startIfNeeded(model: AppModel) {
        if children.isEmpty && !loading { open(currentURL, model: model) }
    }

    func open(_ url: URL, model: AppModel) {
        scanTask?.cancel()
        selection = []
        statusMessage = nil

        // Instant path: serve a recently-measured level from cache, no spinner.
        if let cached = levelCache.lookup(path: url.path, now: Date()) {
            children = cached
            loading = false
            return
        }

        loading = true
        children = []
        let policy = model.policy
        scanTask = Task {
            var collected: [DiskNode] = []
            for await node in DiskTreeScanner.stream(of: url, policy: policy) {
                // A newer open() cancelled us — stop appending to a stale level.
                if Task.isCancelled { return }
                collected.append(node)
                withAnimation(.easeOut(duration: 0.18)) {
                    self.children.append(node)   // @Observable → live, incremental UI
                }
            }
            if Task.isCancelled { return }
            self.loading = false
            self.levelCache.store(path: url.path, nodes: collected, now: Date())
        }
    }

    func drill(into node: DiskNode, model: AppModel) {
        guard node.isDirectory else { return }
        path.append(node.url)
        open(node.url, model: model)
    }

    func navigate(to url: URL, model: AppModel) {
        if url == root {
            path = []
        } else if let idx = path.firstIndex(of: url) {
            path = Array(path.prefix(idx + 1))
        }
        open(url, model: model)
    }

    func setRoot(_ url: URL, model: AppModel) {
        root = url
        path = []
        open(url, model: model)
    }

    func rescan(model: AppModel) {
        // A rescan means "don't trust cached data here" — drop this subtree first.
        levelCache.invalidate(pathsWithPrefix: currentURL.path)
        open(currentURL, model: model)
    }

    func cancel() { scanTask?.cancel(); loading = false }

    // MARK: Filtering + sorting

    var displayed: [DiskNode] {
        var items = children
        let minBytes = Int64(minSizeMB) * 1_000_000
        if minBytes > 0 { items = items.filter { $0.allocatedSize >= minBytes } }
        if foldersOnly { items = items.filter { $0.isDirectory } }
        if safeOnly { items = items.filter { $0.kind.isDeletable } }
        if cloudOnly { items = items.filter { $0.kind.isCloud } }
        if !search.isEmpty { items = items.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        return items.sorted(by: order)
    }

    private func order(_ a: DiskNode, _ b: DiskNode) -> Bool {
        switch sort {
        case .largest: a.allocatedSize > b.allocatedSize
        case .smallest: a.allocatedSize < b.allocatedSize
        case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .oldest: dateOrder(a, b, ascending: true)
        case .newest: dateOrder(a, b, ascending: false)
        }
    }

    private func dateOrder(_ a: DiskNode, _ b: DiskNode, ascending: Bool) -> Bool {
        switch (a.newestModification, b.newestModification) {
        case let (l?, r?): return ascending ? l < r : l > r
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return a.allocatedSize > b.allocatedSize
        }
    }

    // MARK: Aggregates

    var currentTotal: Int64 { children.reduce(0) { $0 + $1.allocatedSize } }
    var maxChildSize: Int64 { children.map(\.allocatedSize).max() ?? 0 }
    var reclaimableSafe: Int64 {
        children.filter { $0.kind == .safeToDelete }.reduce(0) { $0 + $1.allocatedSize }
    }
    var reclaimableOffload: Int64 { children.reduce(0) { $0 + $1.kind.offloadableBytes } }
    var offloadableNodes: [DiskNode] { children.filter { $0.kind.offloadableBytes > 0 } }

    var selectedNodes: [DiskNode] { children.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedNodes.reduce(0) { $0 + $1.allocatedSize } }

    // MARK: Actions

    /// Trash only truly deletable rows — protected and cloud items are filtered
    /// out defensively even if a stale selection contains one.
    func moveToTrash(model: AppModel) {
        let chosen = selectedNodes.filter { $0.kind.isDeletable }
        guard !chosen.isEmpty else { return }
        let items = chosen.map { node in
            ScanItem(
                ruleID: "disk-explorer",
                category: .largeFiles,
                url: node.url,
                displayName: node.name,
                detail: node.url.deletingLastPathComponent().path,
                size: node.allocatedSize,
                fileCount: node.fileCount,
                newestModification: node.newestModification,
                tier: node.kind == .safeToDelete ? .safe : .explicitOnly,
                domain: .user
            )
        }
        Task {
            let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist)
            let session = await cleaner.clean(items: items, source: .diskExplorer, permanentDelete: model.settings.permanentDelete)
            await model.history.add(session)
            await model.refreshHistorySummary()
            model.refreshDisk()
            let removed = Set(session.items.map(\.originalPath))
            self.children.removeAll { removed.contains($0.url.path) }
            // Trashed bytes counted into this level and every ancestor's total, so
            // drop those cached levels; sibling subtrees stay warm.
            for u in self.breadcrumb { self.levelCache.invalidate(path: u.path) }
            self.selection = []
            self.statusMessage = "Moved \(session.totalFreed.sweepBytes) to Trash."
        }
    }

    /// Cloud offload is never a delete: reveal the materialized files in Finder so
    /// the provider's own "Free Up Space" / "Remove Download" can evict them.
    func freeUpCloud(_ nodes: [DiskNode]) {
        let urls = nodes.filter { $0.kind.isCloud }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        statusMessage = "Revealed in Finder — right-click and choose \u{201C}Remove Download\u{201D} / \u{201C}Free Up Space\u{201D} to offload."
    }
}

struct DiskExplorerView: View {
    @Environment(AppModel.self) private var model
    private var explorer: DiskExplorerModel { model.diskExplorer }

    var body: some View {
        VStack(spacing: 12) {
            header
            breadcrumbBar
            toolbar
            summary
            if let status = explorer.statusMessage {
                StatusPill(text: status, color: Theme.mint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
            footer
        }
        .padding(24)
        .onAppear { explorer.startIfNeeded(model: model) }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            SectionHeader(title: "Disk Explorer", subtitle: "See where your space goes — drill in, and reclaim safely.")
            Spacer()
            Menu {
                Button("Home folder") { explorer.setRoot(FileManager.default.homeDirectoryForCurrentUser, model: model) }
                Button("Whole Mac") { explorer.setRoot(URL(fileURLWithPath: "/"), model: model) }
                Divider()
                Button("Choose folder…") { chooseFolder() }
            } label: {
                Label(explorer.root.path == "/" ? "Whole Mac" : explorer.root.lastPathComponent, systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if explorer.loading {
                Button("Stop") { explorer.cancel() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button { explorer.rescan(model: model) } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(explorer.breadcrumb.enumerated()), id: \.element) { idx, url in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        explorer.navigate(to: url, model: model)
                    } label: {
                        Text(idx == 0 ? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent) : url.lastPathComponent)
                            .font(.system(size: 11.5, weight: idx == explorer.breadcrumb.count - 1 ? .semibold : .regular))
                            .foregroundStyle(idx == explorer.breadcrumb.count - 1 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Sort", selection: Binding(get: { explorer.sort }, set: { explorer.sort = $0 })) {
                ForEach(DiskSort.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 140)
            .labelsHidden()
            Toggle("Folders", isOn: Binding(get: { explorer.foldersOnly }, set: { explorer.foldersOnly = $0 })).toggleStyle(.button)
            Toggle("Safe", isOn: Binding(get: { explorer.safeOnly }, set: { explorer.safeOnly = $0 })).toggleStyle(.button)
            Toggle("Cloud", isOn: Binding(get: { explorer.cloudOnly }, set: { explorer.cloudOnly = $0 })).toggleStyle(.button)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter", text: Binding(get: { explorer.search }, set: { explorer.search = $0 }))
                    .textFieldStyle(.plain)
                    .frame(width: 140)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .font(.system(size: 11.5))
    }

    private var summary: some View {
        HStack(spacing: 10) {
            StatTile(title: "This folder", value: explorer.currentTotal.sweepBytes, symbol: "folder.fill", tint: Theme.azure, caption: "\(explorer.children.count) items")
            StatTile(title: "Safe to reclaim", value: explorer.reclaimableSafe.sweepBytes, symbol: "checkmark.shield.fill", tint: Theme.mint, caption: "regenerable here")
            StatTile(title: "Cloud offloadable", value: explorer.reclaimableOffload.sweepBytes, symbol: "cloud.fill", tint: Theme.violet, caption: "synced, downloaded")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if explorer.children.isEmpty && explorer.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Measuring \(explorer.currentURL.lastPathComponent)…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if explorer.displayed.isEmpty {
            SweepEmptyState(symbol: "internaldrive", title: "Nothing here", message: explorer.children.isEmpty ? "This folder is empty or unreadable." : "No items match the current filters.")
        } else {
            List {
                ForEach(explorer.displayed) { node in
                    row(node)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            )
        }
    }

    private func row(_ node: DiskNode) -> some View {
        let fraction = explorer.maxChildSize > 0 ? Double(node.allocatedSize) / Double(explorer.maxChildSize) : 0
        return HStack(spacing: 10) {
            if node.kind.isDeletable {
                Toggle("", isOn: Binding(
                    get: { explorer.selection.contains(node.id) },
                    set: { on in if on { explorer.selection.insert(node.id) } else { explorer.selection.remove(node.id) } }
                ))
                .toggleStyle(.checkbox).labelsHidden()
            } else {
                Color.clear.frame(width: 16)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    kindPill(node)
                    Spacer(minLength: 4)
                    if let d = node.newestModification, d >= LargeFile.plausibleDateFloor {
                        Text(d.sweepRelative).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    ByteText(bytes: node.allocatedSize, font: .system(size: 12, weight: .semibold, design: .rounded))
                        .frame(width: 74, alignment: .trailing)
                    if node.isDirectory {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    } else {
                        Color.clear.frame(width: 10)
                    }
                }
                sizeBar(fraction: fraction, color: barColor(node.kind))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if node.isDirectory { explorer.drill(into: node, model: model) } }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Open") { NSWorkspace.shared.open(node.url) }
            if node.isDirectory { Button("Explore") { explorer.drill(into: node, model: model) } }
            if node.kind.isCloud { Button("Free up space (offload)") { explorer.freeUpCloud([node]) } }
        }
    }

    private func sizeBar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.35))
                Capsule().fill(color.gradient)
                    .frame(width: max(2, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
    }

    private func barColor(_ kind: DiskNodeKind) -> Color {
        switch kind {
        case .safeToDelete: Theme.mint
        case .review: Theme.amber
        case .protectedPath: Color.secondary
        case .cloudOffloadable, .cloudOnlineOnly: Theme.violet
        }
    }

    private func kindPill(_ node: DiskNode) -> some View {
        let (text, color): (String, Color) = {
            switch node.kind {
            case .safeToDelete: ("Safe", Theme.mint)
            case .review: ("Review", Theme.amber)
            case .protectedPath: ("Protected", Color.secondary)
            case .cloudOffloadable(let b): ("Offload \(b.sweepBytes)", Theme.violet)
            case .cloudOnlineOnly: ("Online-only", Theme.violet)
            }
        }()
        return Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if explorer.loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else {
                Text("\(explorer.displayed.count) items").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if explorer.reclaimableOffload > 0 {
                Button {
                    explorer.freeUpCloud(explorer.offloadableNodes)
                } label: {
                    Label("Free up \(explorer.reclaimableOffload.sweepBytes)", systemImage: "cloud")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button {
                explorer.moveToTrash(model: model)
            } label: {
                Label(explorer.selection.isEmpty ? "Select items to remove" : "Move \(explorer.selectedSize.sweepBytes) to Trash", systemImage: "trash")
            }
            .buttonStyle(HeroButtonStyle())
            .disabled(explorer.selection.isEmpty)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            explorer.setRoot(url, model: model)
        }
    }
}
