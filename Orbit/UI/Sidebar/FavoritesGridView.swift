import SwiftUI

let favoriteEmojiGlyphScale: CGFloat = 0.72

struct FavoritesGridMetrics: Equatable {
    static let fallbackAvailableWidth: CGFloat =
        OrbitMetrics.sidebarDefaultWidth
            - 2 * (OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)

    let availableWidth: CGFloat
    let columnCount: Int
    let tileWidth: CGFloat
    let tileHeight: CGFloat

    init(availableWidth: CGFloat) {
        let width = availableWidth > 0 ? availableWidth : Self.fallbackAvailableWidth
        let spacing = OrbitMetrics.favoriteGridSpacing
        let fitting = Int(((width + spacing) / (OrbitMetrics.favoriteTileMinWidth + spacing)).rounded(.down))
        let count = max(1, fitting)
        let resolvedWidth = (width - CGFloat(count - 1) * spacing) / CGFloat(count)

        self.availableWidth = width
        self.columnCount = count
        self.tileWidth = max(resolvedWidth, 1)
        self.tileHeight = min(max(resolvedWidth, 1), OrbitMetrics.favoriteTileHeight)
    }

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: OrbitMetrics.favoriteGridSpacing),
            count: columnCount
        )
    }
}

struct FavoritesGridView: View {
    @Environment(AppEnvironment.self) private var env
    var spaceID: SpaceID
    var theme: SpaceTheme

    @State private var isDropTargeted = false
    @State private var draggingID: UUID?
    @State private var draggingResetTask: Task<Void, Never>?

    @State private var flashingID: UUID?
    @State private var flashingResetTask: Task<Void, Never>?

    private let favoritesToastPresenter = FavoritesToastPresenter.shared

