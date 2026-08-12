import AppKit
import SwiftUI

// MARK: - Icon badge

// Shared with ExtensionConsentSheetView's header so every install-flow state renders the same icon treatment.

struct ExtensionIconBadge: View {
    var iconURL: URL?
    /// Already-loaded icon bytes for states whose source file is gone (`.installing` runs
    /// after the staging directory `iconURL` pointed into moved into the extension store).
    var iconData: Data?
    var size: CGFloat = OrbitMetrics.extensionInstallIconSize

    private var image: NSImage? {
        if let iconData, let loaded = NSImage(data: iconData) { return loaded }
        if let iconURL, let loaded = NSImage(contentsOf: iconURL) { return loaded }
        return nil
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: OrbitMetrics.extensionInstallIconGlyphSize))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Progress bar

// Not LibraryProgressBar: its track is a fixed white tint, invisible on a light sheet. Resolves track and fill from tokens per colour scheme instead.

struct OrbitInstallProgressBar: View {
    var fraction: Double?

    @Environment(\.colorScheme) private var colorScheme

    private var track: Color {
        colorScheme == .dark
            ? Color.white.opacity(OrbitMetrics.extensionInstallProgressTrackOpacityDark)
            : Color.black.opacity(OrbitMetrics.extensionInstallProgressTrackOpacityLight)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(SettingsPalette.accent)
                    .frame(width: filledWidth(in: proxy.size.width))
                    .opacity(fraction == nil ? OrbitMetrics.extensionInstallProgressIndeterminateOpacity : 1)
            }
        }
        .frame(height: OrbitMetrics.extensionInstallProgressBarHeight)
    }

    private func filledWidth(in available: CGFloat) -> CGFloat {
        guard let fraction else { return available }
        return max(OrbitMetrics.extensionInstallProgressBarHeight, available * CGFloat(min(1, max(0, fraction))))
    }
}

// MARK: - Inline notice

// Shared icon+caption row; ExtensionConsentSheetView's own notices route through this too, rather than a private duplicate.

struct OrbitInlineNotice: View {
    var systemImage: String
    var tint: Color
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: OrbitMetrics.extensionInstallCaptionFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Stage row

// Shared by the tab-overlay banner (ContentCardView.swift) and the Settings pane's inline installer.

struct ExtensionInstallStageRow: View {
    var stage: ExtensionInstallStage
    var iconURL: URL? = nil
    var subject: ExtensionInstallSubject? = nil
    var progressBarWidth: CGFloat = 220

    private var presentation: ExtensionInstallStagePresentation {
        ExtensionInstallStagePresenter.present(stage)
    }

    var body: some View {
        HStack(alignment: .top, spacing: OrbitMetrics.extensionInstallHeaderSpacing) {
            ExtensionIconBadge(iconURL: iconURL, iconData: subject?.iconPNGData)
            VStack(alignment: .leading, spacing: 4) {
                // Before consent the stage is the headline; from consent onward the name
                // (as the consent dialog had it) takes that spot and the stage drops below.
                Text(subject?.name ?? presentation.title)
                    .font(.system(size: OrbitMetrics.extensionInstallTitleFontSize, weight: .semibold))
                if subject != nil {
                    Text(presentation.title)
                        .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                        .foregroundStyle(.secondary)
                }
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize))
                        .foregroundStyle(.secondary)
                }
                OrbitInstallProgressBar(fraction: presentation.fraction)
                    .frame(width: progressBarWidth)
            }
        }
    }
}

// MARK: - Terminal status kind

// Distinguishes a genuine success from a neutral decline, so installStatusMessage never paints a decline as a win.

enum ExtensionInstallStatusKind {
    case success
    case declined

    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .declined: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .declined: return .secondary
        }
    }
}

// MARK: - Failure row

struct ExtensionInstallFailureRow: View {
    var presentation: ExtensionInstallFailurePresentation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: OrbitMetrics.extensionInstallFailureGlyphSize))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: OrbitMetrics.extensionInstallDetailFontSize, weight: .semibold))
                Text(presentation.message)
                    .font(.system(size: OrbitMetrics.extensionInstallCaptionFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tint: Color {
        switch presentation.category {
        case .cancelled: return .secondary
        case .network: return .orange
        case .verification: return .red
        case .alreadyInstalled: return .blue
        case .unsupportedManifest: return .orange
        case .other: return .red
        }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ExtensionInstallStageRow(stage: .downloading(receivedBytes: 2_400_000, totalBytes: 6_100_000))
        ExtensionInstallStageRow(stage: .verifying)
        ExtensionInstallStageRow(stage: .extracting(completedEntries: 340, totalEntries: 812))
        ExtensionInstallStageRow(stage: .installing)
        ExtensionInstallFailureRow(presentation: .present(ExtensionInstallError.alreadyInstalled(id: "abcdefghijklmnopabcdefghijklmnop", installedVersion: "2.1.0")))
        ExtensionInstallFailureRow(presentation: .present(ExtensionInstallError.webStoreFailure(.network("The internet connection appears to be offline."))))
    }
    .padding(20)
    .frame(width: 420)
}
#endif
