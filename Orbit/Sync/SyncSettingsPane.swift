import SwiftUI

struct SyncSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRefreshing = false

    private var engine: CloudSyncEngine? { env.syncEngine }
    private var status: SyncStatus { engine?.status ?? .disabled }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("iCloud").font(.system(size: 20, weight: .bold))

            OrbitSettingsSection(title: "Sync") {
                OrbitSettingsRow(
                    title: "Sync this Mac",
                    description: "Uses the iCloud account already signed in on this Mac. Orbit has no separate account to create or sign in to."
                ) {
                    OrbitToggle(
                        accessibilityLabel: "Sync this Mac",
                        isOn: Binding(
                            get: { engine?.isEnabled ?? false },
                            set: { engine?.setEnabled($0) }
                        ),
                        accentColor: SettingsPalette.accent
                    )
                    .disabled(engine == nil)
                }

                OrbitSettingsValueRow(title: "Status", description: status.userFacingMessage) {
                    statusIndicator
                }

                OrbitSettingsActionRow {
                    Text("Checks iCloud for changes from your other Macs and sends anything waiting here.")
                        .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                        .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    OrbitButton(title: "Sync Now", isCompact: true, accentColor: SettingsPalette.accent) {
                        Task {
                            isRefreshing = true
                            await engine?.refreshNow()
                            isRefreshing = false
                        }
                    }
                    .fixedSize()
                    .disabled(engine == nil || isRefreshing || !canSyncNow)
                }
            }

            OrbitSettingsSection(title: "What syncs") {
                Text(Self.whatSyncsCopy)
                    .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.whatDoesNotSyncCopy)
                    .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canSyncNow: Bool {
        switch status {
        case .idle, .syncing, .error: return true
        case .disabled, .off, .unavailable: return false
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .syncing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Syncing")
        case .idle(let lastSyncedAt):
            Image(systemName: lastSyncedAt == nil ? "clock" : "checkmark.circle.fill")
                .foregroundStyle(lastSyncedAt == nil ? Color.secondary : Color.green)
                .accessibilityLabel(lastSyncedAt == nil ? "Waiting" : "Synced")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Problem")
        case .unavailable:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Unavailable")
        case .off, .disabled:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Off")
        }
    }

    static let whatSyncsCopy = """
        Your Spaces, Folders, Pinned and Today tabs, Favorites, Boosts, Easels, Notes and link-routing rules.
        """

    static let whatDoesNotSyncCopy = """
        History, Downloads, archived tabs and anything you do in an Incognito window stay on this Mac only. Turning sync off here stops this Mac syncing; it does not remove anything already in iCloud.
        """
}

#if DEBUG
#Preview {
    SyncSettingsPane()
        .environment(AppEnvironment.demo)
        .padding(24)
        .frame(width: 560)
}
#endif
