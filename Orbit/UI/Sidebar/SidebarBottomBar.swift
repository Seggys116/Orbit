import AppKit
import SwiftUI

struct SidebarBottomBar: View {
    @Environment(AppEnvironment.self) private var env
    var theme: SpaceTheme

    @State private var showLibraryFlyout = false
    @State private var isHoveringLibraryButton = false
    @State private var isHoveringFlyout = false
    @State private var libraryHoverTask: Task<Void, Never>?
    @State private var isNewItemMenuPresented = false

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarBottomBarSpacing) {
            libraryButton

            if env.isTornOffWindow {
                Spacer(minLength: OrbitMetrics.sidebarBottomBarSpacing)
            } else {
                pagerRegion
            }

            newItemMenu
        }
        .padding(.horizontal, OrbitMetrics.sidebarBottomBarHorizontalPadding)
        .frame(height: OrbitMetrics.sidebarBottomBarHeight)
        .overlay(alignment: .bottom) { libraryFlyout }
    }

    // MARK: Space pager region (always present, centred, overflow-safe)

    private var pagerRegion: some View {
        GeometryReader { proxy in
            SpaceSwitcherPagerView(
                theme: theme,
                sizeScale: SpaceSwitcherPagerView.sizeScale(forSpaceCount: env.pagerSpaces.count, availableWidth: proxy.size.width)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .clipped()
        }
    }

    // MARK: `+` menu

    // A plain SwiftUI Button's click is unreliable in this bar's hosting
    // configuration, so this uses OrbitNSActionButton instead.

    private var newItemMenu: some View {
        OrbitNSActionButton {
            isNewItemMenuPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                .foregroundStyle(theme.readableForeground)
                .frame(width: OrbitMetrics.sidebarBottomBarIconSize, height: OrbitMetrics.sidebarBottomBarIconSize)
                .background {
                    if isNewItemMenuPresented {
                        RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius, style: .continuous)
                            .fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity))
                    }
                }
        }
        .orbitTooltip("New…")
        .orbitMenuPanel(
            isPresented: $isNewItemMenuPresented,
            entries: SidebarNewItemOption.contextMenuEntries(in: env),
            preferredDirection: .up,
            showsArrow: true
        )
    }

    // MARK: Library

    private var libraryButton: some View {
        OrbitNSActionButton {
            LibraryWindowController.show(section: .downloads)
        } label: {
            Image(systemName: "archivebox")
                .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                .foregroundStyle(theme.readableForeground)
                .frame(width: OrbitMetrics.sidebarBottomBarIconSize, height: OrbitMetrics.sidebarBottomBarIconSize)
                .background {
                    if showLibraryFlyout || isHoveringLibraryButton {
                        RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius, style: .continuous)
                            .fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity))
                    }
                }
        }
        .onHover { hovering in
            isHoveringLibraryButton = hovering
            rescheduleFlyout()
        }
    }

    static func shouldOpenFlyout(isHoveringButton: Bool, isHoveringFlyout: Bool, downloadCount: Int) -> Bool {
        (isHoveringButton || isHoveringFlyout) && downloadCount > 0
    }

    private func rescheduleFlyout() {
        libraryHoverTask?.cancel()
        let wantsOpen = Self.shouldOpenFlyout(
            isHoveringButton: isHoveringLibraryButton,
            isHoveringFlyout: isHoveringFlyout,
            downloadCount: env.recentDownloads.count
        )
        guard wantsOpen != showLibraryFlyout else { return }
        libraryHoverTask = Task {
            try? await Task.sleep(nanoseconds: wantsOpen ? 350_000_000 : 120_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(OrbitMotion.quick) { showLibraryFlyout = wantsOpen }
        }
    }

    // env.recentDownloads.isEmpty covers the list emptying while the flyout is already open with no hover event to re-evaluate it.
    @ViewBuilder
    private var libraryFlyout: some View {
        if showLibraryFlyout, !env.recentDownloads.isEmpty {
            GeometryReader { proxy in
                let bar = proxy.frame(in: .global)
                let sidebarHeight = bar.maxY + OrbitMetrics.sidebarInterSectionGap
                let panelHeight = max(0, bar.minY - OrbitMetrics.sidebarTopRowHeight)
                DownloadsFlyoutView(theme: theme, downloads: env.recentDownloads)
                    .frame(width: proxy.size.width, height: panelHeight, alignment: .bottom)
                    .background(alignment: .bottom) {
                        // ThemeBackgroundView's gradients are unit-point based: painted at the panel's own size instead of the sidebar's, the stops land at the wrong height and leave a visible seam.
                        ThemeBackgroundView(theme: theme)
                            .frame(height: sidebarHeight)
                            .offset(y: bar.height + OrbitMetrics.sidebarInterSectionGap)
                    }
                    .clipped()
                    .offset(y: -panelHeight)
                    .onHover { hovering in
                        isHoveringFlyout = hovering
                        rescheduleFlyout()
                    }
            }
            .transition(.opacity)
        }
    }
}

