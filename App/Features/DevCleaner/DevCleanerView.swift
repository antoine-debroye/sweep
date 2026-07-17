import SwiftUI
import AppKit
import SweepCore

@MainActor
@Observable
final class DevCleanerModel {
    var items: [ScanItem] = []
    var artifacts: [ScanItem] = []
    var worktrees: [AgentWorktree] = []
    var selection: Set<String> = []
    var scanning = false
    var artifactMinAgeDays = 30
    var statusMessage: String?
    var dockerDF: String?
    var toolOutputs: [String: ToolRun] = [:]

    struct ToolRun {
        var running = false
        var output: String?
        var succeeded: Bool?
    }

    func scan(model: AppModel) {
        guard !scanning else { return }
        scanning = true
        items = []
        artifacts = []
        worktrees = []
        selection = []
        statusMessage = nil

        // Editor-cache rules use skipRunningApps, so the engine needs the live
        // bundle ids or the guard is a no-op.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let engine = ScanEngine(policy: model.policy, whitelist: model.settings.whitelist, runningBundleIDs: running)
        let devRules = RuleCatalog.rules().filter { $0.category == .developer }
        let devFolders = model.settings.devFolders.map { URL(fileURLWithPath: $0) }
        let minAge = artifactMinAgeDays
        let policy = model.policy

        Task {
            let report = await engine.scanReport(rules: devRules)
            self.items = report.items.sorted { $0.size > $1.size }
            self.selection.formUnion(report.items.filter { $0.tier == .safe }.map(\.id))

            let found = await Task.detached(priority: .userInitiated) {
                ProjectArtifactScanner.scan(devFolders: devFolders, minAgeDays: minAge, policy: policy)
            }.value
            self.artifacts = found

            self.worktrees = await WorktreeScanner.scan(devFolders: devFolders, policy: policy)

            self.scanning = false
            self.fetchDockerDF()
        }
    }

    /// Clean and orphaned worktrees can be reclaimed; dirty/unverified are locked.
    var selectableWorktreeItems: [ScanItem] {
        worktrees.filter { $0.state.isSelectable }.map(\.scanItem)
    }

    var selectedItems: [ScanItem] {
        (items + artifacts + selectableWorktreeItems).filter { selection.contains($0.id) }
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    func clean(model: AppModel) {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        Task {
            let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist, privileged: model.broker)
            let session = await cleaner.clean(items: chosen, source: .devCleaner, permanentDelete: model.settings.permanentDelete)
            await model.history.add(session)
            await model.refreshHistorySummary()
            model.refreshDisk()
            let removed = Set(session.items.map(\.originalPath))
            self.items.removeAll { removed.contains($0.url.path) }
            self.artifacts.removeAll { removed.contains($0.url.path) }
            self.worktrees.removeAll { removed.contains($0.url.path) }
            self.selection = []
            self.statusMessage = "Freed \(session.totalFreed.sweepBytes)."
        }
    }

    private func fetchDockerDF() {
        guard let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        Task {
            let result = await ProcessRunner.run(docker, ["system", "df", "--format", "{{.Type}}: {{.Reclaimable}}"])
            if result.status == 0, !result.stdout.isEmpty {
                self.dockerDF = result.stdout
            }
        }
    }

    // MARK: - Command tools

    struct DevTool: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let executable: String
        let args: [String]
    }

    static let tools: [DevTool] = [
        DevTool(
            id: "brew",
            title: "Homebrew cleanup",
            detail: "brew cleanup --prune=all — removes old versions and cached downloads.",
            symbol: "mug",
            executable: "/opt/homebrew/bin/brew",
            args: ["cleanup", "--prune=all", "-s"]
        ),
        DevTool(
            id: "simctl",
            title: "Remove unavailable simulators",
            detail: "xcrun simctl delete unavailable — deletes simulators for old runtimes.",
            symbol: "iphone.gen3",
            executable: "/usr/bin/xcrun",
            args: ["simctl", "delete", "unavailable"]
        ),
        DevTool(
            id: "docker",
            title: "Docker prune",
            detail: "docker system prune -f — unused containers, networks and dangling images. Volumes are kept.",
            symbol: "shippingbox",
            executable: "/usr/local/bin/docker",
            args: ["system", "prune", "-f"]
        ),
    ]

    func toolAvailable(_ tool: DevTool) -> Bool {
        if FileManager.default.isExecutableFile(atPath: tool.executable) { return true }
        if tool.id == "docker" {
            return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/docker")
        }
        return false
    }

    func run(_ tool: DevTool) {
        guard toolOutputs[tool.id]?.running != true else { return }
        toolOutputs[tool.id] = ToolRun(running: true)
        var executable = tool.executable
        if !FileManager.default.isExecutableFile(atPath: executable), tool.id == "docker" {
            executable = "/opt/homebrew/bin/docker"
        }
        Task {
            let result = await ProcessRunner.run(executable, tool.args)
            let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            self.toolOutputs[tool.id] = ToolRun(
                running: false,
                output: output.isEmpty ? "Done." : output,
                succeeded: result.status == 0
            )
        }
    }
}

