import SwiftUI

struct LinkPreviewCardView: View {
    var phase: LinkPreviewController.Phase

    private let cornerRadius: CGFloat = OrbitMetrics.cardCornerRadius
    private let imageHeight: CGFloat = 140

    var body: some View {
        Group {
            switch phase {
            case .idle, .failed:
                EmptyView()
            case .loading:
                skeleton
            case .ready(let preview):
                ready(preview)
            case .recentPages(let data):
                recentPages(data)
            }
        }
    }

    // MARK: Loading — grey skeleton bars

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            skeletonBlock.frame(height: imageHeight)
            VStack(alignment: .leading, spacing: 8) {
                skeletonLine(height: 12)
                skeletonLine(width: 220, height: 12)
                skeletonLine(width: 160, height: 12)
                Spacer().frame(height: 6)
                HStack(alignment: .top, spacing: 8) {
                    skeletonBlock.frame(width: 14, height: 14).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        skeletonLine(height: 10)
                        skeletonLine(width: 180, height: 10)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    skeletonBlock.frame(width: 14, height: 14).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        skeletonLine(height: 10)
                        skeletonLine(width: 140, height: 10)
                    }
                }
            }
            .padding(14)
        }
        .cardChrome(cornerRadius: cornerRadius)
    }

    private var skeletonBlock: some View {
        Rectangle().fill(Color.gray.opacity(0.18))
    }

    private func skeletonLine(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color.gray.opacity(0.18))
            .frame(maxWidth: width ?? .infinity)
            .frame(width: width, height: height)
    }

    // MARK: Ready — the real card

    private func ready(_ preview: AssistRuntime.LinkPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let imageURL = preview.imageURL {
                AsyncImage(url: imageURL) { asyncPhase in
                    switch asyncPhase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.gray.opacity(0.10)
                    }
                }
                .frame(height: imageHeight)
                .clipped()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(preview.summary)
                    .font(.system(size: 13, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                if !preview.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(preview.items.enumerated()), id: \.offset) { _, item in
                            itemRow(item)
                        }
                    }
                }
            }
            .padding(14)
        }
        .cardChrome(cornerRadius: cornerRadius)
    }

    // MARK: Recent pages — the per-service card

    /// Built from local browsing history, not a service API — see `RecentPagesModels.swift`.
    private func recentPages(_ data: RecentPagesData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                FaviconView(url: nil, host: data.iconHost)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(data.service.cardHeading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(data.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(CommandBarRelativeTime.string(from: item.lastVisitDate))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .cardChrome(cornerRadius: cornerRadius)
    }

    private func itemRow(_ item: AssistRuntime.LinkPreview.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            (Text(item.lead).fontWeight(.semibold) + Text(" " + item.detail))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    func cardChrome(cornerRadius: CGFloat) -> some View {
        self
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(OrbitMetrics.cardBorderOpacity))
            )
            .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 8)
    }
}
