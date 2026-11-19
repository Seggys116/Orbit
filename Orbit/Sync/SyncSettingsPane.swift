import SwiftUI

enum SyncRecoveryAction: Identifiable {
    case replaceICloudWithThisMac
    case replaceThisMacWithICloud

    var id: Self { self }

    var buttonTitle: String {
        switch self {
        case .replaceICloudWithThisMac: return "Replace iCloud with This Mac…"
        case .replaceThisMacWithICloud: return "Replace This Mac with iCloud…"
        }
    }

    var summary: String {
        switch self {
        case .replaceICloudWithThisMac:
            return "Deletes everything Orbit has stored in iCloud and uploads what is on this Mac in its place."
        case .replaceThisMacWithICloud:
            return "Forgets what this Mac had already synced and downloads everything from iCloud again."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .replaceICloudWithThisMac: return "Replace everything in iCloud with this Mac?"
        case .replaceThisMacWithICloud: return "Replace this Mac's synced data with iCloud?"
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .replaceICloudWithThisMac: return "Replace iCloud"
        case .replaceThisMacWithICloud: return "Replace This Mac"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .replaceICloudWithThisMac:
            return "This deletes only the data Orbit itself keeps in your iCloud account: nothing else in iCloud is touched, and nothing on this Mac is deleted. Spaces, Folders, Pinned and Today tabs, Favorites, Boosts, Easels, Notes and link-routing rules that exist only on your other Macs are lost. Orbit then uploads what is on this Mac as the only copy, and your other Macs will receive it. This cannot be undone."
        case .replaceThisMacWithICloud:
            return "Orbit discards its record of what this Mac has synced and downloads everything in iCloud again. Where iCloud and this Mac both have an item, iCloud's version replaces this Mac's, so edits made here that never reached iCloud are lost for those items. Items that exist only on this Mac are kept and uploaded, and items you deleted here that are still in iCloud come back. This cannot be undone."
        }
    }
}

struct SyncSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRefreshing = false
    @State private var pendingRecovery: SyncRecoveryAction?

    private var engine: CloudSyncEngine? { env.syncEngine }
    private var status: SyncStatus { engine?.status ?? .disabled }
    private var problem: SyncProblem? { engine?.lastProblem }
    private var isRecovering: Bool { engine?.isRecovering ?? false }
    private var isBusy: Bool { isRefreshing || isRecovering || status.isActivelyWorking }
    private var isInError: Bool {
        if case .error = status { return true }
        return false
    }

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
                    OrbitButton(title: isInError ? "Try Again" : "Sync Now", isCompact: true, accentColor: SettingsPalette.accent) {
                        Task {
                            isRefreshing = true
                            await engine?.refreshNow()
                            isRefreshing = false
                        }
                    }
                    .fixedSize()
                    .disabled(engine == nil || isRefreshing || isRecovering || !canSyncNow)
                }
            }

            if problem != nil || isRecovering {
                troubleshootingSection(for: problem)
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
        .confirmationDialog(
            pendingRecovery?.confirmationTitle ?? "",
            isPresented: Binding(get: { pendingRecovery != nil }, set: { if !$0 { pendingRecovery = nil } }),
            titleVisibility: .visible,
            presenting: pendingRecovery
        ) { action in
            Button(action.confirmButtonTitle, role: .destructive) { run(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.confirmationMessage)
        }
    }

    private func run(_ action: SyncRecoveryAction) {
        Task {
            switch action {
            case .replaceICloudWithThisMac: await engine?.replaceICloudWithThisMac()
            case .replaceThisMacWithICloud: await engine?.replaceThisMacWithICloud()
            }
        }
    }

    private func troubleshootingSection(for problem: SyncProblem?) -> some View {
        OrbitSettingsSection(title: "Troubleshooting") {
            if let problem {
                Text(problem.recoveryHint)
                    .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                    .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isRecovering {
                HStack(spacing: OrbitControlMetrics.settingsRowContentSpacing) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working with iCloud")
                    Text("Working with iCloud…")
                        .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                        .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                }
            }

            if let problem, problem.requiresICloudReset {
                OrbitSettingsActionRow {
                    Text("iCloud's copy needs to be reset. Wipe what's there and upload this Mac's Spaces, tabs and Favorites in its place?")
                        .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    OrbitButton(title: "Yes, Wipe iCloud and Re-sync…", kind: .destructive, isCompact: true) {
                        pendingRecovery = .replaceICloudWithThisMac
                    }
                    .fixedSize()
                    .disabled(engine == nil || isBusy)
                }
                recoveryRow(.replaceThisMacWithICloud)
            } else if let problem, !problem.isSchemaProblem {
                recoveryRow(.replaceICloudWithThisMac)
                recoveryRow(.replaceThisMacWithICloud)
            }
        }
    }

    private func recoveryRow(_ action: SyncRecoveryAction) -> some View {
        OrbitSettingsActionRow {
            Text(action.summary)
                .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize))
                .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            OrbitButton(title: action.buttonTitle, kind: .destructive, isCompact: true) {
                pendingRecovery = action
            }
            .fixedSize()
            .disabled(engine == nil || isBusy)
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
