import AppKit
import SwiftUI

struct SidebarBottomBar: View {
    @Environment(AppEnvironment.self) private var env
    var theme: SpaceTheme

    @State private var showDownloadsPreview = false
    @State private var isHoveringLibraryButton = false
    @State private var isHoveringDownloadsPanel = false
    @State private var downloadsPreviewTask: Task<Void, Never>?
    @State private var downloadsCloseTask: Task<Void, Never>?
    @State private var downloadsEscapeMonitor: Any?
    @State private var barWidth: CGFloat = 0
    @State private var spaceAboveBar: CGFloat?
    @State private var isNewItemMenuPresented = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDisabled
    @Environment(\.orbitForcesDownloadsPreview) private var forcesDownloadsPreview
    #else
    private let forcesDownloadsPreview = false
    #endif

    static let sidebarSpace = "OrbitSidebar"

    private static let horizontalInset = (OrbitMetrics.sidebarBottomBarHeight - OrbitMetrics.sidebarBottomBarIconSize) / 2

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
        .padding(.horizontal, Self.horizontalInset)
        .frame(height: OrbitMetrics.sidebarBottomBarHeight)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in barWidth = width }
                    .onChange(of: proxy.frame(in: .named(Self.sidebarSpace)).minY, initial: true) { _, top in
                        spaceAboveBar = top > 0 ? top : nil
                    }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showDownloadsPreview || forcesDownloadsPreview {
                DownloadsPreviewOverlay(
                    theme: theme,
                    containerWidth: barWidth,
                    spaceAbove: spaceAboveBar,
                    reduceMotion: reduceMotion,
                    onHoverChange: { hovering in
                        isHoveringDownloadsPanel = hovering
                        scheduleDownloadsPreviewClose()
                    },
                    onDismiss: { setDownloadsPreview(false) }
                )
            }
        }
        .onDisappear {
            downloadsPreviewTask?.cancel()
            downloadsCloseTask?.cancel()
            removeDownloadsEscapeMonitor()
        }
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

    // A plain SwiftUI Button's click is unreliable in this bar's hosting configuration, so this uses OrbitNSActionButton instead.

    private var newItemMenu: some View {
        OrbitNSActionButton {
            if OrbitMenuClickGuard.wasDismissedThisTurn {
                isNewItemMenuPresented = false
                return
            }
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


    // The button opens Library mode in this window's sidebar and closes it again on the next click.
    private var libraryButton: some View {
        OrbitNSActionButton {
            downloadsPreviewTask?.cancel()
            downloadsPreviewTask = nil
            setDownloadsPreview(false)
            env.toggleLibrary()
        } label: {
            Image(systemName: "archivebox")
                .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                .foregroundStyle(theme.readableForeground)
                .frame(width: OrbitMetrics.sidebarBottomBarIconSize, height: OrbitMetrics.sidebarBottomBarIconSize)
                .background {
                    if showDownloadsPreview || isHoveringLibraryButton || env.isLibraryMode {
                        RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius, style: .continuous)
                            .fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity))
                    }
                }
                .accessibilityLabel("Library")
                .accessibilityAddTraits(env.isLibraryMode ? .isSelected : [])
        }
        .onHover { hovering in
            isHoveringLibraryButton = hovering
            scheduleDownloadsPreview(hovering: hovering)
            scheduleDownloadsPreviewClose()
        }
    }

    static let downloadsPreviewIntentDelay: UInt64 = 350_000_000

    static func canPresentDownloadsPreview(
        sidebarDragInFlight: Bool,
        menuIsOpen: Bool,
        primaryButtonIsDown: Bool,
        screenshotMode: Bool
    ) -> Bool {
        !sidebarDragInFlight && !menuIsOpen && !primaryButtonIsDown && !screenshotMode
    }

    private var isScreenshotMode: Bool {
        #if DEBUG
        screenshotModeDisabled
        #else
        false
        #endif
    }

    private var anotherMenuIsOpen: Bool {
        isNewItemMenuPresented || Self.menuPanelIsOpen
    }

    // A row's own context menu is a menu panel too; the flyout must outlive it.
    private static var menuPanelIsOpen: Bool {
        NSApp.windows.contains { $0 is OrbitMenuPanel && $0.isVisible }
    }

    private func scheduleDownloadsPreview(hovering: Bool) {
        downloadsPreviewTask?.cancel()
        downloadsPreviewTask = nil
        guard hovering, !showDownloadsPreview else { return }
        env.downloadStore.startWatchingFolder()
        downloadsPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.downloadsPreviewIntentDelay)
            guard !Task.isCancelled, isHoveringLibraryButton else { return }
            guard Self.canPresentDownloadsPreview(
                sidebarDragInFlight: SidebarDragSession.hasInFlightDrag,
                menuIsOpen: anotherMenuIsOpen,
                primaryButtonIsDown: NSEvent.pressedMouseButtons & 1 != 0,
                screenshotMode: isScreenshotMode
            ) else { return }
            setDownloadsPreview(true)
        }
    }

    // Moving into the panel, or dragging a row out of it with the button down, must not close the drag's source panel.
    private func scheduleDownloadsPreviewClose() {
        downloadsCloseTask?.cancel()
        downloadsCloseTask = nil
        guard showDownloadsPreview, !isHoveringLibraryButton, !isHoveringDownloadsPanel else { return }
        downloadsCloseTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.downloadsPreviewCloseGrace)
                guard !Task.isCancelled, !isHoveringLibraryButton, !isHoveringDownloadsPanel else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 || Self.menuPanelIsOpen { continue }
                setDownloadsPreview(false)
                return
            }
        }
    }

    static let downloadsPreviewCloseGrace = UInt64(OrbitHoverPopoverPointerZone.grace * 1_000_000_000)

    private func setDownloadsPreview(_ shown: Bool) {
        guard shown != showDownloadsPreview else { return }
        downloadsCloseTask?.cancel()
        downloadsCloseTask = nil
        if shown {
            env.downloadStore.startWatchingFolder()
            installDownloadsEscapeMonitor()
        } else {
            isHoveringDownloadsPanel = false
            removeDownloadsEscapeMonitor()
        }
        // Reduce Motion keeps the fade and drops the movement (see DownloadsPreviewOverlay's transition).
        withAnimation(reduceMotion ? OrbitMotion.fade : OrbitMotion.quick) { showDownloadsPreview = shown }
    }

    private func installDownloadsEscapeMonitor() {
        removeDownloadsEscapeMonitor()
        downloadsEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // kVK_Escape
            setDownloadsPreview(false)
            return nil
        }
    }

    private func removeDownloadsEscapeMonitor() {
        if let downloadsEscapeMonitor {
            NSEvent.removeMonitor(downloadsEscapeMonitor)
        }
        downloadsEscapeMonitor = nil
    }
}


