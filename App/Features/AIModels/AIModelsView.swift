import SwiftUI
import AppKit
import SweepCore

@MainActor
@Observable
final class AIModelsModel {
    var models: [LocalModel] = []
    var scanning = false
    var busy = false
    var selection: Set<String> = []
    var statusMessage: String?

    func scan(model: AppModel) {
        guard !scanning else { return }
        scanning = true
        models = []
        selection = []
        statusMessage = nil
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ModelScanner.scan()
            }.value
            self.models = found
            self.scanning = false
        }
    }

    var byProvider: [(provider: ModelProvider, models: [LocalModel])] {
        ModelProvider.allCases.compactMap { provider in
            let items = models.filter { $0.provider == provider }
            return items.isEmpty ? nil : (provider, items)
        }
    }

    var selectedModels: [LocalModel] { models.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedModels.reduce(0) { $0 + $1.sizeBytes } }
    var totalSize: Int64 { models.reduce(0) { $0 + $1.sizeBytes } }

    func toggle(_ m: LocalModel) {
        if selection.contains(m.id) { selection.remove(m.id) } else { selection.insert(m.id) }
    }

    func removeSelected(model: AppModel) {
        let chosen = selectedModels
        guard !chosen.isEmpty, !busy else { return }
        busy = true
        statusMessage = nil

        // File-based models go to Trash via the Cleaner (reversible); Ollama
        // models are removed with `ollama rm` (its de-dup-safe command).
        let trashItems: [ScanItem] = chosen.compactMap { m in
            guard case .trashDirectory(let url) = m.removal else { return nil }
            return ScanItem(
                ruleID: "ai-model", category: .aiModels, url: url,
                displayName: m.name, detail: m.provider.label,
                size: m.sizeBytes, fileCount: 1, newestModification: m.lastUsed,
                tier: .explicitOnly, domain: .user
            )
        }
        let ollama = chosen.compactMap { m -> (LocalModel, String)? in
            if case .ollamaCommand(let name) = m.removal { return (m, name) } else { return nil }
        }

        Task {
            var cleanedItems: [CleanedItem] = []
            var errors: [String] = []
            var freed: Int64 = 0

            if !trashItems.isEmpty {
                let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist)
                let session = await cleaner.clean(items: trashItems, source: .aiModels, permanentDelete: model.settings.permanentDelete)
                cleanedItems += session.items
                errors += session.errors
                freed += session.totalFreed
            }

            if !ollama.isEmpty {
                if let binary = AIModelsModel.ollamaBinary() {
                    for (m, name) in ollama {
                        let result = await ProcessRunner.run(binary, ["rm", name])
                        if result.status == 0 {
                            cleanedItems.append(CleanedItem(
                                originalPath: m.location.path, trashPath: nil,
                                size: m.sizeBytes, displayName: m.name, category: .aiModels
                            ))
                            freed += m.sizeBytes
                        } else {
                            let msg = result.stderr.isEmpty ? result.stdout : result.stderr
                            errors.append("\(m.name): \(msg.isEmpty ? "ollama rm failed" : msg)")
                        }
                    }
                } else {
                    errors.append("Ollama CLI not found — start Ollama or install it to remove \(ollama.count) model(s).")
                }
            }

            if !cleanedItems.isEmpty {
                let session = CleanSession(date: Date(), source: .aiModels, items: cleanedItems, errors: errors)
                await model.history.add(session)
                await model.refreshHistorySummary()
            }
            model.refreshDisk()

            let removedIDs = Set(chosen.filter { m in
                cleanedItems.contains { $0.originalPath == m.location.path }
            }.map(\.id))
            self.models.removeAll { removedIDs.contains($0.id) }
            self.selection = []
            self.busy = false
            self.statusMessage = errors.isEmpty
                ? "Freed \(freed.sweepBytes)."
                : "Freed \(freed.sweepBytes) · \(errors.count) issue\(errors.count == 1 ? "" : "s"): " + errors.prefix(2).joined(separator: " · ")
        }
    }

    static func ollamaBinary() -> String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct AIModelsView: View {
    @Environment(AppModel.self) private var model
    private var ai: AIModelsModel { model.aiModels }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                SectionHeader(
                    title: "AI Models",
                    subtitle: "Local LLM & ML models. All re-downloadable — nothing is selected for you."
                )
                Spacer()
                if ai.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { ai.scan(model: model) } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(HeroButtonStyle())
                }
            }

            if let status = ai.statusMessage {
                StatusPill(text: status, color: Theme.mint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if ai.models.isEmpty && !ai.scanning {
                SweepEmptyState(
                    symbol: "brain",
                    title: "Find local models",
                    message: "Inventories Ollama, LM Studio and Hugging Face models with sizes and last-used dates so you can prune the ones you don't need."
                )
            } else {
                List {
                    ForEach(ai.byProvider, id: \.provider) { group in
                        Section {
                            ForEach(group.models) { m in
                                ModelRow(model: m)
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: group.provider.symbol)
                                Text(group.provider.label)
                                Spacer()
                                Text(group.models.reduce(Int64(0)) { $0 + $1.sizeBytes }.sweepBytes)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11.5, weight: .semibold))
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
                    Text("\(ai.models.count) models · \(ai.totalSize.sweepBytes) total")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if ai.busy { ProgressView().controlSize(.small) }
                    Button {
                        ai.removeSelected(model: model)
                    } label: {
                        Label(ai.selection.isEmpty ? "Select models to remove" : "Remove \(ai.selectedSize.sweepBytes)",
                              systemImage: "trash")
                    }
                    .buttonStyle(HeroButtonStyle())
                    .disabled(ai.selection.isEmpty || ai.busy)
                }
            }
        }
        .padding(24)
        .onAppear {
            if ai.models.isEmpty && !ai.scanning { ai.scan(model: model) }
        }
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var appModel
    let model: LocalModel
    private var ai: AIModelsModel { appModel.aiModels }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { ai.selection.contains(model.id) },
                set: { _ in ai.toggle(model) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(model.lastUsed.map { "last used \($0.sweepRelative) · \(model.detail)" } ?? model.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ByteText(bytes: model.sizeBytes, font: .system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.location])
            }
        }
    }
}
