import SwiftUI
import SweepCore

struct SmartCleanView: View {
    @Environment(AppModel.self) private var model

    private var clean: SmartCleanModel { model.smartClean }

    var body: some View {
        Group {
            switch clean.phase {
            case .idle: idle
            case .scanning: scanning
            case .results: SmartCleanResultsView()
            case .cleaning: cleaning
            case .done: done
            }
        }
        .padding(24)
    }

    // MARK: - Idle

    private var idle: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.heroGradient.opacity(0.15))
                    .frame(width: 180, height: 180)
                    .blur(radius: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 8) {
                Text("Smart Clean")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Scans caches, logs, developer junk, installers and leftovers.\nYou review everything before anything is removed.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                clean.startScan(model: model)
            } label: {
                Label("Start Smart Scan", systemImage: "magnifyingglass")
                    .frame(minWidth: 180)
            }
            .buttonStyle(HeroButtonStyle())
            .keyboardShortcut(.defaultAction)

            if !model.fullDiskAccess {
                Button {
                    model.openFullDiskAccessSettings()
                } label: {
                    Label("Grant Full Disk Access to scan Mail & Safari data", systemImage: "lock.open")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scanning

    private var scanning: some View {
        VStack(spacing: 20) {
            HStack {
                SectionHeader(title: "Scanning…", subtitle: "Looking for junk. Nothing is being deleted.")
                Spacer()
                Button("Cancel") { clean.cancelScan() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            VStack(spacing: 4) {
                Text(clean.runningTotal.sweepBytes)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: clean.runningTotal)
                    .foregroundStyle(Theme.accentGradient)
                Text("found so far")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(scanningCategories) { category in
                        HStack(spacing: 10) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.accentGradient)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                ByteText(bytes: sizeFound(category), font: .system(size: 11, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if clean.activeCategories.contains(category) {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.mint)
                                    .font(.system(size: 13))
                            }
                        }
                        .sweepCard(padding: 12)
                    }
                }
            }
        }
    }

    private var scanningCategories: [CleanCategory] {
        clean.seenCategories
            .union(clean.itemsByCategory.keys)
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func sizeFound(_ category: CleanCategory) -> Int64 {
        clean.items(in: category).reduce(0) { $0 + $1.size }
    }

    // MARK: - Cleaning

    private var cleaning: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(Theme.mint)
                .frame(maxWidth: 380)
            Text(clean.cleanProgress?.currentName ?? "Preparing…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            ByteText(bytes: clean.cleanProgress?.freedSoFar ?? 0, font: .system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accentGradient)
            Text("freed")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var progressFraction: Double {
        guard let progress = clean.cleanProgress, progress.total > 0 else { return 0 }
        return Double(progress.completed) / Double(progress.total)
    }

    // MARK: - Done

    private var done: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(Theme.mint)
                .symbolEffect(.bounce, value: clean.phase)
            Text("All clean")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            if let session = clean.lastSession {
                Text("Freed \(session.totalFreed.sweepBytes) · \(session.items.count) items")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                if !session.errors.isEmpty {
                    DisclosureGroup("\(session.errors.count) items could not be removed") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(session.errors, id: \.self) { error in
                                    Text(error)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                    .frame(maxWidth: 460)
                    .font(.system(size: 12))
                }
            }
            if let undoResult = clean.undoResult {
                StatusPill(text: undoResult, color: Theme.azure)
            }
            HStack(spacing: 12) {
                if clean.lastSession?.restorableCount ?? 0 > 0, clean.undoResult == nil {
                    Button {
                        clean.undoLastClean(model: model)
                    } label: {
                        Label("Undo (restore from Trash)", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button {
                    clean.reset()
                } label: {
                    Text("Done")
                        .frame(minWidth: 90)
                }
                .buttonStyle(HeroButtonStyle())
            }
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
