import SwiftUI
import ServiceManagement
import SweepCore

/// First-launch flow: welcome → Full Disk Access → helper → notifications.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    @State private var fdaTimer: Task<Void, Never>?

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Group {
                switch page {
                case 0: welcome
                case 1: fullDiskAccess
                case 2: helper
                default: notifications
                }
            }
            .frame(maxWidth: 460)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(page)
            Spacer(minLength: 16)

            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.quaternary))
                        .frame(width: index == page ? 22 : 7, height: 7)
                }
            }
            .padding(.bottom, 16)

            HStack {
                if page > 0 {
                    Button("Back") { withAnimation(.spring(duration: 0.35)) { page -= 1 } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                if page < pageCount - 1 {
                    Button(skipLabel) { withAnimation(.spring(duration: 0.35)) { page += 1 } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Button("Continue") { withAnimation(.spring(duration: 0.35)) { page += 1 } }
                        .buttonStyle(HeroButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start using Sweep") {
                        model.settings.hasCompletedOnboarding = true
                    }
                    .buttonStyle(HeroButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .background(.background)
        .interactiveDismissDisabled()
        .onAppear { startFDAPolling() }
        .onDisappear { fdaTimer?.cancel() }
    }

    private var skipLabel: String {
        switch page {
        case 1, 2: "Skip for now"
        default: " "
        }
    }

    private func startFDAPolling() {
        fdaTimer = Task {
            while !Task.isCancelled {
                model.checkFullDiskAccess()
                model.broker.refreshHelperState()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Pages

    private var welcome: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.heroGradient.opacity(0.18))
                    .frame(width: 150, height: 150)
                    .blur(radius: 24)
                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            Text("Welcome to Sweep")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Deep-cleans your Mac like mole, with a proper app around it.\nEverything is previewed before removal, goes to the Trash first, and can be undone from History.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            HStack(spacing: 14) {
                pill("checkmark.shield", "Trash-first")
                pill("eye", "Preview always")
                pill("arrow.uturn.backward", "Undo built-in")
            }
            .padding(.top, 6)
        }
    }

    private func pill(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private var fullDiskAccess: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.person.crop")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text("Full Disk Access")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("macOS hides Mail, Safari and some app data from apps by default. Granting Full Disk Access lets Sweep scan everything — it still never deletes without your review.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            VStack(alignment: .leading, spacing: 8) {
                step("1", "Click the button below — System Settings opens on the right pane.")
                step("2", "Enable **Sweep** in the list (add it with + if missing).")
                step("3", "Come back here — the badge flips to Granted.")
            }
            .padding(.vertical, 4)

            if model.fullDiskAccess {
                StatusPill(text: "Granted — you're all set", color: Theme.mint)
            } else {
                Button {
                    model.openFullDiskAccessSettings()
                } label: {
                    Label("Open Full Disk Access settings", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(HeroButtonStyle())
            }
        }
    }

    private var helper: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text("Administrator helper")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Flushing RAM and cleaning system caches needs admin rights. Install the helper once and Sweep never has to ask for your password again.\n\nSkip it and Sweep simply shows the standard macOS password prompt when needed.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            switch model.broker.helperState {
            case .enabled:
                StatusPill(text: "Helper installed & active", color: Theme.mint)
            case .requiresApproval:
                VStack(spacing: 8) {
                    StatusPill(text: "Waiting for approval", color: Theme.amber)
                    Text("Enable **Sweep** under System Settings → General → Login Items & Extensions → Allow in Background.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            default:
                Button {
                    model.broker.installHelper()
                } label: {
                    Label("Install helper", systemImage: "key.fill")
                }
                .buttonStyle(HeroButtonStyle())
            }
            if let error = model.broker.lastError {
                Text("Helper couldn't be installed (\(error)). No problem — Sweep will use password prompts instead.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var notifications: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.badge")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text("Stay in the loop")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Sweep auto-trims old junk in the background (30-day age gate, Trash-first). A notification tells you what was freed — with undo one click away in History.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                Task { _ = await Notifier.requestAuthorization() }
            } label: {
                Label("Enable notifications", systemImage: "bell")
            }
            .buttonStyle(HeroButtonStyle())
            Toggle("Keep auto-trim enabled", isOn: Binding(
                get: { model.settings.autoTrimEnabled },
                set: { model.settings.autoTrimEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .padding(.top, 4)
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(Theme.accentGradient.opacity(0.2), in: Circle())
            Text(.init(text))
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
