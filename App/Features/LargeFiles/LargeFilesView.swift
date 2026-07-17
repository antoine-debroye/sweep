import SwiftUI
import AppKit
import SweepCore

@MainActor
@Observable
final class LargeFilesModel {
    var files: [LargeFile] = []
    var scanning = false
    var selection: Set<String> = []
    var minSizeMB: Int = 100
    var statusMessage: String?

    private var scanTask: Task<Void, Never>?

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
            for await file in LargeFileScanner.scan(roots: [home], minSize: minBytes, policy: policy) {
                guard !Task.isCancelled else { return }
                self.files.append(file)
                self.files.sort { $0.size > $1.size }
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
                Picker("Min size", selection: Binding(get: { large.minSizeMB }, set: { large.minSizeMB = $0 })) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                }
                .frame(width: 200)
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
                            if let modified = file.modified {
                                Text(modified.sweepRelative)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 70, alignment: .trailing)
                            }
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
                    Button {
                        large.moveToTrash(model: model)
                    } label: {
                        Label("Move \(large.selectedSize.sweepBytes) to Trash", systemImage: "trash")
                    }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(large.selection.isEmpty)
                }
            }
        }
        .padding(24)
    }
}
