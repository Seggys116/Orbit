import SwiftUI

struct TidyDownloadCardView: View {
    @Environment(AppEnvironment.self) private var env
    var theme: SpaceTheme

    @State private var coordinator = TidyDownloadsCoordinator.shared

    var body: some View {
        if let announcement = coordinator.announcement {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Download renamed to:")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.readableSecondaryForeground)
                    Spacer(minLength: 4)
                    Button { coordinator.undoAnnouncedRename(env: env) } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.readableSecondaryForeground)
                    .accessibilityLabel("Undo download rename")

                    Button { coordinator.dismissAnnouncement() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.readableSecondaryForeground)
                    .accessibilityLabel("Dismiss download rename notice")
                }

                Text(announcement.newFileName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.readableForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Text(announcement.originalFileName)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.readableSecondaryForeground.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OrbitMetrics.favoriteTileCornerRadius, style: .continuous)
                    .fill(theme.readableForeground.opacity(0.10))
            )
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        }
    }
}