enum DownloadsFlyoutSelection {
    /// The flyout shows the last few downloads, no more.
    static let maxRows = 4

    /// The most recent `maxRows` downloads, newest first. Equal start times keep their given order.
    static func visible(from items: [DownloadItem]) -> [DownloadItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                lhs.element.startedAt == rhs.element.startedAt
                    ? lhs.offset < rhs.offset
                    : lhs.element.startedAt > rhs.element.startedAt
            }
            .prefix(maxRows)
            .map(\.element)
    }
}


enum DownloadsPreviewLayout {
    /// The panel runs the sidebar's full width, inset from each edge by the bottom bar's own padding.
    static let edgeInset: CGFloat = OrbitMetrics.sidebarBottomBarHorizontalPadding
    static let gap: CGFloat = 4

    static func placement(containerWidth: CGFloat) -> (originX: CGFloat, width: CGFloat) {
        (edgeInset, max(0, containerWidth - edgeInset * 2))
    }

    /// Divider, footer and the panel's own padding: what the rows never get.
    static let chromeHeightBound: CGFloat = 56

    /// Height the panel may occupy above the bar; `nil` when the bar's position inside the sidebar is unknown.
    static func maxHeight(spaceAbove: CGFloat?) -> CGFloat? {
        spaceAbove.map { max(0, $0 - edgeInset - gap) }
    }

