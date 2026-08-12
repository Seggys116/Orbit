import SwiftUI

/// `chrome.permissions.request` put to the user, at
/// `ExtensionConsentSheetView`'s width, padding and typographic scale — this
/// is the same decision at a different moment, so it reads as the same dialog.
struct ExtensionPermissionsConsentSheetView: View {
    let request: ExtensionPermissionsConsentRequest
    var iconURL: URL?
    var onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitMetrics.extensionInstallStackSpacing) {
            header
            warningsList
            buttons
        }
        .padding(OrbitMetrics.extensionInstallSheetPadding)
        .frame(width: OrbitMetrics.extensionInstallSheetWidth)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: OrbitMetrics.extensionInstallHeaderSpacing) {
            ExtensionIconBadge(iconURL: iconURL)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(request.extensionName) is requesting additional permissions")
                    .font(.system(size: OrbitMetrics.extensionInstallTitleFontSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("It already runs in Orbit. Granting these gives it access it does not have today.")
                    .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Warnings

    private var warningsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("This would let it:")
                    .font(.system(size: OrbitMetrics.extensionInstallCaptionFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(request.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        Text(warning)
                            .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            Spacer()
            OrbitButton(
                title: "Deny",
                kind: .secondary,
                accentColor: SettingsPalette.accent,
                keyboardShortcut: .cancelAction
            ) {
                onAnswer(false)
            }
            OrbitButton(title: "Allow", kind: .primary, accentColor: SettingsPalette.accent) {
                onAnswer(true)
            }
        }
    }
}

#if DEBUG
#Preview {
    ExtensionPermissionsConsentSheetView(
        request: ExtensionPermissionsConsentRequest(
            requestID: 1,
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            extensionName: "Example Extension",
            permissions: ["downloads"],
            origins: ["https://example.com/*"],
            warnings: [
                "Manage your downloads",
                "Read and change your data on example.com",
            ]
        ),
        iconURL: nil,
        onAnswer: { _ in }
    )
}
#endif
