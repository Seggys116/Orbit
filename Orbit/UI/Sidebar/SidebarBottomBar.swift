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
                    anchorMinX: Self.horizontalInset,
                    anchorMidX: Self.horizontalInset + OrbitMetrics.sidebarBottomBarIconSize / 2,
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

    // A plain SwiftUI Button's click is unreliable in this bar's hosting
    // configuration, so this uses OrbitNSActionButton instead.

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

    // MARK: Library

    private var libraryButton: some View {
        OrbitNSActionButton {
            downloadsPreviewTask?.cancel()
            downloadsPreviewTask = nil
            setDownloadsPreview(false)
            LibraryWindowController.show(section: .downloads)
        } label: {
            Image(systemName: "archivebox")
                .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                .foregroundStyle(theme.readableForeground)
                .frame(width: OrbitMetrics.sidebarBottomBarIconSize, height: OrbitMetrics.sidebarBottomBarIconSize)
                .background {
                    if showDownloadsPreview || isHoveringLibraryButton {
                        RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius, style: .continuous)
                            .fill(theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity))
                    }
                }
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
        isNewItemMenuPresented || NSApp.windows.contains { $0 is OrbitMenuPanel && $0.isVisible }
    }

    private func scheduleDownloadsPreview(hovering: Bool) {
        downloadsPreviewTask?.cancel()
        downloadsPreviewTask = nil
        guard hovering, !showDownloadsPreview else { return }
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
                if NSEvent.pressedMouseButtons & 1 != 0 { continue }
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
            installDownloadsEscapeMonitor()
        } else {
            isHoveringDownloadsPanel = false
            removeDownloadsEscapeMonitor()
        }
        if reduceMotion {
            showDownloadsPreview = shown
        } else {
            withAnimation(OrbitMotion.quick) { showDownloadsPreview = shown }
        }
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

enum DownloadsPreviewLayout {
    static let maxWidth: CGFloat = 300
    static let edgeInset: CGFloat = OrbitMetrics.sidebarHorizontalPadding
    static let gap: CGFloat = 4

    static func placement(containerWidth: CGFloat, anchorMinX: CGFloat) -> (originX: CGFloat, width: CGFloat) {
        let width = max(0, min(maxWidth, containerWidth - edgeInset * 2))
        let originX = min(max(anchorMinX, edgeInset), max(edgeInset, containerWidth - edgeInset - width))
        return (originX, width)
    }

    static let rowHeightBound: CGFloat = 52
    static let chromeHeightBound: CGFloat = 56

    /// Height the panel may occupy above the bar; `nil` when the bar's position inside the sidebar is unknown.
    static func maxHeight(spaceAbove: CGFloat?) -> CGFloat? {
        spaceAbove.map { max(0, $0 - edgeInset - gap) }
    }

    static func visibleRowCount(rowCount: Int, maxHeight: CGFloat?) -> Int {
        guard let maxHeight else { return rowCount }
        let fitting = Int((max(0, maxHeight - chromeHeightBound) / rowHeightBound).rounded(.down))
        return min(rowCount, fitting)
    }
}

struct DownloadsPreviewOverlay: View {
    var theme: SpaceTheme
    var containerWidth: CGFloat
    var spaceAbove: CGFloat?
    var anchorMinX: CGFloat
    var anchorMidX: CGFloat
    var reduceMotion: Bool
    var onHoverChange: (Bool) -> Void
    var onDismiss: () -> Void

    var body: some View {
        let placement = DownloadsPreviewLayout.placement(containerWidth: containerWidth, anchorMinX: anchorMinX)
        let anchorX = placement.width > 0 ? min(max((anchorMidX - placement.originX) / placement.width, 0), 1) : 0
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
                    : .opacity.combined(with: .scale(scale: 0.94, anchor: UnitPoint(x: anchorX, y: 1)))
            )
    }
}

struct DownloadsPreviewPanel: View {
    static let cornerRadius = OrbitMetrics.sidebarRowCornerRadius + OrbitMetrics.sidebarHorizontalPadding / 2

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
        let all = env.recentDownloads
        let downloads = Array(all.prefix(DownloadsPreviewLayout.visibleRowCount(rowCount: all.count, maxHeight: maxHeight)))
        VStack(spacing: 0) {
            if all.isEmpty {
                if DownloadsPreviewLayout.visibleRowCount(rowCount: 1, maxHeight: maxHeight) > 0 {
                    emptyState
                }
            } else {
                ForEach(downloads) { item in
                    DownloadsPreviewRow(item: item, theme: theme, onDismiss: onDismiss)
                }
            }

            Rectangle()
                .fill(theme.readableForeground.opacity(OrbitMetrics.cardBorderOpacity))
                .frame(height: OrbitMetrics.cardBorderWidth)
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
                .padding(.vertical, 4)

            footer
        }
        .padding(.vertical, 6)
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

    private var emptyState: some View {
        Text("No recent downloads")
            .font(OrbitFont.commandBarRowSubtitle)
            .foregroundStyle(theme.readableSecondaryForeground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .padding(.vertical, 12)
    }

    private var footer: some View {
        Text("Show all downloads")
            .font(OrbitFont.commandBarRowTitle)
            .foregroundStyle(theme.readableForeground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                    .fill(isHoveringFooter ? theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity) : .clear)
                    .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding / 2)
            )
            .contentShape(Rectangle())
            .onHover { isHoveringFooter = $0 }
            .onTapGesture {
                onDismiss()
                LibraryWindowController.show(section: .downloads)
            }
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

struct DownloadsPreviewRow: View {
    static let thumbnailSide: CGFloat = 32

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

    private var timestamp: String {
        DownloadsFlyoutTime.string(for: item.finishedAt ?? item.startedAt, relativeTo: Date())
    }

    private var detailText: String {
        switch item.state {
        case .completed:
            if !fileExists { return "Moved or deleted" }
            let bytes = item.totalBytes > 0 ? item.totalBytes : item.receivedBytes
            return "\(LibraryByteFormat.string(bytes)) · \(timestamp)"
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
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(OrbitFont.commandBarRowTitle)
                    .foregroundStyle(theme.readableForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailText)
                    .font(OrbitFont.commandBarRowSubtitle)
                    .foregroundStyle(theme.readableSecondaryForeground)
                    .lineLimit(1)
                if isInFlight {
                    progressBar
                }
            }
            Spacer(minLength: 0)
            trailingControl
        }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                .fill(isHovering && !isMissing ? theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity) : .clear)
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding / 2)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { open() }
        .help(displayName)
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
            .aspectRatio(contentMode: .fill)
            .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
            .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius, style: .continuous))
            .opacity(item.state == .cancelled || item.state == .interrupted || isMissing ? OrbitMetrics.spacePagerInactiveOpacity : 1)
    }

    @ViewBuilder
    private var trailingControl: some View {
        Group {
            if isInFlight {
                controlButton(symbol: "xmark", help: "Cancel") {
                    env.cancelDownload(item.id)
                }
            } else {
                controlButton(symbol: "folder", help: "Show in Finder") {
                    env.downloadStore.revealInFinder(item.id)
                    onDismiss()
                }
            }
        }
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }

    private func controlButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.readableForeground)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