    /// Height the rows may occupy; past it they scroll instead of running off the top of the sidebar.
    static func rowsMaxHeight(panelMaxHeight: CGFloat?) -> CGFloat? {
        panelMaxHeight.map { max(0, $0 - chromeHeightBound) }
    }

    /// Every row is the same height: the icon is taller than its two text lines and the progress bar.
    static let rowHeight: CGFloat = DownloadsPreviewRow.thumbnailSide + DownloadsPreviewRow.verticalPadding * 2

    /// Whether the rows need their own scroller to stay inside `rowsMaxHeight`.
    static func rowsScroll(rowCount: Int, rowsMaxHeight: CGFloat?) -> Bool {
        guard let rowsMaxHeight else { return false }
        return CGFloat(rowCount) * rowHeight > rowsMaxHeight
    }
}

struct DownloadsPreviewOverlay: View {
    var theme: SpaceTheme
    var containerWidth: CGFloat
    var spaceAbove: CGFloat?
    var reduceMotion: Bool
    var onHoverChange: (Bool) -> Void
    var onDismiss: () -> Void

    var body: some View {
        let placement = DownloadsPreviewLayout.placement(containerWidth: containerWidth)
        DownloadsPreviewPanel(
            theme: theme,
            width: placement.width,
            maxHeight: DownloadsPreviewLayout.maxHeight(spaceAbove: spaceAbove),
            onDismiss: onDismiss
        )
            .padding(.bottom, DownloadsPreviewLayout.gap)
            .contentShape(Rectangle())
            .onHover(perform: onHoverChange)
            .padding(.leading, placement.originX)
            .offset(y: -OrbitMetrics.sidebarBottomBarHeight)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity
                        .combined(with: .offset(y: OrbitSpacing.md))
                        .combined(with: .scale(scale: 0.97, anchor: .bottom))
            )
    }
}

struct DownloadsPreviewPanel: View {
    static let cornerRadius = OrbitRadius.panel
    /// Row pills sit this far inside the panel edge.
    static let rowInset = OrbitMetrics.sidebarHorizontalPadding / 2
    static let rowCornerRadius = OrbitRadius.concentric(outer: cornerRadius, inset: rowInset)

    @Environment(AppEnvironment.self) private var env
    var theme: SpaceTheme
    var width: CGFloat
    var maxHeight: CGFloat?
    var onDismiss: () -> Void

    @State private var isHoveringFooter = false

    private var surface: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        let downloads = DownloadsFlyoutSelection.visible(from: env.recentDownloads)
        VStack(spacing: 0) {
            if downloads.isEmpty {
                emptyState
            } else {
                rows(downloads)
            }

            Rectangle()
                .fill(theme.readableForeground.opacity(OrbitMetrics.cardBorderOpacity))
                .frame(height: OrbitMetrics.cardBorderWidth)
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
                .padding(.vertical, OrbitSpacing.xs)

            footer
        }
        .padding(.vertical, OrbitSpacing.sm)
        .frame(width: width)
        .background(
            surface
                .fill(Color(theme.primary.nsColor))
                .overlay(surface.fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity)))
        )
        .overlay(
            surface.strokeBorder(
                theme.readableForeground.opacity(OrbitMetrics.cardBorderOpacity),
                lineWidth: OrbitMetrics.cardBorderWidth
            )
        )
        .shadow(
            color: .black.opacity(OrbitMetrics.contextMenuShadowOpacity),
            radius: OrbitMetrics.contextMenuShadowRadius,
            y: OrbitMetrics.contextMenuShadowYOffset
        )
        .contentShape(surface)
    }

    // Scrolls only when the room above the bar cannot hold every row; decided from the fixed row height, not ViewThatFits, whose proposal here is the bar's own height and would always pick the scroller.
    @ViewBuilder
    private func rows(_ downloads: [DownloadItem]) -> some View {
        let list = VStack(spacing: 0) {
            ForEach(downloads) { item in
                DownloadsPreviewRow(item: item, theme: theme, onDismiss: onDismiss)
            }
        }
        let limit = DownloadsPreviewLayout.rowsMaxHeight(panelMaxHeight: maxHeight)
        if let limit, DownloadsPreviewLayout.rowsScroll(rowCount: downloads.count, rowsMaxHeight: limit) {
            ScrollView { list }
                .scrollIndicators(.hidden)
                .frame(height: limit)
        } else {
            list
        }
    }

    private var emptyState: some View {
        Text("No recent downloads")
            .font(OrbitFont.commandBarRowSubtitle)
            .foregroundStyle(theme.readableSecondaryForeground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .padding(.vertical, OrbitSpacing.lg)
    }

    private var footer: some View {
        Text("Show all downloads")
            .font(OrbitFont.commandBarRowTitle)
            .foregroundStyle(theme.readableForeground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .padding(.vertical, OrbitSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
                    .fill(isHoveringFooter ? theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity) : .clear)
                    .padding(.horizontal, Self.rowInset)
            )
            .contentShape(Rectangle())
            .onHover { isHoveringFooter = $0 }
            .onTapGesture {
                onDismiss()
                env.openLibrary(section: .downloads)
            }
            .accessibilityAddTraits(.isButton)
    }
}

