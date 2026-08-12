import SwiftUI

struct ExtensionConsentSheetView: View {
    let pending: ExtensionInstaller.PendingInstall
    var onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitMetrics.extensionInstallStackSpacing) {
            header
            if let chromiumVersionWarning = pending.chromiumVersionWarning {
                OrbitInlineNotice(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: chromiumVersionWarning)
            }
            warningsList
            buttons
        }
        .padding(OrbitMetrics.extensionInstallSheetPadding)
        .frame(width: OrbitMetrics.extensionInstallSheetWidth)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: OrbitMetrics.extensionInstallHeaderSpacing) {
            ExtensionIconBadge(iconURL: pending.iconURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(pending.name)
                    .font(.system(size: OrbitMetrics.extensionInstallTitleFontSize, weight: .semibold))
                Text(versionLine)
                    .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                    .foregroundStyle(.secondary)
                if let description = pending.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var versionLine: String {
        guard pending.isUpdate else { return "Version \(pending.version)" }
        guard let previousVersion = pending.previousVersion else { return "Update to version \(pending.version)" }
        return "Updating from version \(previousVersion) to \(pending.version)"
    }

    // MARK: - Warnings

    private var grouped: (granted: [ExtensionPermissionWarning], optional: [ExtensionPermissionWarning]) {
        ExtensionInstallLogic.groupedWarnings(pending.warnings)
    }

    @ViewBuilder
    private var warningsList: some View {
        if pending.warnings.isEmpty {
            Text("This extension does not request any special permissions.")
                .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !grouped.granted.isEmpty {
                        warningSection(
                            title: pending.isUpdate ? "This update will be able to:" : "This extension will be able to:",
                            warnings: grouped.granted
                        )
                    }
                    if !grouped.optional.isEmpty {
                        warningSection(title: "May ask permission for, later:", warnings: grouped.optional)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }

    private func warningSection(title: String, warnings: [ExtensionPermissionWarning]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: OrbitMetrics.extensionInstallCaptionFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(severityColor(warning.severity))
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    Text(warning.text)
                        .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func severityColor(_ severity: ExtensionPermissionWarningSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .moderate: return .yellow
        case .low: return .secondary
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            Spacer()
            OrbitButton(title: "Cancel", kind: .secondary, accentColor: SettingsPalette.accent) {
                onAnswer(false)
            }
            OrbitButton(
                title: pending.isUpdate ? "Update" : "Install",
                kind: .primary,
                accentColor: SettingsPalette.accent,
                keyboardShortcut: .defaultAction
            ) {
                onAnswer(true)
            }
        }
    }
}

#if DEBUG
#Preview {
    ExtensionConsentSheetView(
        pending: .init(
            id: "abcdefghijklmnopabcdefghijklmnop",
            name: "Example Extension",
            version: "1.3.0",
            description: "A short description of what this extension does, long enough to wrap onto a second line in the preview.",
            iconURL: nil,
            warnings: [
                ExtensionPermissionWarning(id: "host.all", text: "Read and change all your data on all websites", severity: .critical, isGrantedAtInstall: true),
                ExtensionPermissionWarning(id: "perm:storage", text: "Store data on your Mac", severity: .low, isGrantedAtInstall: true),
                ExtensionPermissionWarning(id: "perm:geolocation.optional", text: "Detect your physical location", severity: .high, isGrantedAtInstall: false),
            ],
            isUpdate: false,
            previousVersion: nil,
            chromiumVersionWarning: "This extension declares that it requires Chrome 200.0 or later. Orbit currently embeds an older Chromium, so some of its features may not work correctly."
        ),
        onAnswer: { _ in }
    )
}
#endif