struct DownloadsFlyoutView: View {
    var theme: SpaceTheme
    var downloads: [DownloadItem]

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitMetrics.sidebarBottomBarSpacing) {
            ForEach(downloads) { item in
                DownloadsFlyoutRow(theme: theme, item: item)
            }
        }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        .padding(.bottom, OrbitMetrics.sidebarSectionSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

@MainActor
enum DownloadsFlyoutTime {
    private static let formatter = RelativeDateTimeFormatter()

    static func string(for date: Date, relativeTo reference: Date, locale: Locale = .current) -> String {
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

struct DownloadsFlyoutRow: View {
    var theme: SpaceTheme
    var item: DownloadItem

    @Environment(\.displayScale) private var displayScale
    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif
    @State private var thumbnail: NSImage?

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: item.destinationURL.path)
    }

    private var displayName: String {
        fileExists ? item.destinationURL.lastPathComponent : item.suggestedFileName
    }

    private var timestamp: String {
        DownloadsFlyoutTime.string(for: item.finishedAt ?? item.startedAt, relativeTo: Date())
    }

    private var isInFlight: Bool {
        switch item.state {
        case .pending, .inProgress, .paused: return true
        case .completed, .cancelled, .interrupted: return false
        }
    }

    private var progress: DownloadProgress {
        DownloadProgress(receivedBytes: item.receivedBytes, totalBytes: item.totalBytes, state: item.state)
    }

    var body: some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            rowContent
        } else {
            draggableRow
        }
        #else
        draggableRow
        #endif
    }

    private var draggableRow: some View {
        rowContent
            .onDrag {
                guard fileExists else { return NSItemProvider() }
                return NSItemProvider(contentsOf: item.destinationURL) ?? NSItemProvider()
            }
    }

    private var rowContent: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            thumbnailView
            VStack(alignment: .leading, spacing: 0) {
                Text(displayName)
                    .font(.system(size: OrbitMetrics.sidebarSpaceNameFontSize, weight: .regular))
                    .foregroundStyle(theme.readableForeground.opacity(OrbitMetrics.sidebarRowLabelOpacityInactive))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timestamp)
                    .font(.system(size: OrbitMetrics.sidebarRowFontSize, weight: .regular))
                    .foregroundStyle(theme.readableForeground.opacity(OrbitMetrics.sidebarSpaceNameOpacity))
                    .lineLimit(1)
                if isInFlight, let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .tint(theme.readableForeground)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard fileExists else { return }
            NSWorkspace.shared.open(item.destinationURL)
        }
        .orbitTooltip(displayName)
        .task(id: item.destinationURL) {
            let side = OrbitMetrics.spaceBadgeSize
            let scale = max(1, displayScale)
            if let hit = DownloadThumbnailStore.shared.cached(for: item.destinationURL, side: side, scale: scale) {
                thumbnail = hit
                return
            }
            thumbnail = await DownloadThumbnailStore.shared.thumbnail(for: item.destinationURL, side: side, scale: scale)
        }
    }

    private var thumbnailView: some View {
        Image(nsImage: thumbnail ?? DownloadFileIcon.icon(for: item, fileExists: fileExists))
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: OrbitMetrics.spaceBadgeSize, height: OrbitMetrics.spaceBadgeSize)
            .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius, style: .continuous))
            .opacity(item.state == .cancelled || item.state == .interrupted ? OrbitMetrics.spacePagerInactiveOpacity : 1)
    }
}

extension Notification.Name {
    static let orbitPresentBoostsEditor = Notification.Name("OrbitPresentBoostsEditor")
}