@MainActor
enum DownloadsFlyoutTime {
    private static let formatter = RelativeDateTimeFormatter()

    /// Under a minute reads "Just now": the formatter would say "in 0 seconds" for a download that finished a moment ago.
    static func string(for date: Date, relativeTo reference: Date, locale: Locale = .current) -> String {
        if abs(date.timeIntervalSince(reference)) < 60 { return "Just now" }
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

struct DownloadsPreviewRow: View {
    /// A large file icon, not a favicon-sized glyph.
    static let thumbnailSide: CGFloat = 40
    static let verticalPadding: CGFloat = OrbitSpacing.sm

    @Environment(AppEnvironment.self) private var env
    @Environment(\.displayScale) private var displayScale
    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    var item: DownloadItem
    var theme: SpaceTheme
    var onDismiss: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    private var fileExists: Bool {
        env.downloadStore.fileStillExists(item.id)
    }

    private var isInFlight: Bool {
        switch item.state {
        case .pending, .inProgress, .paused: return true
        case .completed, .cancelled, .interrupted: return false
        }
    }

    private var isOpenable: Bool { item.state == .completed && fileExists }

    private var isMissing: Bool { item.state == .completed && !fileExists }

    private var displayName: String {
        fileExists ? item.destinationURL.lastPathComponent : item.suggestedFileName
    }

    private var progress: DownloadProgress {
        DownloadProgress(receivedBytes: item.receivedBytes, totalBytes: item.totalBytes, state: item.state)
    }

    /// The second line. Pure over `now` so the live-updating row and the tests share one definition.
    static func detailText(for item: DownloadItem, fileExists: Bool, now: Date, locale: Locale = .current) -> String {
        let timestamp = DownloadsFlyoutTime.string(for: item.finishedAt ?? item.startedAt, relativeTo: now, locale: locale)
        switch item.state {
        case .completed:
            return fileExists ? timestamp : "Moved or deleted"
        case .cancelled:
            return "Cancelled · \(timestamp)"
        case .interrupted:
            return "Failed · \(timestamp)"
        case .pending:
            return "Starting…"
        case .inProgress, .paused:
            let received = LibraryByteFormat.string(item.receivedBytes)
            let text = item.totalBytes > 0 ? "\(received) of \(LibraryByteFormat.string(item.totalBytes))" : received
            return item.state == .paused ? "Paused · \(text)" : text
        }
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

    @ViewBuilder
    private var draggableRow: some View {
        if isOpenable {
            rowContent
                .onDrag { NSItemProvider(contentsOf: item.destinationURL) ?? NSItemProvider() }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            thumbnailView
            VStack(alignment: .leading, spacing: OrbitSpacing.xxs) {
                Text(displayName)
                    .font(OrbitFont.commandBarRowTitle)
                    .foregroundStyle(theme.readableForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Re-evaluated every minute so "24 minutes ago" keeps counting while the flyout is open.
                TimelineView(.everyMinute) { context in
                    Text(Self.detailText(for: item, fileExists: fileExists, now: context.date))
                        .font(OrbitFont.commandBarRowSubtitle)
                        .foregroundStyle(theme.readableSecondaryForeground)
                        .lineLimit(1)
                }
                if isInFlight {
                    progressBar
                }
            }
            Spacer(minLength: 0)
            trailingControl
        }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(height: DownloadsPreviewLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: DownloadsPreviewPanel.rowCornerRadius, style: .continuous)
                .fill(isHovering && !isMissing ? theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity) : .clear)
                .padding(.horizontal, DownloadsPreviewPanel.rowInset)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { open() }
        .orbitRightClickMenu { menuEntries }
        .orbitTooltip(displayName)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: item.destinationURL) {
            let side = Self.thumbnailSide
            let scale = max(1, displayScale)
            if let hit = DownloadThumbnailStore.shared.cached(for: item.destinationURL, side: side, scale: scale) {
                thumbnail = hit
                return
            }
            thumbnail = await DownloadThumbnailStore.shared.thumbnail(for: item.destinationURL, side: side, scale: scale)
        }
    }

    private var progressBar: some View {
        Capsule()
            .fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity * 2))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(theme.readableForeground)
                        .frame(width: proxy.size.width * (progress.fraction ?? 0.3))
                }
            }
    }

    private var thumbnailView: some View {
        Image(nsImage: thumbnail ?? DownloadFileIcon.icon(for: item, fileExists: fileExists))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
            .clipShape(RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous))
            .opacity(item.state == .cancelled || item.state == .interrupted || isMissing ? OrbitMetrics.spacePagerInactiveOpacity : 1)
            .accessibilityHidden(true)
    }

    // Only a running download has a control of its own; Show in Finder and Remove live in the context menu.
    @ViewBuilder
    private var trailingControl: some View {
        if isInFlight {
            Button {
                env.cancelDownload(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize - 1, weight: .semibold))
                    .foregroundStyle(theme.readableForeground)
                    .frame(width: OrbitMetrics.sidebarCloseButtonSize, height: OrbitMetrics.sidebarCloseButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .orbitTooltip("Cancel")
            .accessibilityLabel("Cancel download")
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
    }

    private var menuEntries: [OrbitContextMenuEntry] {
        var entries: [OrbitContextMenuEntry] = []
        if isInFlight {
            entries.append(.item(OrbitContextMenuItem(title: "Cancel", systemImage: "xmark") {
                env.cancelDownload(item.id)
            }))
        }
        entries.append(.item(OrbitContextMenuItem(title: "Show in Finder", systemImage: "folder", isEnabled: fileExists) {
            env.downloadStore.revealInFinder(item.id)
            onDismiss()
        }))
        if env.downloadStore.isFolderOnly(item.id) {
            entries.append(.item(OrbitContextMenuItem(title: "Move to Trash", systemImage: "trash", isEnabled: fileExists, isDestructive: true) {
                env.downloadStore.moveToTrash(item.id)
            }))
        } else {
            entries.append(.item(OrbitContextMenuItem(title: "Remove from List", systemImage: "trash", isDestructive: true) {
                env.downloadStore.remove(item.id)
            }))
        }
        return entries
    }

    private func open() {
        guard isOpenable else { return }
        NSWorkspace.shared.open(item.destinationURL)
        onDismiss()
    }
}

#if DEBUG
private struct OrbitForcesDownloadsPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var orbitForcesDownloadsPreview: Bool {
        get { self[OrbitForcesDownloadsPreviewKey.self] }
        set { self[OrbitForcesDownloadsPreviewKey.self] = newValue }
    }
}
#endif

extension Notification.Name {
    static let orbitPresentBoostsEditor = Notification.Name("OrbitPresentBoostsEditor")
}
