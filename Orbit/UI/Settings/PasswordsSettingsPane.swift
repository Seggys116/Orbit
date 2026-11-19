import AppKit
import SwiftUI

/// Passwords and passkeys live in Apple's Passwords app, in iCloud Keychain. This pane shows whether Orbit can reach them and pairs it.
struct PasswordsSettingsPane: View {
    @State private var passwords = SystemPasswords.shared
    @State private var isPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("Passwords").font(.system(size: 20, weight: .bold))

            paragraph("Orbit fills and saves passwords with the Passwords app, so they stay in iCloud Keychain and sync to your other devices. Orbit keeps no passwords of its own.")

            passwordsSection
            passkeysSection
        }
        .onAppear { passwords.refreshPasskeyState() }
        .onReceive(NotificationCenter.default.publisher(for: .orbitPasskeyAuthorizationDidChange)) { _ in
            passwords.refreshPasskeyState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            passwords.refreshPasskeyState()
        }
        .sheet(isPresented: $isPairing, onDismiss: {
            if [SystemPasswordsState.pairing, .awaitingPIN, .verifyingPIN].contains(passwords.state) { passwords.cancelPairing() }
        }) {
            SystemPasswordsPairingView(passwords: passwords) { isPairing = false }
        }
    }

    private var passwordsSection: some View {
        let summary = SystemPasswords.summary(of: passwords.state)
        return OrbitSettingsSection(title: "Passwords app") {
            OrbitSettingsRow(title: summary.title, description: summary.detail) {
                Image(systemName: Self.symbol(for: passwords.state))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Self.isHealthy(passwords.state) ? SettingsPalette.accent : SettingsPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            if let error = passwords.lastError, !isPairing {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OrbitSettingsActionRow {
                Text("Pairing lasts until Orbit quits; macOS shows a new code each time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                HStack(spacing: 6) {
                    if passwords.state != .paired {
                        OrbitButton(title: "Pair…", kind: .primary, isCompact: true, accentColor: SettingsPalette.accent) {
                            isPairing = true
                        }
                        .disabled(!passwords.canPair)
                    }
                    OrbitButton(title: "Open Passwords", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                        passwords.openPasswordsApp()
                    }
                }
            }
        }
    }

    private var passkeysSection: some View {
        OrbitSettingsSection(title: "Passkeys") {
            OrbitSettingsRow(title: Self.passkeyTitle(passwords.passkeyState), description: Self.passkeyDetail(passwords.passkeyState)) {
                if passwords.passkeyState == .notDetermined {
                    OrbitButton(title: "Allow Passkeys…", kind: .primary, isCompact: true, accentColor: SettingsPalette.accent) {
                        Task { await passwords.enablePasskeys() }
                    }
                } else if passwords.passkeyState == .denied {
                    OrbitButton(title: "Open Privacy Settings", kind: .secondary, isCompact: true, accentColor: SettingsPalette.accent) {
                        Self.openPasskeyPrivacySettings()
                    }
                }
            }
        }
    }

    static func isHealthy(_ state: SystemPasswordsState) -> Bool { state == .paired }

    static func symbol(for state: SystemPasswordsState) -> String {
        switch state {
        case .paired: return "checkmark.circle.fill"
        case .notPaired, .pairing, .awaitingPIN, .verifyingPIN: return "link.circle"
        case .waitingForMacOS: return "clock"
        case .notStarted, .starting: return "ellipsis.circle"
        case .helperMissing, .unentitledBuild, .unavailable: return "exclamationmark.circle"
        }
    }

    static func passkeyTitle(_ state: PasskeyAuthorizationState) -> String {
        switch state {
        case .authorized: return "Passkeys allowed"
        case .notDetermined: return "Passkeys not set up"
        case .denied: return "Passkeys turned off"
        case .unavailable: return "Passkeys not available in this build"
        }
    }

    static func passkeyDetail(_ state: PasskeyAuthorizationState) -> String {
        switch state {
        case .authorized:
            return "Sites that sign in with a passkey use the passkeys in iCloud Keychain."
        case .notDetermined:
            return "Let sites use the passkeys in iCloud Keychain. macOS also asks the first time a site wants one."
        case .denied:
            return "macOS does not let Orbit use your passkeys. Turn Orbit on under Privacy & Security to allow it."
        case .unavailable:
            return "Only signed release builds of Orbit can use the passkeys in iCloud Keychain."
        }
    }

    private static func openPasskeyPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_PasskeyAccess") {
            NSWorkspace.shared.open(url)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: OrbitControlMetrics.settingsRowDescriptionFontSize + 1))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
