import SwiftUI
import Charts
import SweepCore

@MainActor
@Observable
final class MemoryModel {
    var current: MemorySnapshot?
    var samples: [MemorySnapshot] = []
    var topProcesses: [TopProcess] = []
    var flushing = false
    var lastFlushFreed: Int64?
    var lastFlushError: String?

    /// Only the Memory screen needs the per-process breakdown; the dashboard and
    /// menu bar just read `current`. Gate the expensive `ps` poll on this so we
    /// don't spawn a subprocess every few seconds for the app's whole lifetime.
    var wantsProcessDetail = false

    private var samplerTask: Task<Void, Never>?

    func startSampling() {
        guard samplerTask == nil else { return }
        samplerTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let snapshot = MemoryStats.sample() {
                    self.current = snapshot
                    self.samples.append(snapshot)
                    if self.samples.count > 90 { self.samples.removeFirst(self.samples.count - 90) }
                }
                if self.wantsProcessDetail, tick % 3 == 0 {
                    self.topProcesses = await ProcessStats.topByMemory(limit: 8)
                }
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopSampling() {
        samplerTask?.cancel()
        samplerTask = nil
    }

    func flush(model: AppModel) {
        guard !flushing else { return }
        flushing = true
        lastFlushFreed = nil
        lastFlushError = nil
        let before = MemoryStats.sample()

        Task {
            do {
                _ = try await model.broker.purgeMemory()
                try? await Task.sleep(for: .seconds(3))
                let after = MemoryStats.sample()
                if let before, let after {
                    self.lastFlushFreed = max(0, after.free - before.free)
                }
                if model.settings.notificationsEnabled, let freed = self.lastFlushFreed, freed > 0 {
                    Notifier.post(title: "Memory flushed", body: "Freed \(freed.sweepMemory) of RAM.")
                }
            } catch {
                self.lastFlushError = error.localizedDescription
            }
            self.flushing = false
        }
    }
}

struct MemoryView: View {
    @Environment(AppModel.self) private var model

    private var memory: MemoryModel { model.memory }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    SectionHeader(title: "Memory", subtitle: "Live memory pressure, biggest consumers, and one-click flush.")
                    Spacer()
                    FlushRAMButton()
                }

                HStack(spacing: 14) {
                    pressureCard
                        .frame(width: 250)
                    chartCard
                }
                .frame(height: 230)

                processCard
            }
            .padding(24)
        }
        .onAppear { memory.wantsProcessDetail = true }
        .onDisappear { memory.wantsProcessDetail = false }
    }

    private var pressureCard: some View {
        VStack(spacing: 12) {
            if let snapshot = memory.current {
                ZStack {
                    GaugeRing(
                        value: snapshot.usedFraction,
                        lineWidth: 13,
                        tint: AnyShapeStyle(Theme.pressureColor(snapshot.usedFraction).gradient)
                    )
                    .frame(width: 120, height: 120)
                    VStack(spacing: 0) {
                        Text("\(Int(snapshot.usedFraction * 100))%")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text(snapshot.pressure.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 4) {
                    row("Used", snapshot.used)
                    row("App memory", snapshot.appMemory)
                    row("Wired", snapshot.wired)
                    row("Compressed", snapshot.compressed)
                    row("Free", snapshot.free)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sweepCard()
    }

    private func row(_ label: String, _ bytes: Int64) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(bytes.sweepMemory)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pressure over time")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let freed = memory.lastFlushFreed {
                    StatusPill(text: "Flush freed \(freed.sweepMemory)", color: Theme.mint)
                }
                if let error = memory.lastFlushError {
                    StatusPill(text: error, color: Theme.coral)
                }
            }
            if memory.samples.count > 1 {
                Chart(memory.samples, id: \.date) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        y: .value("Used", sample.usedFraction * 100)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.azure.opacity(0.45), Theme.azure.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Used", sample.usedFraction * 100)
                    )
                    .foregroundStyle(Theme.accentGradient)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) { Text("\(v)%") }
                        }
                    }
                }
                .chartXAxis(.hidden)
            } else {
                SweepEmptyState(symbol: "waveform.path.ecg", title: "Sampling…", message: "The pressure graph appears after a few seconds.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sweepCard()
    }

    private var processCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top memory consumers")
                .font(.system(size: 13, weight: .semibold))
            if memory.topProcesses.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                let maxBytes = memory.topProcesses.first?.memoryBytes ?? 1
                ForEach(memory.topProcesses) { process in
                    HStack(spacing: 10) {
                        Text(process.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .frame(width: 200, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Theme.accentGradient)
                                .frame(width: max(4, geo.size.width * CGFloat(process.memoryBytes) / CGFloat(maxBytes)))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 7)
                        Text(process.memoryBytes.sweepMemory)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
        .sweepCard()
    }
}

/// Shared flush button (Dashboard, Memory, menu bar).
struct FlushRAMButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.memory.flush(model: model)
        } label: {
            if model.memory.flushing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Flushing…")
                }
                .frame(minWidth: 110)
            } else {
                Label("Flush RAM", systemImage: "bolt.fill")
                    .frame(minWidth: 110)
            }
        }
        .buttonStyle(HeroButtonStyle())
        .disabled(model.memory.flushing)
        .help("Runs the system purge command with administrator access. Frees inactive memory and disk cache.")
    }
}
