import Foundation
import AppKit
import SweepCore

/// Background auto-trim: while Sweep runs (menu bar / launch-at-login), checks
/// hourly whether a trim is due — either the regular interval elapsed or disk
/// space dropped below the threshold. Only Safe-tier, user-domain rules with
/// the age gate raised to the user's setting; always Trash-first; always
/// logged to History; notifies with the result.
@MainActor
final class AutoTrimScheduler {
    private weak var model: AppModel?
    private var loop: Task<Void, Never>?
    private(set) var running = false

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // First check shortly after launch, then hourly.
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.tickIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func tickIfDue() async {
        guard let model, model.settings.autoTrimEnabled, !running else { return }
        // Never trim before the user has been through onboarding.
        guard model.settings.hasCompletedOnboarding else { return }
        // Never race a user-driven scan or clean.
        guard model.smartClean.phase == .idle || model.smartClean.phase == .results else { return }

        model.refreshDisk()
        let interval = TimeInterval(model.settings.autoTrimIntervalHours) * 3600
        // Fresh install: anchor the schedule now so the first background trim
        // happens one full interval after setup, not immediately.
        if model.settings.lastAutoTrim == nil {
            model.settings.lastAutoTrim = Date()
            return
        }
        let last = model.settings.lastAutoTrim ?? .distantPast
        let intervalDue = Date().timeIntervalSince(last) >= interval
        // Low-disk trigger re-arms at most every 6 hours so it can't loop.
        let lowDiskDue = model.lowDiskSpace && Date().timeIntervalSince(last) >= 6 * 3600

        guard intervalDue || lowDiskDue else { return }
        await run(reason: intervalDue ? "scheduled" : "low disk space")
    }

    func run(reason: String) async {
        guard let model, !running else { return }
        running = true
        defer { running = false }

        let running = RunningApps.snapshot()
        let engine = ScanEngine(policy: model.policy, whitelist: model.settings.whitelist,
                                runningBundleIDs: running.bundleIDs, runningAppNames: running.names)
        let rules = RuleCatalog.autoTrimRules(minAgeDays: model.settings.autoTrimMinAgeDays)
        let report = await engine.scanReport(rules: rules)
        model.settings.lastAutoTrim = Date()

        guard !report.items.isEmpty else { return }
        let cleaner = Cleaner(policy: model.policy, whitelist: model.settings.whitelist)
        let session = await cleaner.clean(items: report.items, source: .autoTrim, permanentDelete: false)
        await model.history.add(session)
        await model.refreshHistorySummary()
        model.refreshDisk()

        if model.settings.notificationsEnabled, session.totalFreed > 0 {
            Notifier.post(
                title: "Sweep auto-trim (\(reason))",
                body: "Moved \(session.totalFreed.sweepBytes) of stale junk to the Trash. Undo any time from History."
            )
        }
    }
}
