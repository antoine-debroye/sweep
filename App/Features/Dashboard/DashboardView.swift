import SwiftUI
import SweepCore

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    SectionHeader(title: greeting, subtitle: "Here's how your Mac is doing.")
                    Spacer()
                    if model.lowDiskSpace {
                        StatusPill(text: "Low disk space", color: Theme.coral)
                    }
                }

                HStack(spacing: 14) {
                    diskCard
                    memoryCard
                }
                .frame(height: 190)

                heroCard

                HStack(spacing: 14) {
                    StatTile(
                        title: "Freed with Sweep",
                        value: model.lifetimeFreed.sweepBytes,
                        symbol: "arrow.down.heart",
                        tint: Theme.mint,
                        caption: "lifetime total"
                    )
                    StatTile(
                        title: "Last clean",
                        value: model.lastClean?.sweepRelative ?? "Never",
                        symbol: "clock",
                        tint: Theme.azure,
                        caption: model.settings.autoTrimEnabled ? "auto-trim is on" : "auto-trim is off"
                    )
                    StatTile(
                        title: "Memory pressure",
                        value: model.memory.current?.pressure.label ?? "—",
                        symbol: "memorychip",
                        tint: Theme.pressureColor(model.memory.current?.usedFraction ?? 0),
                        caption: model.memory.current.map { "\($0.used.sweepMemory) of \($0.total.sweepMemory)" }
                    )
                }
            }
            .padding(24)
        }
        .onAppear { model.refreshDisk() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var diskCard: some View {
        HStack(spacing: 20) {
            ZStack {
                GaugeRing(
                    value: model.disk?.usedFraction ?? 0,
                    lineWidth: 14,
                    tint: AnyShapeStyle(Theme.pressureColor(model.disk?.usedFraction ?? 0).gradient)
                )
                .frame(width: 120, height: 120)
                VStack(spacing: 0) {
                    Text("\(Int((model.disk?.usedFraction ?? 0) * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("used")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Macintosh HD")
                    .font(.system(size: 14, weight: .semibold))
                if let disk = model.disk {
                    Text("\(disk.available.sweepBytes) available")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text("\(disk.used.sweepBytes) of \(disk.total.sweepBytes) used")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Button("Free up space") { model.section = .smartClean }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sweepCard(padding: 20)
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Memory", systemImage: "memorychip")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let snapshot = model.memory.current {
                    StatusPill(
                        text: snapshot.pressure.label,
                        color: Theme.pressureColor(snapshot.usedFraction)
                    )
                }
            }
            if let snapshot = model.memory.current {
                MemoryBar(snapshot: snapshot)
                    .frame(height: 14)
                HStack(spacing: 14) {
                    legend("App", Theme.azure, snapshot.appMemory)
                    legend("Wired", Theme.violet, snapshot.wired)
                    legend("Compressed", Theme.amber, snapshot.compressed)
                    Spacer()
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            Spacer()
            HStack {
                Spacer()
                FlushRAMButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sweepCard(padding: 20)
    }

    private func legend(_ label: String, _ color: Color, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(bytes.sweepMemory)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
        }
    }

    private var heroCard: some View {
        HStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Circle().fill(.white.opacity(0.18)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Smart Clean")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("One scan across every junk category — review, then clean with undo.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button {
                model.section = .smartClean
                if model.smartClean.phase == .idle {
                    model.smartClean.startScan(model: model)
                }
            } label: {
                Text("Scan now")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.azure)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .shadow(color: Theme.azure.opacity(0.25), radius: 16, y: 6)
    }
}

/// Stacked horizontal memory-composition bar.
struct MemoryBar: View {
    let snapshot: MemorySnapshot

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                segment(snapshot.appMemory, Theme.azure, geo.size.width)
                segment(snapshot.wired, Theme.violet, geo.size.width)
                segment(snapshot.compressed, Theme.amber, geo.size.width)
                Spacer(minLength: 0)
            }
        }
        .background(.quaternary.opacity(0.4))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func segment(_ bytes: Int64, _ color: Color, _ totalWidth: CGFloat) -> some View {
        let fraction = snapshot.total > 0 ? CGFloat(bytes) / CGFloat(snapshot.total) : 0
        Rectangle()
            .fill(color.gradient)
            .frame(width: max(0, totalWidth * fraction))
    }
}
