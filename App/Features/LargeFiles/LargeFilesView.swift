import SwiftUI
import AppKit
import SweepCore

enum LargeFileSort: String, CaseIterable, Identifiable {
    case largest, oldest, newest, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .largest: "Largest"
        case .oldest: "Oldest first"
        case .newest: "Newest first"
        case .name: "Name"
        }
    }
}

@MainActor
@Observable
final class LargeFilesModel {
    var files: [LargeFile] = []
    var scanning = false
    var selection: Set<String> = []
    var minSizeMB: Int = 100
    var statusMessage: String?
    var sort: LargeFileSort = .largest { didSet { applySort() } }

    private var scanTask: Task<Void, Never>?

    /// Sorts `files` in place per the current `sort`. Files with no plausible
    /// date (unknown) fall to the end of date sorts, ordered by size.
    func applySort() {
        switch sort {
        case .largest:
            files.sort { $0.size > $1.size }
        case .oldest:
            files.sort { Self.dateOrder($0, $1, ascending: true) }
        case .newest:
            files.sort { Self.dateOrder($0, $1, ascending: false) }
        case .name:
            files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private static func dateOrder(_ a: LargeFile, _ b: LargeFile, ascending: Bool) -> Bool {
        switch (a.displayDate, b.displayDate) {
        case let (l?, r?): return ascending ? l < r : l > r
        case (nil, _?): return false   // unknown dates last
        case (_?, nil): return true
        case (nil, nil): return a.size > b.size
        }
    }

    func scan(model: AppModel) {
        guard !scanning else { return }
        scanning = true
        files = []
        selection = []
        statusMessage = nil
        let minBytes = Int64(minSizeMB) * 1_000_000
        let policy = model.policy
        let home = policy.home

        scanTask = Task {
            // Buffer incoming files and flush in batches: appending + re-sorting
            // the observed array on every single item drives the SwiftUI List
            // hard enough to crash in optimized builds. Deduping by path guards
            // against the same URL being yielded twice (possible while the tree
            // is being written to), which would put duplicate ids into ForEach.
            var buffer: [LargeFile] = []
            var seen = Set<String>()

            for await file in LargeFileScanner.scan(roots: [home], minSize: minBytes, policy: policy) {
                guard !Task.isCancelled else { return }
                guard seen.insert(file.id).inserted else { continue }
                buffer.append(file)
                if buffer.count >= 25 {
                    self.files.append(contentsOf: buffer)
                    self.applySort()
                    buffer.removeAll(keepingCapacity: true)
                    await Task.yield()   // let the List render this batch
                }
            }
            if !buffer.isEmpty {
                self.files.append(contentsOf: buffer)
                self.applySort()
            }
            self.scanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanning = false
    }

    var selectedFiles: [LargeFile] {
        files.filter { selection.contains($0.id) }
    }

    var selectedSize: Int64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    func moveToTrash(model: AppModel) {
        let chosen = selectedFiles
        guard !chosen.isEmpty else { return }
        let items = chosen.map { file in
            ScanItem(
                ruleID: "large-files",
                category: .largeFiles,
                url: file.url,
                displayName: file.name,
                detail: file.url.deletingLastPathComponent().path,
                size: file.size,
                fileCount: 1,
                newestModification: file.modified,
                tier: .explicitOnly,
                domain: .user
            )
        }
        Task {
            let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist)
            let session = await cleaner.clean(items: items, source: .largeFiles, permanentDelete: false)
            await model.history.add(session)
            await model.refreshHistorySummary()
            model.refreshDisk()
            let removed = Set(session.items.map(\.originalPath))
            self.files.removeAll { removed.contains($0.url.path) }
            self.selection = []
            self.statusMessage = "Moved \(session.totalFreed.sweepBytes) to Trash."
        }
    }
}

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model

    private var large: LargeFilesModel { model.largeFiles }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                SectionHeader(
                    title: "Large Files",
                    subtitle: "Big files in your home folder. Nothing is selected for you — review and choose."
                )
                Spacer()
                Picker("Sort", selection: Binding(get: { large.sort }, set: { large.sort = $0 })) {
                    ForEach(LargeFileSort.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 150)
                Picker("Min size", selection: Binding(get: { large.minSizeMB }, set: { large.minSizeMB = $0 })) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                }
                .frame(width: 150)
                if large.scanning {
                    Button("Stop") { large.cancel() }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button {
                        large.scan(model: model)
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(HeroButtonStyle())
                }
            }

            if let status = large.statusMessage {
                StatusPill(text: status, color: Theme.mint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if large.files.isEmpty && !large.scanning {
                SweepEmptyState(
                    symbol: "doc.badge.clock",
                    title: "Find space hogs",
                    message: "Scans your home folder for files over the size threshold. Documents, Desktop, Photos and cloud folders are left alone."
                )
            } else {
                List {
                    ForEach(large.files) { file in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { large.selection.contains(file.id) },
                                set: { on in
                                    if on { large.selection.insert(file.id) }
                                    else { large.selection.remove(file.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                .resizable()
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                Text(file.url.deletingLastPathComponent().path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(file.url.path)
                            }
                            Spacer()
                            Text(file.displayDate?.sweepRelative ?? "Unknown date")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .frame(width: 88, alignment: .trailing)
                                .help(file.displayDate.map { "Last modified \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No reliable date on this file")
                            ByteText(bytes: file.size, font: .system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 74, alignment: .trailing)
                        }
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                            Button("Open") { NSWorkspace.shared.open(file.url) }
                        }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
                )

                HStack {
                    if large.scanning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scanning… \(large.files.count) found")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(large.files.count) files")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    let allSelected = !large.files.isEmpty && large.selection.count == large.files.count
                    Button(allSelected ? "Clear" : "Select all") {
                        large.selection = allSelected ? [] : Set(large.files.map(\.id))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(large.files.isEmpty)
                    Button {
                        large.moveToTrash(model: model)
                    } label: {
                        Label(large.selection.isEmpty ? "Select files to remove" : "Move \(large.selectedSize.sweepBytes) to Trash",
                              systemImage: "trash")
                    }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(large.selection.isEmpty)
                }
            }
        }
        .padding(24)
    }
}
