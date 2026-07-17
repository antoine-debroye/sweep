import SwiftUI
import SweepCore

@MainActor
@Observable
final class OptimizeModel {
    struct ActionState {
        var running = false
        var output: String?
        var succeeded: Bool?
    }

    var states: [String: ActionState] = [:]

    enum Kind {
        case maintenance(MaintenanceTask)
        case purge
        case command(path: String, args: [String])
    }

    struct OptimizeAction: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let needsAdmin: Bool
        let kind: Kind
    }

    static let actions: [OptimizeAction] = [
        OptimizeAction(
            id: "purge",
            title: "Flush RAM",
            detail: "Frees inactive memory and the disk cache (system purge).",
            symbol: "bolt.fill",
            needsAdmin: true,
            kind: .purge
        ),
        OptimizeAction(
            id: "dns",
            title: "Flush DNS cache",
            detail: "Clears the resolver cache — fixes many \"site won't load\" oddities.",
            symbol: "network",
            needsAdmin: true,
            kind: .maintenance(.flushDNS)
        ),
        OptimizeAction(
            id: "spotlight",
            title: "Rebuild Spotlight index",
            detail: "Erases and rebuilds the search index. Indexing takes a while afterwards.",
            symbol: "magnifyingglass.circle",
            needsAdmin: true,
            kind: .maintenance(.rebuildSpotlight)
        ),
        OptimizeAction(
            id: "snapshots",
            title: "Thin Time Machine snapshots",
            detail: "Asks macOS to reclaim space held by local APFS snapshots.",
            symbol: "clock.arrow.circlepath",
            needsAdmin: true,
            kind: .maintenance(.thinLocalSnapshots)
        ),
        OptimizeAction(
            id: "launchservices",
            title: "Rebuild Launch Services",
            detail: "Fixes duplicate \"Open With\" menu entries.",
            symbol: "menucard",
            needsAdmin: false,
            kind: .command(
                path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                args: ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]
            )
        ),
        OptimizeAction(
            id: "finder",
            title: "Restart Finder",
            detail: "Relaunches Finder if it's acting up.",
            symbol: "faceid",
            needsAdmin: false,
            kind: .command(path: "/usr/bin/killall", args: ["Finder"])
        ),
        OptimizeAction(
            id: "dock",
            title: "Restart Dock",
            detail: "Relaunches the Dock (also resets Mission Control).",
            symbol: "dock.rectangle",
            needsAdmin: false,
            kind: .command(path: "/usr/bin/killall", args: ["Dock"])
        ),
    ]

    func run(_ action: OptimizeAction, model: AppModel) {
        guard states[action.id]?.running != true else { return }
        states[action.id] = ActionState(running: true)
        Task {
            var output: String
            var ok: Bool
            do {
                switch action.kind {
                case .purge:
                    output = try await model.broker.purgeMemory()
                    ok = true
                case .maintenance(let task):
                    output = try await model.broker.runMaintenance(task)
                    ok = true
                case .command(let path, let args):
                    let result = await ProcessRunner.run(path, args)
                    output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                    ok = result.status == 0
                }
            } catch {
                output = error.localizedDescription
                ok = false
            }
            self.states[action.id] = ActionState(
                running: false,
                output: output.isEmpty ? "Done." : output,
                succeeded: ok
            )
        }
    }
}

struct OptimizeView: View {
    @Environment(AppModel.self) private var model

    private var optimize: OptimizeModel { model.optimize }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    SectionHeader(
                        title: "Optimize",
                        subtitle: "System maintenance, one click each. Admin actions use the helper or ask for your password."
                    )
                    Spacer()
                    if model.broker.helperState == .enabled {
                        StatusPill(text: "Helper active — no password prompts", color: Theme.mint)
                    }
                }

                VStack(spacing: 2) {
                    ForEach(OptimizeModel.actions) { action in
                        let state = optimize.states[action.id]
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Image(systemName: action.symbol)
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.accentGradient)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(action.title)
                                            .font(.system(size: 13, weight: .medium))
                                        if action.needsAdmin {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                                .help("Requires administrator access")
                                        }
                                    }
                                    Text(action.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if state?.running == true {
                                    ProgressView().controlSize(.small)
                                } else if state?.succeeded == true {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Theme.mint)
                                        Button("Run again") { optimize.run(action, model: model) }
                                            .buttonStyle(SecondaryButtonStyle())
                                    }
                                } else {
                                    Button("Run") { optimize.run(action, model: model) }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                            }
                            if let output = state?.output, state?.succeeded != true {
                                Text(output)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.coral)
                                    .lineLimit(4)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.vertical, 9)
                        if action.id != OptimizeModel.actions.last?.id {
                            Divider()
                        }
                    }
                }
                .sweepCard()
            }
            .padding(24)
        }
    }
}