    private func beginDragging(_ id: UUID) {
        draggingResetTask?.cancel()
        draggingID = id
        draggingResetTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            draggingID = nil
        }
    }

    private func endDragging() {
        draggingResetTask?.cancel()
        draggingResetTask = nil
        draggingID = nil
    }

    private func beginFlashing(_ id: UUID) {
        flashingResetTask?.cancel()
        flashingID = id
        flashingResetTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            flashingID = nil
        }
    }

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    private var favorites: [Favorite] { env.favorites(for: spaceID) }

    @State private var measuredWidth: CGFloat = 0

    @State private var hoveredID: UUID?

    func metrics(for width: CGFloat) -> FavoritesGridMetrics {
        FavoritesGridMetrics(availableWidth: width)
    }

    private var currentMetrics: FavoritesGridMetrics { metrics(for: measuredWidth) }

    var body: some View {
        Group {
            if favorites.isEmpty {
                Color.clear
                    .frame(height: 0)
                    .overlay(alignment: .top) { emptyDropZone }
            } else {
                populatedGrid
            }
        }
        .animation(OrbitMotion.quick, value: isDropTargeted)
        .overlay(alignment: .bottom) {
            SidebarToastView(theme: theme, presenter: favoritesToastPresenter)
        }
    }

    private var populatedGrid: some View {
        let metrics = currentMetrics
        let grid = LazyVGrid(columns: metrics.columns, spacing: OrbitMetrics.favoriteGridSpacing) {
            ForEach(favorites) { favorite in
                favoriteIcon(favorite, metrics: metrics)
            }
        }
        .frame(maxWidth: .infinity)
        .background { widthReader }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding + OrbitMetrics.sidebarRowContentInset)
        .padding(.top, OrbitMetrics.favoriteGridVerticalPadding)
        .padding(.bottom, OrbitMetrics.favoriteGridVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.favoriteTileCornerRadius, style: .continuous)
                .fill(isDropTargeted ? theme.readableForeground.opacity(0.10) : .clear)
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        )

        // sidebarPayloadDropDestination, not dropDestination(for:), which forces AppKit's green + badge onto the drag image.
        return Group {
            #if DEBUG
            if screenshotModeDragDisabled {
                grid
            } else {
                grid.sidebarPayloadDropDestination(action: handleFavoriteDrop) { targeted in
                    isDropTargeted = targeted
                }
            }
            #else
            grid.sidebarPayloadDropDestination(action: handleFavoriteDrop) { targeted in
                isDropTargeted = targeted
            }
            #endif
        }
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    guard abs(width - measuredWidth) > 0.5 else { return }
                    measuredWidth = width
                }
        }
    }

    private var emptyDropZone: some View {
        let shape = RoundedRectangle(cornerRadius: OrbitMetrics.favoriteTileCornerRadius, style: .continuous)
            .fill(isDropTargeted ? theme.readableForeground.opacity(0.10) : .clear)
            .frame(height: OrbitMetrics.sidebarRowHeight)
            .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
            .contentShape(Rectangle())
        #if DEBUG
        return Group {
            if screenshotModeDragDisabled {
                shape
            } else {
                shape.sidebarPayloadDropDestination(action: handleFavoriteDrop) { targeted in
                    isDropTargeted = targeted
                }
            }
        }
        #else
        return shape.sidebarPayloadDropDestination(action: handleFavoriteDrop) { targeted in
            isDropTargeted = targeted
        }
        #endif
    }

    private func handleFavoriteDrop(_ items: [SidebarDragPayload], _ location: CGPoint) -> Bool {
        endDragging()
        guard let item = items.first, item.kind != .favorite else { return false }
        guard let outcome = env.promoteTabToFavorite(item.nodeID) else { return false }
        switch outcome {
        case .added:
            return true
        case .alreadyExists(let id):
            beginFlashing(id)
            favoritesToastPresenter.announceAlreadyFavorite()
            return true
        case .atCapacity:
            favoritesToastPresenter.announceAtCapacity()
            return false
        }
    }

    private func favoriteIcon(_ favorite: Favorite, metrics: FavoritesGridMetrics) -> some View {
        let payload = SidebarDragPayload(nodeID: favorite.id, kind: .favorite, spaceID: spaceID)
        let shape = RoundedRectangle(cornerRadius: OrbitMetrics.favoriteTileCornerRadius, style: .continuous)
        let isHovered = hoveredID == favorite.id
        let isFlashing = flashingID == favorite.id
        let base = ZStack {
            shape
                .fill(theme.readableForeground.opacity(isFlashing ? 0.28 : (isHovered ? 0.16 : 0.09)))
                .overlay(shape.strokeBorder(theme.readableForeground.opacity(isFlashing ? 0.55 : 0.07), lineWidth: isFlashing ? 2 : 1))
            tileContent(favorite)
        }
        .frame(maxWidth: .infinity)
        .frame(height: metrics.tileHeight)
        .clipShape(shape)
        .opacity(draggingID == favorite.id ? 0.35 : 1)
        .animation(OrbitMotion.quick, value: isFlashing)
        .contentShape(shape)
        .onHover { hovering in
            withAnimation(OrbitMotion.quick) {
                if hovering {
                    hoveredID = favorite.id
                } else if hoveredID == favorite.id {
                    hoveredID = nil
                }
            }
        }

        // Plain .onTapGesture + .draggable, not sidebarRowDragSource: that catcher breaks both clicking and dragging here.
        let interactiveTile = Group {
            #if DEBUG
            if screenshotModeDragDisabled {
                base
            } else {
                base
                    .sidebarDragSource(payload) { dragPreview(for: favorite) }
                    .onTapGesture { env.activateFavorite(favorite, in: spaceID) }
            }
            #else
            base
                .sidebarDragSource(payload) { dragPreview(for: favorite) }
                .onTapGesture { env.activateFavorite(favorite, in: spaceID) }
            #endif
        }

        return reorderDropDestination(interactiveTile, favorite: favorite)
            .contextMenu {
                Button("Open") { env.activateFavorite(favorite, in: spaceID) }
                if CalendarSiteMatcher.isCalendar(favorite.url) {
                    Divider()
                    liveCalendarMenuItems
                    Divider()
                }
                Button("Remove from Favorites", role: .destructive) { env.removeFavorite(favorite.id, from: spaceID) }
            }
            .orbitTooltip(favorite.title)
    }

    @ViewBuilder
    private func tileContent(_ favorite: Favorite) -> some View {
        let glyph = faviconImage(favorite, glyphBoxSize: OrbitMetrics.favoriteIconGlyphSize)
            .frame(width: OrbitMetrics.favoriteIconGlyphSize, height: OrbitMetrics.favoriteIconGlyphSize)

        if let countdown = calendarCountdown(for: favorite) {
            VStack(spacing: 2) {
                glyph
                LiveCalendarCountdownPill(text: countdown)
            }
        } else {
            glyph
        }
    }

    private func dragPreview(for favorite: Favorite) -> some View {
        let shape = RoundedRectangle(cornerRadius: OrbitMetrics.favoriteTileCornerRadius, style: .continuous)
        return ZStack {
            shape.fill(theme.readableForeground.opacity(0.16))
            tileContent(favorite)
        }
        .frame(width: currentMetrics.tileWidth, height: currentMetrics.tileHeight)
        .clipShape(shape)
        .onAppear { beginDragging(favorite.id) }
    }

    @ViewBuilder
    private var liveCalendarMenuItems: some View {
        if LiveCalendarSettings.isEnabled {
            Toggle("Show Time to Next Meeting", isOn: Binding(
                get: { LiveCalendarSettings.showsCountdown },
                set: { LiveCalendarSettings.showsCountdown = $0 }
            ))
            Toggle("Show Next Meeting Link", isOn: Binding(
                get: { LiveCalendarSettings.showsJoinRow },
                set: { LiveCalendarSettings.showsJoinRow = $0 }
            ))
            Menu("Notify Me") {
                ForEach(LiveCalendarLeadTime.allCases, id: \.rawValue) { option in
                    Toggle(option.title, isOn: Binding(
                        get: { LiveCalendarSettings.leadTime == option },
                        set: { if $0 { LiveCalendarSettings.leadTime = option } }
                    ))
                }
            }
            Button("Disable Live Calendar") {
                LiveCalendarSettings.isEnabled = false
                LiveCalendarStore.shared.stopRefreshing()
            }
        } else {
            Button("Enable Live Calendar") {
                LiveCalendarSettings.isEnabled = true
                Task { await LiveCalendarStore.shared.connect() }
            }
        }
    }

    private func calendarCountdown(for favorite: Favorite) -> String? {
        guard LiveCalendarSettings.isEnabled, LiveCalendarSettings.showsCountdown else { return nil }
        guard CalendarSiteMatcher.isCalendar(favorite.url) else { return nil }
        guard let event = LiveCalendarStore.shared.nextEvent else { return nil }
        return LiveCalendarCountdown.text(for: event, now: Date())
    }

    @ViewBuilder
    private func reorderDropDestination<V: View>(_ content: V, favorite: Favorite) -> some View {
        #if DEBUG
        if screenshotModeDragDisabled {
            content
        } else {
            content.sidebarPayloadDropDestination { items, _ in
                handleTileDrop(items, favorite: favorite)
            }
        }
        #else
        content.sidebarPayloadDropDestination { items, _ in
            handleTileDrop(items, favorite: favorite)
        }
        #endif
    }

    // Must accept both drop kinds: SwiftUI never re-offers a rejected drop to the ancestor .dropDestination.
    private func handleTileDrop(_ items: [SidebarDragPayload], favorite: Favorite) -> Bool {
        endDragging()
        guard let item = items.first else { return false }
        if item.kind == .favorite {
            guard item.nodeID != favorite.id else { return false }
            reorder(dragged: item.nodeID, onto: favorite.id)
            return true
        }
        return promote(item.nodeID, insertingAt: favorite.id)
    }

    private func promote(_ tabID: TabID, insertingAt targetID: UUID) -> Bool {
        guard let outcome = env.promoteTabToFavorite(tabID) else {
            return false
        }
        switch outcome {
        case .added(let newID):
            reorder(dragged: newID, onto: targetID)
            return true
        case .alreadyExists(let existingID):
            beginFlashing(existingID)
            favoritesToastPresenter.announceAlreadyFavorite()
            if existingID != targetID {
                reorder(dragged: existingID, onto: targetID)
            }
            return true
        case .atCapacity:
            favoritesToastPresenter.announceAtCapacity()
            return false
        }
    }

    @ViewBuilder
    private func faviconImage(_ favorite: Favorite, glyphBoxSize: CGFloat) -> some View {
        if favorite.customIconIsEmoji, let icon = favorite.customIcon {
            Text(icon).font(.system(size: glyphBoxSize * favoriteEmojiGlyphScale))
        } else {
            FaviconView(url: faviconURL(for: favorite), host: favorite.url.host() ?? favorite.url.absoluteString)
                .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius))
        }
    }

    private func faviconURL(for favorite: Favorite) -> URL? {
        guard let liveTabID = favorite.liveTabID else { return nil }
        return env.tab(liveTabID)?.faviconURL
    }

    // remove(at:) then insert(at: to) overshoots by one when dragging downward; insertionIndex(before:draggedIndex:) corrects it.
    private func reorder(dragged draggedID: UUID, onto targetID: UUID) {
        var ids = favorites.map(\.id)
        guard let from = ids.firstIndex(of: draggedID), let to = ids.firstIndex(of: targetID) else { return }
        let index = SidebarReorderMath.insertionIndex(before: to, draggedIndex: from)
        ids.remove(at: from)
        ids.insert(draggedID, at: index)
        env.reorderFavorites(ids, in: spaceID)
    }
}
