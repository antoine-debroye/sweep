import SwiftUI
import AppKit
import ServiceManagement
import SweepCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Settings", subtitle: "How Sweep behaves — and what it must never touch.")

                // MARK: General
                settingsCard("General", symbol: "gearshape") {
                    Toggle("Launch at login (keeps auto-trim and the menu bar icon running)", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    Toggle("Show notifications after cleans", isOn: $settings.notificationsEnabled)
                }

                // MARK: Cleaning behavior
                settingsCard("Cleaning", symbol: "sparkles") {
                    Toggle(isOn: $settings.permanentDelete) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Delete permanently instead of moving to Trash")
                            Text("Off is safer: everything can be undone from History until you empty the Trash.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: Auto-trim
                settingsCard("Auto-Trim", symbol: "wand.and.sparkles") {
                    Toggle(isOn: $settings.autoTrimEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keep my Mac trimmed automatically")
                            Text("Quietly moves Safe-tier junk that hasn't been touched in a while to the Trash, then notifies you.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if settings.autoTrimEnabled {
                        Picker("Only touch junk untouched for", selection: $settings.autoTrimMinAgeDays) {
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                            Text("60 days").tag(60)
                            Text("90 days").tag(90)
                        }
                        Picker("Run every", selection: $settings.autoTrimIntervalHours) {
                            Text("12 hours").tag(12)
                            Text("24 hours").tag(24)
                            Text("48 hours").tag(48)
                            Text("Week").tag(168)
                        }
                        Picker("Also run when free space drops below", selection: $settings.lowDiskThresholdGB) {
                            Text("10 GB").tag(10)
                            Text("15 GB").tag(15)
                            Text("25 GB").tag(25)
                            Text("50 GB").tag(50)
                        }
                        if let last = settings.lastAutoTrim {
                            Text("Last auto-trim: \(last.sweepRelative)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: Whitelist
                settingsCard("Never touch these", symbol: "shield.lefthalf.filled") {
                    Text("Documents, Desktop, Photos, Mail, iCloud and cloud-drive folders are always protected. Add anything else Sweep should ignore:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(settings.whitelist, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                settings.whitelist.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        addWhitelistFolder()
                    } label: {
                        Label("Add folder…", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                // MARK: Dev folders
                settingsCard("Developer folders", symbol: "hammer") {
                    Text("Where Sweep looks for stale project artifacts (node_modules, build folders…).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(settings.devFolders, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                settings.devFolders.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        addDevFolder()
                    } label: {
                        Label("Add folder…", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                // MARK: Permissions
                settingsCard("Permissions", symbol: "lock.shield") {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Full Disk Access")
                            Text("Needed to scan Mail, Safari and some app containers.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.fullDiskAccess {
                            StatusPill(text: "Granted", color: Theme.mint)
                        } else {
                            Button("Open System Settings") { model.openFullDiskAccessSettings() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Privileged helper")
                            Text(model.broker.helperState.label + " — flushes RAM and cleans system files without password prompts.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            if let error = model.broker.lastError {
                                Text(error)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.coral)
                            }
                        }
                        Spacer()
                        switch model.broker.helperState {
                        case .enabled:
                            HStack(spacing: 8) {
                                StatusPill(text: "Active", color: Theme.mint)
                                Button("Remove") { model.broker.uninstallHelper() }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        case .requiresApproval:
                            Button("Approve in System Settings") { SMAppService.openSystemSettingsLoginItems() }
                                .buttonStyle(SecondaryButtonStyle())
                        default:
                            Button("Install") { model.broker.installHelper() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    Text("Without the helper, admin actions fall back to the standard macOS password prompt.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                // MARK: About
                settingsCard("About", symbol: "info.circle") {
                    HStack {
                        Text("Sweep 1.0")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("Built for Antoine · inspired by tw93/mole")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            model.checkFullDiskAccess()
            model.broker.refreshHelperState()
        }
    }

    private func settingsCard(_ title: String, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sweepCard()
    }

    private func addWhitelistFolder() {
        pickFolder { url in
            if !model.settings.whitelist.contains(url.path) {
                model.settings.whitelist.append(url.path)
            }
        }
    }

    private func addDevFolder() {
        pickFolder { url in
            if !model.settings.devFolders.contains(url.path) {
                model.settings.devFolders.append(url.path)
            }
        }
    }

    private func pickFolder(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }
}
