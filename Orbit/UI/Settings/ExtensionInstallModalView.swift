import SwiftUI

struct ExtensionInstallModalView: View {
    var phase: ExtensionInstallModalPhase
    var subject: ExtensionInstallSubject?
    var onAnswerConsent: (Bool) -> Void
    var onCancel: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        switch phase {
        case .consent(let pending):
            ExtensionConsentSheetView(pending: pending, onAnswer: onAnswerConsent)
        case .progress(let stage):
            frame { progressBody(stage) } buttons: {
                OrbitButton(title: "Cancel", kind: .secondary, accentColor: SettingsPalette.accent, action: onCancel)
            }
        case .outcome(let outcome):
            frame { outcomeBody(outcome) } buttons: {
                OrbitButton(
                    title: "Done",
                    kind: .primary,
                    accentColor: SettingsPalette.accent,
                    keyboardShortcut: .defaultAction,
                    action: onDismiss
                )
            }
        }
    }

    // MARK: - Shared frame

    private func frame(
        @ViewBuilder content: () -> some View,
        @ViewBuilder buttons: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: OrbitMetrics.extensionInstallStackSpacing) {
            content()
                .frame(
                    maxWidth: .infinity,
                    minHeight: OrbitMetrics.extensionInstallProgressMinimumBodyHeight,
                    alignment: .topLeading
                )
            HStack {
                Spacer()
                buttons()
            }
        }
        .padding(OrbitMetrics.extensionInstallSheetPadding)
        .frame(width: OrbitMetrics.extensionInstallSheetWidth)
    }

    // MARK: - Progress

    private func progressBody(_ stage: ExtensionInstallStage) -> some View {
        ExtensionInstallStageRow(
            stage: stage,
            subject: subject,
            progressBarWidth: OrbitMetrics.extensionInstallProgressBarWidth
        )
    }

    // MARK: - Outcome

    @ViewBuilder
    private func outcomeBody(_ outcome: ExtensionInstallOutcome) -> some View {
        switch outcome {
        case .installed(let name, let version):
            header(title: name, detail: "Version \(version)") {
                OrbitInlineNotice(
                    systemImage: ExtensionInstallStatusKind.success.systemImage,
                    tint: ExtensionInstallStatusKind.success.tint,
                    text: "Installed and running. Manage it in Settings › Extensions."
                )
            }
        case .failed(let presentation):
            header(title: subject?.name ?? presentation.title, detail: subject.map { "Version \($0.version)" }) {
                ExtensionInstallFailureRow(presentation: presentation)
            }
        }
    }

    private func header(
        title: String,
        detail: String?,
        @ViewBuilder notice: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: OrbitMetrics.extensionInstallHeaderSpacing) {
            ExtensionIconBadge(iconData: subject?.iconPNGData)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: OrbitMetrics.extensionInstallTitleFontSize, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                        .foregroundStyle(.secondary)
                }
                notice()
            }
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 0) {
        ExtensionInstallModalView(
            phase: .progress(.extracting(completedEntries: 4_820, totalEntries: 13_244)),
            subject: ExtensionInstallSubject(name: "Fixture Extension", version: "1.3.0", iconPNGData: nil),
            onAnswerConsent: { _ in },
            onCancel: {},
            onDismiss: {}
        )
        ExtensionInstallModalView(
            phase: .outcome(.failed(.present(ExtensionInstallError.webStoreFailure(.network("The internet connection appears to be offline."))))),
            subject: nil,
            onAnswerConsent: { _ in },
            onCancel: {},
            onDismiss: {}
        )
    }
}
#endif
