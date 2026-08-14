import SwiftUI

struct UpdaterStatusView: View {
    var status: UpdaterStatus
    var canCheckForUpdates: Bool
    var onCheckForUpdates: () -> Void
    var onInstallNow: () -> Void
    var onRemindLater: () -> Void
    var onSkipVersion: () -> Void
    var onCancelCheck: () -> Void
    var onCancelDownload: () -> Void

    @State private var isDismissed = false

    @State private var isReleaseNotesExpanded = false
    @State private var decodedReleaseNotes: AttributedString?
    @State private var decodedReleaseNotesSourceHTML: String?

    var body: some View {
        Group {
            if isDismissed, isDismissibleStatus {
                idleRow
            } else {
                switch status {
                case .idle:
                    idleRow
                case .checking:
                    checkingRow
                case .upToDate:
                    upToDateRow
                case .updateAvailable(let version, let releaseNotesHTML, let isInformationOnly):
                    updateAvailableContent(version: version, releaseNotesHTML: releaseNotesHTML, isInformationOnly: isInformationOnly)
                case .downloading(let fractionCompleted):
                    downloadingContent(fractionCompleted: fractionCompleted)
                case .extracting(let fractionCompleted):
                    extractingContent(fractionCompleted: fractionCompleted)
                case .readyToRelaunch(let version):
                    readyToRelaunchContent(version: version)
                case .error(let message):
                    errorContent(message: message)
                }
            }
        }
        .onChange(of: status) { _, _ in isDismissed = false }
    }

    private var isDismissibleStatus: Bool {
        switch status {
        case .error, .upToDate: return true
        default: return false
        }
    }

    // MARK: - Idle / checking / up to date

    private var idleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Orbit checks for updates automatically.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            OrbitButton(title: "Check for Updates", kind: .secondary, isCompact: true) {
                onCheckForUpdates()
            }
            .disabled(!canCheckForUpdates)
        }
    }

    private var checkingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Checking for updates…")
                .font(.system(size: 11.5))
            Spacer(minLength: 8)
            OrbitButton(title: "Cancel", kind: .ghost, isCompact: true) {
                onCancelCheck()
            }
        }
    }

    private var upToDateRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
            Text("Orbit is up to date.")
                .font(.system(size: 11.5))
            Spacer(minLength: 8)
            OrbitButton(title: "Check Again", kind: .secondary, isCompact: true) {
                onCheckForUpdates()
            }
            .disabled(!canCheckForUpdates)
            OrbitButton(title: "Dismiss", systemImage: "xmark", kind: .ghost, isIconOnly: true, isCompact: true) {
                isDismissed = true
            }
        }
    }

    // MARK: - Update available

    private func updateAvailableContent(version: String, releaseNotesHTML: String?, isInformationOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orbit \(version) is available.")
                        .font(.system(size: 12, weight: .semibold))
                    if isInformationOnly {
                        Text("This update can't be installed automatically. Visit the release page to update Orbit by hand.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            releaseNotesDisclosure(html: releaseNotesHTML)
            if isInformationOnly {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    OrbitButton(title: "OK", kind: .secondary, isCompact: true) {
                        onRemindLater()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    OrbitButton(title: "Remind Me Later", kind: .secondary, isCompact: true) {
                        onRemindLater()
                    }
                    OrbitButton(title: "Install and Relaunch", kind: .primary, isCompact: true) {
                        onInstallNow()
                    }
                }
                HStack(spacing: 8) {
                    OrbitButton(title: "Skip This Version", kind: .ghost, isCompact: true) {
                        onSkipVersion()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func releaseNotesDisclosure(html: String?) -> some View {
        DisclosureGroup(isExpanded: $isReleaseNotesExpanded) {
            releaseNotesBody(html: html)
                .padding(.top, 4)
        } label: {
            Text("Release Notes")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }

    @ViewBuilder
    private func releaseNotesBody(html: String?) -> some View {
        if let html {
            if decodedReleaseNotesSourceHTML == html, let decodedReleaseNotes {
                ScrollView {
                    Text(decodedReleaseNotes)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading release notes…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .task(id: html) {
                    await decodeReleaseNotes(html)
                }
            }
        } else {
            Text("No release notes were provided for this update.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func decodeReleaseNotes(_ html: String) async {
        guard let data = html.data(using: .utf8) else {
            decodedReleaseNotesSourceHTML = html
            decodedReleaseNotes = AttributedString("Release notes could not be displayed.")
            return
        }
        let imported = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
        decodedReleaseNotesSourceHTML = html
        if let imported {
            decodedReleaseNotes = AttributedString(imported)
        } else {
            decodedReleaseNotes = AttributedString("Release notes could not be displayed.")
        }
    }

    // MARK: - Downloading / extracting

    private func downloadingContent(fractionCompleted: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(fractionCompleted.map { "Downloading update… \(Int(($0 * 100).rounded()))%" } ?? "Downloading update…")
                    .font(.system(size: 11.5))
                Spacer(minLength: 8)
                OrbitButton(title: "Cancel", kind: .ghost, isCompact: true) {
                    onCancelDownload()
                }
            }
            if let fractionCompleted {
                ProgressView(value: fractionCompleted)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }

    private func extractingContent(fractionCompleted: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extracting update… \(Int((fractionCompleted * 100).rounded()))%")
                .font(.system(size: 11.5))
            ProgressView(value: fractionCompleted)
                .progressViewStyle(.linear)
        }
    }

    // MARK: - Ready to relaunch

    private func readyToRelaunchContent(version: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
            Text("Orbit \(version) is ready to install.")
                .font(.system(size: 11.5))
            Spacer(minLength: 8)
            OrbitButton(title: "Relaunch & Install", kind: .primary, isCompact: true) {
                onInstallNow()
            }
        }
    }

    // MARK: - Error

    private func errorContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                Text("Update Check Failed")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                OrbitButton(title: "Dismiss", systemImage: "xmark", kind: .ghost, isIconOnly: true, isCompact: true) {
                    isDismissed = true
                }
            }
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                OrbitButton(title: "Try Again", kind: .secondary, isCompact: true) {
                    onCheckForUpdates()
                }
                .disabled(!canCheckForUpdates)
            }
        }
    }
}

#if DEBUG
#Preview("Idle") {
    UpdaterStatusView(status: .idle, canCheckForUpdates: true, onCheckForUpdates: {}, onInstallNow: {}, onRemindLater: {}, onSkipVersion: {}, onCancelCheck: {}, onCancelDownload: {})
        .padding()
        .frame(width: 340)
}

#Preview("Update available") {
    UpdaterStatusView(
        status: .updateAvailable(version: "2.4.0", releaseNotesHTML: "<h3>What's new</h3><ul><li>Faster tab switching</li><li>Fixed a crash on quit</li></ul>", isInformationOnly: false),
        canCheckForUpdates: true,
        onCheckForUpdates: {}, onInstallNow: {}, onRemindLater: {}, onSkipVersion: {}, onCancelCheck: {}, onCancelDownload: {}
    )
    .padding()
    .frame(width: 340)
}

#Preview("Error") {
    UpdaterStatusView(
        status: .error(message: "The update is improperly signed and could not be validated.\n\nThe host application's EdDSA public key could not be decoded. Please make sure to use a valid EdDSA public key with the app."),
        canCheckForUpdates: true,
        onCheckForUpdates: {}, onInstallNow: {}, onRemindLater: {}, onSkipVersion: {}, onCancelCheck: {}, onCancelDownload: {}
    )
    .padding()
    .frame(width: 340)
}
#endif
