import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    // Key name is load-bearing: renaming it resets the preference for anyone who already set it.
    @AppStorage("OrbitConfirmBeforeQuit", store: OrbitDefaults.standard) private var confirmBeforeQuit = false

    @State private var isDefaultBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("General").font(.system(size: 20, weight: .bold))

            OrbitSettingsSection(title: "Browsing") {
                OrbitSettingsRow(title: "Warn before quitting", description: "Only prompts when multiple tabs are open.") {
                    OrbitToggle(accessibilityLabel: "Warn before quitting with multiple tabs open", isOn: $confirmBeforeQuit, accentColor: SettingsPalette.accent)
                }
            }

            OrbitSettingsSection(title: "Default browser") {
                OrbitSettingsActionRow {
                    Text(isDefaultBrowser ? "Orbit is your default browser." : "Orbit is not your default browser.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } trailing: {
                    if !isDefaultBrowser {
                        OrbitButton(title: "Make Orbit My Default Browser", kind: .primary, accentColor: SettingsPalette.accent) {
                            DefaultBrowser.requestBecomingDefault { _ in
                                Task { @MainActor in isDefaultBrowser = DefaultBrowser.isDefault }
                            }
                        }
                    }
                }
            }

            #if ORBIT_SPARKLE
            updatesSection
            #endif

            OrbitSettingsSection(title: "About") {
                OrbitSettingsActionRow(spacing: 12) {
                    HStack(spacing: 12) {
                        if let icon = NSApplication.shared.applicationIconImage {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 40, height: 40)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Orbit").font(.system(size: 13, weight: .semibold))
                            Text(orbitVersionDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } trailing: { EmptyView() }
                OrbitSettingsValueRow(title: "Engine") {
                    Text(ChromiumBuild.engineDescription).foregroundStyle(.secondary)
                }
                OrbitSettingsValueRow(title: "Chromium") {
                    Text("\(ChromiumBuild.version) · \(ChromiumBuild.channel)").foregroundStyle(.secondary)
                }
                OrbitSettingsValueRow(title: "Pinned") {
                    Text(ChromiumBuild.pinnedAt).foregroundStyle(.secondary)
                }
                OrbitSettingsValueRow(title: "Copyright") {
                    Text(copyrightDescription).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { isDefaultBrowser = DefaultBrowser.isDefault }
    }

    private var orbitVersionDescription: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private var copyrightDescription: String {
        "© \(Calendar.current.component(.year, from: Date())) Orbit"
    }

    #if ORBIT_SPARKLE
    @Bindable private var updater = UpdaterController.shared

    private var lastCheckedDescription: String {
        guard let lastCheckDate = updater.lastCheckDate else { return "Never" }
        return CommandBarRelativeTime.string(from: lastCheckDate)
    }

    private var updatesSection: some View {
        OrbitSettingsSection(title: "Updates") {
            OrbitSettingsRow(title: "Check for updates automatically") {
                OrbitToggle(accessibilityLabel: "Check for updates automatically", isOn: $updater.isAutomaticCheckEnabled, accentColor: SettingsPalette.accent)
            }
            OrbitSettingsRow(
                title: "Include pre-release versions",
                description: "Get beta builds before they're released to everyone. These are less tested and may be less stable."
            ) {
                OrbitToggle(accessibilityLabel: "Include pre-release versions", isOn: $updater.isPrereleaseChannelEnabled, accentColor: SettingsPalette.accent)
            }
            OrbitSettingsValueRow(title: "Last checked") {
                Text(lastCheckedDescription).foregroundStyle(.secondary)
            }
            UpdaterStatusView(
                status: updater.status,
                canCheckForUpdates: updater.canCheckForUpdates,
                onCheckForUpdates: { updater.checkForUpdates() },
                onInstallNow: { updater.installUpdateNow() },
                onRemindLater: { updater.remindMeLater() },
                onSkipVersion: { updater.skipThisVersion() },
                onCancelCheck: { updater.cancelCheck() },
                onCancelDownload: { updater.cancelDownload() }
            )
            .padding(.top, SettingsMetrics.rowVerticalPadding)
        }
    }
    #endif
}
