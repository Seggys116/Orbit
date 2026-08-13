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
                OrbitSettingsValueRow(title: "Engine") {
                    Text(ChromiumBuild.engineDescription).foregroundStyle(.secondary)
                }
                OrbitSettingsActionRow {
                    Text(orbitVersionDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } trailing: {
                    OrbitButton(title: "About Orbit…", kind: .secondary, accentColor: SettingsPalette.accent) { AboutWindowController.show() }
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

    #if ORBIT_SPARKLE
    @Bindable private var updater = UpdaterController.shared

    private var updaterStatusSummary: String? {
        switch updater.status {
        case .idle:
            return nil
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Orbit is up to date."
        case .updateAvailable(let version, _, let isInformationOnly):
            return isInformationOnly ? "Orbit \(version) is available (see About Orbit…)." : "Orbit \(version) is available."
        case .downloading(let fractionCompleted):
            return fractionCompleted.map { "Downloading… \(Int(($0 * 100).rounded()))%" } ?? "Downloading…"
        case .extracting(let fractionCompleted):
            return "Extracting… \(Int((fractionCompleted * 100).rounded()))%"
        case .readyToRelaunch(let version):
            return "Orbit \(version) is ready to install (see About Orbit…)."
        case .error:
            return "Update check failed."
        }
    }

    private var updaterErrorDescription: String? {
        guard case .error(let message) = updater.status else { return nil }
        return message
    }

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
            OrbitSettingsActionRow {
                VStack(alignment: .leading, spacing: 2) {
                    if let updaterStatusSummary {
                        Text(updaterStatusSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if updaterErrorDescription == nil {
                        Text("Checks for a newer version of Orbit.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let updaterErrorDescription {
                        Text(updaterErrorDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                OrbitButton(title: "Check Now", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
    }
    #endif
}
