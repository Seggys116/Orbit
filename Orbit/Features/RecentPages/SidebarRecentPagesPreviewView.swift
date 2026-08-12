import SwiftUI

// MARK: - The card

struct SidebarRecentPagesPreviewView: View {
    var data: RecentPagesData
    var onOpen: (URL) -> Void
    var onCreate: (() -> Void)?
    @Binding var isPointerInside: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                SidebarRecentPagesPreviewList(items: data.items, onOpen: onOpen)
            }
            .frame(maxHeight: OrbitMetrics.folderPreviewMaxHeight)
        }
        .frame(width: OrbitMetrics.folderPreviewWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.popoverCornerRadius))
        .onHover { isPointerInside = $0 }
    }

    private var header: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            FaviconView(url: nil, host: data.iconHost)
                .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            Text(data.service.cardHeading)
                .font(OrbitFont.spaceTitle)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let onCreate {
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .bold))
                        .frame(
                            width: OrbitMetrics.sidebarCloseButtonSize,
                            height: OrbitMetrics.sidebarCloseButtonSize
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .orbitTooltip("New \(data.service.displayName) page")
            }
        }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        .padding(.vertical, OrbitMetrics.sidebarRowContentSpacing / 2)
    }
}

// Split out from the scroll container: ImageRenderer renders ScrollView content blank,
// so a render test of the whole card would assert against an empty bitmap.
struct SidebarRecentPagesPreviewList: View {
    var items: [RecentPagesItem]
    var onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                SidebarRecentPagesPreviewRow(item: item, onOpen: onOpen)
            }
        }
    }
}

struct SidebarRecentPagesPreviewRow: View {
    var item: RecentPagesItem
    var onOpen: (URL) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle)
                    .font(OrbitFont.commandBarRowTitle)
                    .lineLimit(1)
                Text(CommandBarRelativeTime.string(from: item.lastVisitDate))
                    .font(OrbitFont.commandBarRowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding)
        .frame(height: OrbitMetrics.commandBarRowHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.sidebarRowCornerRadius)
                .fill(isHovering ? Color.primary.opacity(OrbitMetrics.sidebarHoverRowOpacity) : .clear)
                .padding(.horizontal, OrbitMetrics.sidebarHorizontalPadding / 2)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onOpen(item.url) }
    }
}

// MARK: - Attaching it to a row

extension View {
    func sidebarRecentPagesPreview(tab: Tab) -> some View {
        modifier(SidebarRecentPagesPreviewModifier(tab: tab))
    }
}

struct SidebarRecentPagesPreviewModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab

    @State private var controller = SidebarRecentPagesPreviewController()
    @State private var isRowHovered = false
    @State private var isCardHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isRowHovered = hovering
                refresh()
            }
            .onChange(of: isCardHovered) { _, _ in refresh() }
            // orbitHoverPopover, not a plain .popover: the latter's .transient behavior consumes
            // the dismissing click, eating whatever the user actually clicked next.
            .orbitHoverPopover(
                isPresented: Binding(
                    get: { controller.data != nil },
                    set: { if !$0 { dismiss() } }
                ),
                preferredEdge: .maxX
            ) {
                if let data = controller.data {
                    SidebarRecentPagesPreviewView(
                        data: data,
                        onOpen: { open($0) },
                        onCreate: RecentPagesNewDocument.url(for: data.service).map { url in
                            { open(url) }
                        },
                        isPointerInside: $isCardHovered
                    )
                }
            }
            .onDisappear { dismiss() }
    }

    private func refresh() {
        let isServiceRow = SidebarRecentPagesPreviewController.service(for: tab) != nil
        let isSpacePersistent = !isIncognitoSpace(tab.spaceID)

        controller.hoverChanged(
            hovering: isRowHovered || isCardHovered,
            tab: tab,
            isSpacePersistent: isSpacePersistent,
            source: (isSpacePersistent && isServiceRow)
                ? RecentPagesHistoryConnection.source()
                : .unavailable,
            query: RecentPagesQuery(excludedSpaceIDs: incognitoSpaceIDs())
        )
    }

    // A new tab, not a replace: these rows are history, and navigating the hovered Pinned tab
    // away from its own URL is the accident "Resetting a Pinned Tab" exists to undo.
    private func open(_ url: URL) {
        env.openTab(url: url, in: tab.spaceID)
        dismiss()
    }

    private func dismiss() {
        isRowHovered = false
        isCardHovered = false
        controller.dismiss()
    }

    // Refuse, not allow, when the Space can't be resolved — the safe default everywhere in this codebase.
    private func isIncognitoSpace(_ spaceID: SpaceID) -> Bool {
        guard let space = env.state.spaces.first(where: { $0.id == spaceID }) else { return true }
        return env.isIncognito(space)
    }

    // A second, non-redundant refusal: bulk importers can write to HistoryStore directly, bypassing
    // the Incognito check in recordVisit, so this excludes Incognito Spaces' rows from the query itself.
    private func incognitoSpaceIDs() -> Set<SpaceID> {
        Set(env.state.spaces.filter { env.isIncognito($0) }.map(\.id))
    }
}
