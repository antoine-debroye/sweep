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
    /// The engine address when docker points at another machine; prune and
    /// the usage report are withheld while it does.
    var dockerRemoteEndpoint: String?
    var brewPreview: BrewCleanupPreview?
    var toolOutputs: [String: ToolRun] = [:]
    var simulators = SimulatorInventory()
    var simulatorSelection: Set<String> = []
    var simulatorBusy = false
    var simulatorStatus: String?
    var confirmSimulatorRemoval = false

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
        let running = RunningApps.snapshot()
        let engine = ScanEngine(policy: model.policy, whitelist: model.settings.whitelist,
                                runningBundleIDs: running.bundleIDs, runningAppNames: running.names)
        let devRules = RuleCatalog.rules().filter { $0.category == .developer }
        let devFolders = model.settings.devFolders.map { URL(fileURLWithPath: $0) }
        let minAge = artifactMinAgeDays
        let policy = model.policy

        Task {
            let report = await engine.scanReport(rules: devRules)
            var seen = Set<String>()
            self.items = ScanItem.collapsingNested(report.items.filter { seen.insert($0.url.path).inserted })
                .sorted { $0.size > $1.size }
            self.selection.formUnion(report.items.filter { $0.tier == .safe }.map(\.id))

            let found = await Task.detached(priority: .userInitiated) {
                ProjectArtifactScanner.scan(devFolders: devFolders, minAgeDays: minAge, policy: policy)
            }.value
            self.artifacts = found

            self.worktrees = await WorktreeScanner.scan(devFolders: devFolders, policy: policy)

            self.scanning = false
            self.fetchDockerDF()
            self.fetchBrewPreview()
            await self.scanSimulators()
        }
    }

    // MARK: - Simulators

    func scanSimulators() async {
        simulatorSelection = []
        simulators = await SimulatorScanner.inventory()
    }

    var selectedRuntimes: [SimulatorRuntime] {
        simulators.runtimes.filter { simulatorSelection.contains($0.id) }
    }

    var selectedDevices: [SimulatorDevice] {
        simulators.allDevices.filter { simulatorSelection.contains($0.id) }
    }

    var selectedSimulatorSize: Int64 {
        selectedRuntimes.reduce(0) { $0 + $1.sizeBytes + $1.devicesSize }
            + selectedDevices.reduce(0) { $0 + $1.totalSize }
    }

    func selectSuggestedSimulators() {
        let suggestion = SimulatorScanner.suggest(simulators)
        simulatorSelection = suggestion.runtimeIDs.union(suggestion.deviceIDs)
    }

    /// Runtimes that share a disk image select and deselect as one unit.
    func toggleSimulator(_ id: String) {
        var unit: Set<String> = [id]
        if let runtime = simulators.runtimes.first(where: { $0.id == id }) {
            unit.formUnion(runtime.linkedRuntimeIDs)
        }
        if simulatorSelection.contains(id) { simulatorSelection.subtract(unit) } else { simulatorSelection.formUnion(unit) }
    }

    /// Permanent: simctl has no Trash. Devices on a runtime being removed are
    /// deleted with it, so they are not sent separately.
    func removeSelectedSimulators(model: AppModel) {
        let runtimes = selectedRuntimes
        let devices = SimulatorScanner.devicesToDeleteExplicitly(
            selectedDevices: selectedDevices, removingRuntimes: runtimes, inventory: simulators
        )
        guard !runtimes.isEmpty || !devices.isEmpty, !simulatorBusy else { return }
        simulatorBusy = true
        simulatorStatus = nil
        Task {
            let result = await SimulatorScanner.remove(runtimes: runtimes, devices: devices)
            var cleaned: [CleanedItem] = []
            for runtime in result.removedRuntimes {
                cleaned.append(CleanedItem(
                    originalPath: "simctl runtime \(runtime.id)", trashPath: nil,
                    size: runtime.sizeBytes + runtime.devicesSize,
                    displayName: "Simulator runtime \(runtime.displayName)", category: .developer
                ))
            }
            for device in result.removedDevices {
                cleaned.append(CleanedItem(
                    originalPath: device.dataPath, trashPath: nil, size: device.totalSize,
                    displayName: "Simulator \(device.name) (\(device.runtimeLabel))", category: .developer
                ))
            }
            if !cleaned.isEmpty {
                let session = CleanSession(date: Date(), source: .devCleaner, items: cleaned, errors: result.errors)
                await model.history.add(session)
                await model.refreshHistorySummary()
            }
            model.refreshDisk()
            self.simulatorStatus = result.errors.isEmpty
                ? "Removed \(result.removedRuntimes.count) runtime(s), \(result.removedDevices.count) device(s) · \(result.freed.sweepBytes)."
                : "Freed \(result.freed.sweepBytes) · " + result.errors.prefix(2).joined(separator: " · ")
            await self.scanSimulators()
            self.simulatorBusy = false
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
            // Trash-first: nothing is freed until the Trash is emptied.
            let moved = session.items.contains { $0.trashPath != nil }
            var status = moved
                ? "Moved \(session.totalFreed.sweepBytes) to the Trash — empty it to free the space."
                : "Deleted \(session.totalFreed.sweepBytes)."
            if let kept = session.errors.first { status += " · " + kept }
            self.statusMessage = status
        }
    }

    private func fetchDockerDF() {
        guard let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        Task {
            if let remote = await Self.remoteDockerEndpoint(docker) {
                self.dockerRemoteEndpoint = remote
                self.dockerDF = nil
                return
            }
            self.dockerRemoteEndpoint = nil
            let result = await ProcessRunner.run(docker, ["system", "df", "--format", DockerDiskUsage.format], timeout: 10)
            if result.status == 0, !result.stdout.isEmpty {
                self.dockerDF = DockerDiskUsage.summary(result.stdout)
            }
        }
    }

    /// The engine address when the current docker context is not this Mac,
    /// nil when it is local. A context that cannot be read counts as remote:
    /// prune must not run against an engine nobody identified.
    nonisolated static func remoteDockerEndpoint(_ docker: String) async -> String? {
        let result = await ProcessRunner.run(docker, DockerEndpoint.inspectArguments, timeout: 10)
        guard result.status == 0 else { return "unknown (docker context inspect failed)" }
        let endpoint = DockerEndpoint.effective(
            dockerHost: ProcessInfo.processInfo.environment["DOCKER_HOST"],
            contextHost: result.stdout
        )
        return DockerEndpoint.isLocal(endpoint) ? nil : endpoint
    }

    /// brew's own dry run, so the row says what it frees before it runs.
    private func fetchBrewPreview() {
        guard let brew = Self.tools.first(where: { $0.id == "brew" }),
              FileManager.default.isExecutableFile(atPath: brew.executable) else { return }
        Task {
            let result = await ProcessRunner.run(
                brew.executable, BrewCleanupPreview.cleanupArguments + ["--dry-run"],
                timeout: 120, environment: BrewCleanupPreview.environment
            )
            if result.status == 0 { self.brewPreview = BrewCleanupPreview.parse(result.stdout) }
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
        var environment: [String: String] = [:]
    }

    static let tools: [DevTool] = [
        DevTool(
            id: "brew",
            title: "Homebrew cleanup",
            detail: "brew cleanup --prune=all — removes old versions and cached downloads. Never uninstalls formulae.",
            symbol: "mug",
            executable: "/opt/homebrew/bin/brew",
            args: BrewCleanupPreview.cleanupArguments,
            environment: BrewCleanupPreview.environment
        ),
        // No blind `simctl delete unavailable`: a device is "unavailable" both
        // when its runtime was retired on purpose and when the runtime merely
        // went missing — and in the second case the command destroys the
        // device's data. The Simulators section lists them one by one instead.
        DevTool(
            id: "docker",
            title: "Docker prune",
            detail: "docker system prune -f — unused containers, networks and dangling images. Volumes are kept.",
            symbol: "shippingbox",
            executable: "/usr/local/bin/docker",
            args: ["system", "prune", "-f"]
        ),
        DevTool(
            id: "docker-deep",
            title: "Docker deep prune",
            detail: "docker system prune -af — also removes every image not used by a container, plus the build cache. Volumes are kept; images re-pull on next run.",
            symbol: "shippingbox.fill",
            executable: "/usr/local/bin/docker",
            args: ["system", "prune", "-af"]
        ),
    ]

    func toolAvailable(_ tool: DevTool) -> Bool {
        if FileManager.default.isExecutableFile(atPath: tool.executable) { return true }
        if tool.id.hasPrefix("docker") {
            return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/docker")
        }
        return false
    }

    func run(_ tool: DevTool) {
        guard toolOutputs[tool.id]?.running != true else { return }
        toolOutputs[tool.id] = ToolRun(running: true)
        var executable = tool.executable
        if !FileManager.default.isExecutableFile(atPath: executable), tool.id.hasPrefix("docker") {
            executable = "/opt/homebrew/bin/docker"
        }
        let isDocker = tool.id.hasPrefix("docker")
        Task {
            // Re-read right before pruning: the context may have changed
            // since the row was drawn.
            if isDocker, let remote = await Self.remoteDockerEndpoint(executable) {
                self.dockerRemoteEndpoint = remote
                self.toolOutputs[tool.id] = ToolRun(
                    running: false,
                    output: "Not run: docker points at a remote engine (\(remote)). Switch to a local context first.",
                    succeeded: false
                )
                return
            }
            let result = await ProcessRunner.run(executable, tool.args, timeout: 900, environment: tool.environment)
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

                if !dev.simulators.isEmpty {
                    simulatorSection
                }

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

    private var simulatorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Simulators")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(dev.simulators.runtimes.count) runtimes · \(dev.simulators.runtimesSize.sweepBytes) · \(dev.simulators.allDevices.count) devices · \(dev.simulators.devicesSize.sweepBytes)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select suggested") { dev.selectSuggestedSimulators() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(dev.simulatorBusy)
            }
            if let status = dev.simulatorStatus {
                StatusPill(text: status, color: Theme.mint)
            }

            Text("Runtimes")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(dev.simulators.runtimes) { runtime in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { dev.simulatorSelection.contains(runtime.id) },
                        set: { _ in dev.toggleSimulator(runtime.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!runtime.deletable)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(runtime.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Text(runtimeDetail(runtime))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !runtime.isReady {
                        StatusPill(text: "unusable", color: Theme.amber)
                    } else if runtime.isNewestForPlatform {
                        StatusPill(text: "newest \(runtime.platform)", color: Theme.mint)
                    }
                    if let linked = dev.simulators.runtimes.first(where: { runtime.linkedRuntimeIDs.contains($0.id) }) {
                        StatusPill(text: "shares image with \(linked.displayName)", color: Theme.amber)
                    }
                    ByteText(bytes: runtime.sizeBytes + runtime.devicesSize, font: .system(size: 11.5, weight: .semibold, design: .rounded))
                        .frame(width: 70, alignment: .trailing)
                }
            }

            let devices = dev.simulators.allDevices.filter { $0.totalSize > 0 }
            if !devices.isEmpty {
                Text("Devices")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(devices) { device in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { dev.simulatorSelection.contains(device.id) },
                            set: { _ in dev.toggleSimulator(device.id) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(device.state == "Booted")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(deviceDetail(device))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if device.state == "Booted" {
                            StatusPill(text: "running", color: Theme.coral)
                        } else if !device.isAvailable {
                            StatusPill(text: "runtime missing", color: Theme.amber)
                        }
                        ByteText(bytes: device.totalSize, font: .system(size: 11.5, weight: .semibold, design: .rounded))
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }

            HStack {
                Text("Removed with xcrun simctl — permanent, not undoable. Removing a runtime also removes its devices; Xcode re-downloads runtimes on demand.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if dev.simulatorBusy { ProgressView().controlSize(.small) }
                Button {
                    dev.confirmSimulatorRemoval = true
                } label: {
                    Label(dev.simulatorSelection.isEmpty ? "Select simulators to remove" : "Remove \(dev.selectedSimulatorSize.sweepBytes)",
                          systemImage: "trash")
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(dev.simulatorSelection.isEmpty || dev.simulatorBusy)
            }
        }
        .sweepCard()
        .confirmationDialog(
            "Remove \(dev.selectedRuntimes.count) runtime(s) and \(dev.selectedDevices.count) device(s)?",
            isPresented: Binding(get: { dev.confirmSimulatorRemoval }, set: { dev.confirmSimulatorRemoval = $0 })
        ) {
            Button("Remove permanently (\(dev.selectedSimulatorSize.sweepBytes))", role: .destructive) {
                dev.removeSelectedSimulators(model: model)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Simulator runtimes and devices are deleted through simctl and cannot be restored from the Trash. Xcode can download runtimes again from Settings › Components.")
        }
    }

    private func runtimeDetail(_ runtime: SimulatorRuntime) -> String {
        var parts = ["\(runtime.devices.count) device\(runtime.devices.count == 1 ? "" : "s")"]
        if let booted = runtime.lastBooted {
            parts.append("last booted \(booted.sweepRelative)")
        } else {
            parts.append("never booted")
        }
        if !runtime.isReady { parts.append(runtime.state) }
        return parts.joined(separator: " · ")
    }

    private func deviceDetail(_ device: SimulatorDevice) -> String {
        let booted = device.lastBootedAt.map { "last booted \($0.sweepRelative)" } ?? "never booted"
        return "\(device.runtimeLabel) · \(booted)"
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
                        } else if tool.id.hasPrefix("docker"), dev.dockerRemoteEndpoint != nil {
                            StatusPill(text: "Remote context", color: .gray)
                        } else {
                            Button("Run") { dev.run(tool) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    if tool.id == "brew", let preview = dev.brewPreview, run?.output == nil {
                        Text(preview.summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if tool.id.hasPrefix("docker"), let df = dev.dockerDF {
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