struct DevCleanerView: View {
    @Environment(AppModel.self) private var model

    private var dev: DevCleanerModel { model.devCleaner }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    SectionHeader(
                        title: "Dev Cleaner",
                        subtitle: "Xcode junk, package caches and stale build artifacts in your projects."
                    )
                    Spacer()
                    if dev.scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            dev.scan(model: model)
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(HeroButtonStyle())
                    }
                }

                if let status = dev.statusMessage {
                    StatusPill(text: status, color: Theme.mint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !dev.items.isEmpty || !dev.artifacts.isEmpty {
                    itemsSection
                }

                if !dev.worktrees.isEmpty {
                    worktreeSection
                }

                cleanBar

                toolsSection
            }
            .padding(24)
        }
        .onAppear {
            if dev.items.isEmpty && !dev.scanning {
                dev.scan(model: model)
            }
        }
    }

    private var worktreeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI agent worktrees")
                    .font(.system(size: 13, weight: .semibold))
                Text("git-checked · dirty ones are locked")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(dev.worktrees) { wt in
                HStack(spacing: 10) {
                    if wt.state.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.coral)
                            .frame(width: 18)
                            .help(wt.state == .dirty ? "Has uncommitted changes — protected" : "Couldn't verify — protected")
                    } else {
                        Toggle("", isOn: Binding(
                            get: { dev.selection.contains(wt.scanItem.id) },
                            set: { on in
                                if on { dev.selection.insert(wt.scanItem.id) }
                                else { dev.selection.remove(wt.scanItem.id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(wt.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(wt.branch.map { "branch \($0)" } ?? "worktree")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    worktreeBadge(wt)
                    ByteText(bytes: wt.size, font: .system(size: 11.5, weight: .semibold, design: .rounded))
                        .frame(width: 70, alignment: .trailing)
                }
            }
            Text("Clean and orphaned worktrees go to the Trash (recreatable). Worktrees with uncommitted work are never offered.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .sweepCard()
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !dev.items.isEmpty {
                Text("Caches & derived data")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(dev.items) { item in
                    DevItemRow(item: item)
                }
            }
            if !dev.artifacts.isEmpty {
                HStack {
                    Text("Project artifacts")
                        .font(.system(size: 13, weight: .semibold))
                    Text("older than \(dev.artifactMinAgeDays) days")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                ForEach(dev.artifacts) { item in
                    DevItemRow(item: item)
                }
            }
        }
        .sweepCard()
    }

    @ViewBuilder
    private func worktreeBadge(_ wt: AgentWorktree) -> some View {
        switch wt.state {
        case .dirty:
            StatusPill(text: "\(wt.dirtyCount) uncommitted", color: Theme.coral)
        case .orphaned:
            StatusPill(text: "orphaned", color: Theme.amber)
        case .unverified:
            StatusPill(text: "unverified", color: .gray)
        case .clean:
            EmptyView()
        }
    }

    @ViewBuilder
    private var cleanBar: some View {
        if !dev.selection.isEmpty {
            HStack {
                Text("\(dev.selectedItems.count) selected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    dev.clean(model: model)
                } label: {
                    Label("Clean \(dev.selectedSize.sweepBytes)", systemImage: "sparkles")
                }
                .buttonStyle(HeroButtonStyle())
            }
            .sweepCard()
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tool maintenance")
                .font(.system(size: 13, weight: .semibold))
            ForEach(DevCleanerModel.tools) { tool in
                let run = dev.toolOutputs[tool.id]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.accentGradient)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.title)
                                .font(.system(size: 12.5, weight: .medium))
                            Text(tool.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if run?.running == true {
                            ProgressView().controlSize(.small)
                        } else if !dev.toolAvailable(tool) {
                            StatusPill(text: "Not installed", color: .gray)
                        } else {
                            Button("Run") { dev.run(tool) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    if tool.id == "docker", let df = dev.dockerDF {
                        Text("Reclaimable now:\n\(df)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let output = run?.output {
                        Text(output)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(run?.succeeded == true ? Color.secondary : Theme.coral)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .sweepCard()
    }
}

private struct DevItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem

    private var dev: DevCleanerModel { model.devCleaner }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { dev.selection.contains(item.id) },
                set: { on in
                    if on { dev.selection.insert(item.id) } else { dev.selection.remove(item.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(item.url.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(item.url.path)
            }
            Spacer()
            SafetyBadge(tier: item.tier)
            ByteText(bytes: item.size, font: .system(size: 11.5, weight: .semibold, design: .rounded))
                .frame(width: 70, alignment: .trailing)
        }
    }
}
