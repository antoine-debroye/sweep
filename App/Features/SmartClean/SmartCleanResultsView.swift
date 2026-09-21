import SwiftUI
import SweepCore

/// Review screen: categories on the left, items of the focused category on the
/// right, a persistent clean bar at the bottom.
struct SmartCleanResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var focused: CleanCategory?
    @State private var search = ""

    private var clean: SmartCleanModel { model.smartClean }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                SectionHeader(
                    title: "Review & Clean",
                    subtitle: "Found \(clean.runningTotal.sweepBytes) across \(clean.allItems.count) items in \(String(format: "%.1f", clean.scanDuration))s. Safe items are pre-selected."
                )
                Spacer()
                Button {
                    clean.reset()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            HSplitView {
                categoryList
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                itemList
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            )

            cleanBar
        }
        .onAppear { focused = focused ?? clean.categories.first }
    }

    // MARK: - Categories

    private var categoryList: some View {
        List(selection: $focused) {
            ForEach(clean.categories) { category in
                CategoryRow(category: category)
                    .tag(category)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.background.secondary)
    }

    // MARK: - Items

    @ViewBuilder
    private var itemList: some View {
        if let category = focused {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text(category.blurb)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Toggle("All", isOn: categoryToggle(category))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                TextField("Filter items", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                Divider()

                List {
                    if category == .appLeftovers, search.isEmpty {
                        let split = clean.groups(in: category)
                        ForEach(clean.blockedLeftovers) { finding in
                            BlockedLeftoverRow(finding: finding)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(split.groups) { group in
                            LeftoverGroupRow(group: group)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(split.ungrouped) { item in
                            ItemRow(item: item)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        ForEach(filteredItems(category)) { item in
                            ItemRow(item: item)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .background(.background)
        } else {
            SweepEmptyState(symbol: "tray", title: "Nothing here", message: "Select a category on the left.")
        }
    }

    private func filteredItems(_ category: CleanCategory) -> [ScanItem] {
        let items = clean.items(in: category)
        guard !search.isEmpty else { return items }
        return items.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.url.path.localizedCaseInsensitiveContains(search)
        }
    }

    private func categoryToggle(_ category: CleanCategory) -> Binding<Bool> {
        Binding(
            get: { clean.categorySelectionState(category) != false },
            set: { clean.setCategory(category, selected: $0) }
        )
    }

    // MARK: - Clean bar

    private var cleanBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                ByteText(bytes: clean.selectedSize, font: .system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accentGradient)
                Text("\(clean.selectedItems.count) items selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.settings.permanentDelete {
                StatusPill(text: "Permanent delete is ON", color: Theme.coral)
            } else {
                StatusPill(text: "Reversible · goes to Trash", color: Theme.mint)
            }
            if clean.selectedItems.contains(where: { $0.domain == .system }) {
                StatusPill(text: "Includes system files (admin)", color: Theme.amber)
            }
            Button {
                clean.clean(model: model)
            } label: {
                Label("Clean \(clean.selectedSize.sweepBytes)", systemImage: "sparkles")
                    .frame(minWidth: 150)
            }
            .buttonStyle(HeroButtonStyle())
            .disabled(clean.selectedItems.isEmpty)
        }
        .sweepCard()
    }
}

// MARK: - Rows

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanCategory

    private var clean: SmartCleanModel { model.smartClean }

    var body: some View {
        let items = clean.items(in: category)
        let total = items.reduce(0) { $0 + $1.size }
        HStack(spacing: 10) {
            Image(systemName: category.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(items.count) items")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                ByteText(bytes: total, font: .system(size: 12.5, weight: .semibold, design: .rounded))
                let selected = clean.selectedSize(in: category)
                if selected > 0 {
                    Text("\(selected.sweepBytes) selected")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.mint)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem

    private var clean: SmartCleanModel { model.smartClean }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { clean.selection.contains(item.id) },
                set: { _ in clean.toggle(item) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(item.detail.isEmpty ? item.url.path : item.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(item.url.path)
            }
            Spacer()
            SafetyBadge(tier: item.tier)
            ByteText(bytes: item.size, font: .system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }
}


// MARK: - Leftover groups

/// One departed app's data, shown as a single collapsible unit: its
/// Application Support folder plus the caches, preferences and HTTP storage it
/// scattered elsewhere. The children remain individually selectable, because
/// cleaning and undo are per-path.
private struct LeftoverGroupRow: View {
    @Environment(AppModel.self) private var model
    let group: SmartCleanModel.ItemGroup
    @State private var expanded = false

    private var clean: SmartCleanModel { model.smartClean }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(group.items) { item in
                ItemRow(item: item)
                    .padding(.leading, 6)
            }
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { clean.groupSelectionState(group) == true },
                    set: { clean.setGroup(group, selected: $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(group.items.count == 1
                         ? "1 location"
                         : "\(group.items.count) locations")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SafetyBadge(tier: group.items.first?.tier ?? .review)
                ByteText(bytes: group.size, font: .system(size: 12, weight: .semibold, design: .rounded))
                    .frame(width: 74, alignment: .trailing)
            }
            .padding(.vertical, 3)
        }
    }
}

/// A leftover Sweep found but refuses to offer: something is still executing
/// from inside it, so the user has to stop that first.
private struct BlockedLeftoverRow: View {
    let finding: LaunchItemFinding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.label)
                    .font(.system(size: 12.5, weight: .medium))
                Text(finding.reason)
                    .font(.system(size: 10.5))
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
        .padding(.vertical, 3)
    }
}
