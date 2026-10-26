import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpaceSwitcherPagerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.spaceSwipeProgress) private var swipeProgress
    var theme: SpaceTheme

    var sizeScale: CGFloat = 1

    @State private var tabDropTargetID: SpaceID?
    @State private var isEditPresented = false
    @State private var editingSpaceID: SpaceID?
    @State private var mouseDragOffset: CGFloat = 0

    @State private var isIconChooserPresented = false
    @State private var iconChooserSpaceID: SpaceID?
    @State private var isThemeEditorPresented = false
    @State private var themeEditorSpaceID: SpaceID?

    #if DEBUG
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    private var orderedSpaces: [Space] { env.pagerSpaces }

    static let mouseDragCommitThreshold: CGFloat = 46

    private var hasSomethingToSwitchBetween: Bool { orderedSpaces.count > 1 }

    // Always renders, even at one Space; do not gate this behind a Space-count check.
    var body: some View {
        pager
    }

    private var pager: some View {
        HStack(spacing: OrbitMetrics.spacePagerDotSpacing * sizeScale) {
            ForEach(Array(orderedSpaces.enumerated()), id: \.element.id) { index, space in
                dot(for: space, index: index)
            }
        }
        .padding(OrbitMetrics.spacePagerContainerPadding * sizeScale)
        .background(
            Capsule()
                .fill(Color.clear)
                .contentShape(Capsule())
                // .simultaneousGesture, not .gesture: a plain .gesture() here competed for
                // exclusive recognition against each dot's own Button tap, and a click with even
                // a few points of ordinary pointer jitter could lose that race to this DragGesture
                // — the click was then silently swallowed (translation never reached
                // mouseDragCommitThreshold, so nothing happened) and the user had to click again.
                // Simultaneous recognition lets both live side by side: a real drag still pages
                // through Spaces, but a tap on a dot always reaches that dot's own Button.
                .simultaneousGesture(mouseDragGesture)
        )
        .offset(x: mouseDragOffset * 0.3)
        .popover(isPresented: $isEditPresented) {
            if let editingSpaceID {
                SpaceEditPopover(spaceID: editingSpaceID) { isEditPresented = false }
            }
        }
        .popover(isPresented: $isIconChooserPresented) {
            if let iconChooserSpaceID {
                SpaceIconChooserView { icon in
                    env.store.setIcon(icon, forSpace: iconChooserSpaceID)
                    isIconChooserPresented = false
                }
            }
        }
        .popover(isPresented: $isThemeEditorPresented) {
            if let themeEditorSpaceID, let space = env.space(themeEditorSpaceID) {
                ThemeEditorView(
                    theme: Binding(
                        get: { env.space(themeEditorSpaceID)?.theme ?? space.theme },
                        set: { env.updateSpaceTheme(themeEditorSpaceID, theme: $0) }
                    ),
                    spaceID: themeEditorSpaceID,
                    onDone: { isThemeEditorPresented = false }
                )
            }
        }
    }

    // MARK: - One dot

    private func dot(for space: Space, index: Int) -> some View {
        let isActive = space.id == env.activeSpace?.id
        let highlight = highlightIntensity(forIndex: index, isActive: isActive)

        // Plain .onTapGesture, not Button: a Button's own tap gesture raced .onDrag below for an
        // ordinary click's few points of pointer jitter and lost, silently swallowing the click
        // (measured directly in SpacePagerClickReliabilityTests). FavoritesGridView hit the exact
        // same failure with the exact same combination and documents the same fix at its own
        // sidebarDragSource call sites — .onTapGesture is what actually coexists with a drag source.
        let base = SpacePagerIconButton(
            space: space,
            theme: theme,
            highlight: highlight,
            sizeScale: sizeScale,
            isDropTarget: tabDropTargetID == space.id
        )
        .onTapGesture {
            withAnimation(OrbitMotion.dramatic) { env.selectSpace(space.id) }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(space.name)
        .orbitTooltip(space.name)
        .animation(OrbitMotion.quick, value: tabDropTargetID)

        return Group {
            #if DEBUG
            if screenshotModeDragDisabled {
                base
            } else {
                decoratedDot(base, space: space, index: index)
            }
            #else
            decoratedDot(base, space: space, index: index)
            #endif
        }
    }

    private func decoratedDot(_ base: some View, space: Space, index: Int) -> some View {
        base
            // .onDrag, not .draggable: see SidebarDragDrop.swift's own header — .draggable's
            // gesture recognizer competed with this dot's Button tap for an ordinary click's few
            // points of pointer jitter and silently swallowed it (measured directly in
            // SpacePagerClickReliabilityTests). .onDrag is the pattern already proven elsewhere in
            // this sidebar to coexist with a reliable click; .dropDestination(for:) still decodes
            // whatever it hands the pasteboard, so the drop side below is unchanged.
            .onDrag {
                Self.itemProvider(for: SpacePagerDragPayload(spaceID: space.id))
            } preview: {
                SpaceIconView(
                    icon: space.resolvedIcon,
                    size: OrbitMetrics.spacePagerDotSize,
                    foregroundColor: theme.readableForeground
                )
                .padding(4)
            }
            .dropDestination(for: SpacePagerDragPayload.self) { items, _ in
                guard let item = items.first, item.spaceID != space.id else { return false }
                reorder(dragged: item.spaceID, onto: space.id)
                return true
            } isTargeted: { _ in }
            .sidebarPayloadDropDestination { items, _ in
                guard let item = items.first else { return false }
                let tabID: TabID?
                switch item.kind {
                case .favorite:
                    tabID = env.resolvedTab(forFavorite: item.nodeID, in: item.spaceID)
                case .todayTab, .pinnedNode:
                    tabID = item.nodeID
                }
                guard let tabID else { return false }
                env.moveTab(tabID, toSpace: space.id, section: .today)
                return true
            } isTargeted: { targeted in
                tabDropTargetID = targeted ? space.id : (tabDropTargetID == space.id ? nil : tabDropTargetID)
            }
            .orbitRightClickMenu { dotMenuEntries(space: space, index: index) }
    }

    private func dotMenuEntries(space: Space, index: Int) -> [OrbitContextMenuEntry] {
        [
            .item(OrbitContextMenuItem(title: "New Folder", systemImage: "folder.badge.plus") {
                env.createFolder(name: "New Folder", in: space.id)
            }),
            .item(OrbitContextMenuItem(title: "Paste as New Tab", systemImage: "doc.on.clipboard") {
                pasteAsNewTab(into: space.id)
            }),
            .divider(),
            .item(OrbitContextMenuItem(title: "Rename Space", systemImage: "pencil") {
                editingSpaceID = space.id
                isEditPresented = true
            }),
            .item(OrbitContextMenuItem(title: "Change Icon…", systemImage: "face.smiling") {
                iconChooserSpaceID = space.id
                isIconChooserPresented = true
            }),
            .item(OrbitContextMenuItem(title: "Theme…", systemImage: "paintpalette") {
                themeEditorSpaceID = space.id
                isThemeEditorPresented = true
            }),
            .divider(),
            .item(OrbitContextMenuItem(title: "Duplicate", systemImage: "plus.square.on.square") {
                env.store.duplicateSpace(space.id)
            }),
            .divider(),
            .item(OrbitContextMenuItem(title: "Move Left", systemImage: "arrow.left", isEnabled: index != 0) {
                env.store.moveSpaceLeft(space.id)
            }),
            .item(OrbitContextMenuItem(title: "Move Right", systemImage: "arrow.right", isEnabled: index != orderedSpaces.count - 1) {
                env.store.moveSpaceRight(space.id)
            }),
            .divider(),
            .item(OrbitContextMenuItem(
                title: "Delete",
                systemImage: "trash",
                isEnabled: orderedSpaces.count > 1,
                isDestructive: true
            ) {
                env.deleteSpace(space.id)
            }),
        ]
    }

    private func pasteAsNewTab(into spaceID: SpaceID) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        guard let url = env.resolveTypedInput(string) else { return }
        env.openTab(url: url, in: spaceID)
    }

    private func highlightIntensity(forIndex index: Int, isActive: Bool) -> Double {
        guard swipeProgress.isDragging,
              let activeIndex = orderedSpaces.firstIndex(where: { $0.id == env.activeSpace?.id }) else {
            return isActive ? 1 : 0
        }
        let livePosition = CGFloat(activeIndex) - swipeProgress.fraction
        return max(0, 1 - abs(livePosition - CGFloat(index)))
    }

    // MARK: - Reordering

    private func reorder(dragged draggedID: SpaceID, onto targetID: SpaceID) {
        var ids = orderedSpaces.map(\.id)
        guard let from = ids.firstIndex(of: draggedID), let to = ids.firstIndex(of: targetID) else { return }
        ids.remove(at: from)
        ids.insert(draggedID, at: to)
        withAnimation(OrbitMotion.interactive) {
            env.reorderSpaces(ids)
        }
    }

    // MARK: - Mouse click-and-drag swipe

    // minimumDistance 24, not 6: onChanged below applies a real .offset() to the whole row the
    // instant this gesture recognizes, and that live layout shift — not just gesture-priority —
    // is what broke a dot's own Button tap on an ordinary click carrying a few points of pointer
    // jitter (measured empirically at ~7pt; see SpacePagerClickReliabilityTests). 24pt is comfortably
    // past any accidental click jitter but well short of mouseDragCommitThreshold (46), so a real
    // click-and-drag swipe still recognizes immediately once the user actually starts dragging.
    private var mouseDragGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                mouseDragOffset = value.translation.width
            }
            .onEnded { value in
                let translation = value.translation.width
                withAnimation(OrbitMotion.interactive) {
                    mouseDragOffset = 0
                }
                withAnimation(OrbitMotion.dramatic) {
                    _ = Self.commitMouseDrag(translation: translation, in: env)
                }
            }
    }

    // .all visibility, deliberately, matching SidebarDragSession.itemProvider(for:): narrowing
    // this risks the type not being advertised on the pasteboard at all, silently disabling drops.
    static func itemProvider(for payload: SpacePagerDragPayload) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        provider.registerDataRepresentation(for: .orbitSpacePagerPayload, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @discardableResult
    static func commitMouseDrag(translation: CGFloat, in env: AppEnvironment) -> Bool {
        guard abs(translation) >= mouseDragCommitThreshold else { return false }
        if translation < 0 {
            env.nextSpace()
        } else {
            env.previousSpace()
        }
        return true
    }

    // MARK: - Overflow protection

    static func sizeScale(forSpaceCount count: Int, availableWidth: CGFloat) -> CGFloat {
        guard count > 0, availableWidth > 0 else { return 1 }
        let fullSizeWidth = idealWidth(forSpaceCount: count, scale: 1)
        guard fullSizeWidth > availableWidth else { return 1 }
        let scaleThatWouldExactlyFit = availableWidth / fullSizeWidth
        return max(OrbitMetrics.spacePagerMinimumSizeScale, scaleThatWouldExactlyFit)
    }

    static func idealWidth(forSpaceCount count: Int, scale: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let dotsWidth = CGFloat(count) * OrbitMetrics.spacePagerDotSize * scale
        let gapsWidth = CGFloat(max(0, count - 1)) * OrbitMetrics.spacePagerDotSpacing * scale
        let paddingWidth = OrbitMetrics.spacePagerContainerPadding * 2 * scale
        return dotsWidth + gapsWidth + paddingWidth
    }
}

private struct SpacePagerIconButton: View {
    var space: Space
    var theme: SpaceTheme
    var highlight: Double
    var sizeScale: CGFloat
    var isDropTarget: Bool

    var body: some View {
        let side = OrbitMetrics.spacePagerDotSize * sizeScale
        SpaceIconView(
            icon: space.resolvedIcon,
            size: side,
            foregroundColor: theme.readableForeground,
            dim: 1 - highlight,
            emojiScale: 0.82,
            symbolScale: 0.9
        )
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .orbitHoverHighlight(
            fill: theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity),
            cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius
        )
        .scaleEffect(isDropTarget ? 1.12 : 1)
    }
}

struct SpacePagerDragPayload: Codable, Transferable, Equatable {
    var spaceID: SpaceID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .orbitSpacePagerPayload)
    }
}

extension UTType {
    static let orbitSpacePagerPayload = UTType(exportedAs: "com.orbit.browser.spacePagerPayload")
}
