import SwiftUI

struct OrbitContextMenuView: View {
    static let coordinateSpace = "OrbitContextMenu"

    var entries: [OrbitContextMenuEntry]
    var onSelect: () -> Void
    /// Non-nil only for a menu that deliberately points at its own trigger,
    /// e.g. the sidebar "+" button. The right-click menu never has one.
    var arrow: OrbitMenuArrow?
    var selection: OrbitMenuSelectionModel?
    /// Fires whenever a row becomes the active one, with its frame in this
    /// menu's own coordinate space, so the controller can open or close a
    /// submenu panel beside it.
    var onRowActivate: ((OrbitContextMenuItem, CGRect) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.orbitSpaceTheme) private var environmentTheme
    @State private var fallbackSelection = OrbitMenuSelectionModel()

    private var activeSelection: OrbitMenuSelectionModel { selection ?? fallbackSelection }

    private var chrome: SpaceThemeChrome? {
        (environmentTheme ?? OrbitMenuThemeSource.shared.theme).map {
            SpaceThemeChrome(theme: $0, colorScheme: colorScheme)
        }
    }

    private var surface: OrbitMenuSurfaceShape {
        OrbitMenuSurfaceShape(cornerRadius: OrbitMetrics.contextMenuCornerRadius, arrow: arrow)
    }

    var body: some View {
        let chrome = self.chrome
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                row(for: entry, chrome: chrome)
            }
        }
        .padding(.vertical, OrbitMetrics.contextMenuVerticalPadding)
        .frame(width: OrbitMetrics.contextMenuWidth)
        .padding(.top, arrow?.edge == .top ? OrbitMetrics.contextMenuArrowHeight : 0)
        .padding(.bottom, arrow?.edge == .bottom ? OrbitMetrics.contextMenuArrowHeight : 0)
        .background(surface.fill(chrome?.surface ?? OrbitColor.menuSurface(for: colorScheme)))
        .overlay(
            surface.strokeBorder(
                chrome?.border ?? OrbitControlColor.border(for: colorScheme),
                lineWidth: OrbitAcrylic.panelEdgeHighlightWidth
            )
        )
        .contentShape(surface)
        .coordinateSpace(name: Self.coordinateSpace)
        .onAppear { activeSelection.setEntries(entries) }
        .onChange(of: entries.map(\.id)) { _, _ in activeSelection.setEntries(entries) }
        .orbitThemeAnimation(value: chrome)
    }

    // AnyView, not `some View`: this recurses into itself for `.section`'s
    // nested entries, and an opaque return type cannot be defined in terms
    // of itself.
    private func row(for entry: OrbitContextMenuEntry, chrome: SpaceThemeChrome?) -> AnyView {
        switch entry {
        case .item(let item):
            return AnyView(
                OrbitContextMenuRow(
                    item: item,
                    selection: activeSelection,
                    chrome: chrome,
                    onRowActivate: onRowActivate,
                    onSelect: onSelect
                )
            )
        case .divider:
            return AnyView(
                Rectangle()
                    .fill(chrome?.divider ?? OrbitColor.menuDivider(for: colorScheme))
                    .frame(height: OrbitMetrics.contextMenuDividerThickness)
                    .padding(.vertical, OrbitMetrics.contextMenuDividerVerticalPadding)
                    .padding(.horizontal, OrbitMetrics.contextMenuRowHorizontalInset + OrbitMetrics.contextMenuRowHorizontalPadding)
            )
        case .section(_, let title, let entries):
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.uppercased())
                        .font(.system(size: OrbitMetrics.contextMenuSectionHeaderFontSize, weight: .semibold))
                        .foregroundStyle(chrome?.secondaryForeground ?? OrbitControlColor.secondaryForeground(for: colorScheme))
                        .padding(.horizontal, OrbitMetrics.contextMenuRowHorizontalInset + OrbitMetrics.contextMenuRowHorizontalPadding)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(entries) { child in row(for: child, chrome: chrome) }
                }
            )
        }
    }
}

private struct OrbitContextMenuRow: View {
    var item: OrbitContextMenuItem
    var selection: OrbitMenuSelectionModel
    var chrome: SpaceThemeChrome?
    var onRowActivate: ((OrbitContextMenuItem, CGRect) -> Void)?
    var onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var frameInMenu: CGRect = .zero

    private var isActive: Bool { selection.selectedItemID == item.id }

    var body: some View {
        Button {
            guard item.isEnabled, !item.hasSubmenu else { return }
            item.action?()
            onSelect()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .orbitTooltip(item.tooltip ?? "")
        .onHover { hovering in
            guard item.isEnabled else { return }
            if hovering {
                selection.selectedItemID = item.id
            } else if selection.selectedItemID == item.id {
                selection.selectedItemID = nil
            }
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            onRowActivate?(item, frameInMenu)
        }
        .accessibilityLabel(item.isEnabled ? item.title : "\(item.title): unavailable")
    }

    private var content: some View {
        HStack(spacing: OrbitMetrics.contextMenuIconToTitleGap) {
            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: OrbitMetrics.contextMenuIconSize, weight: .medium))
                    .frame(width: OrbitMetrics.contextMenuIconSize, alignment: .center)
            }
            Text(item.title)
                .font(.system(size: OrbitMetrics.contextMenuFontSize))
                .lineLimit(1)
            Spacer(minLength: 8)
            if item.isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: OrbitMetrics.contextMenuIconSize, weight: .semibold))
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: OrbitMetrics.contextMenuShortcutFontSize))
                    .foregroundStyle(secondaryColor)
            }
            if item.hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: OrbitMetrics.contextMenuSubmenuChevronSize, weight: .semibold))
                    .foregroundStyle(secondaryColor)
            }
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, OrbitMetrics.contextMenuRowHorizontalPadding)
        .frame(height: OrbitMetrics.contextMenuRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.contextMenuRowCornerRadius, style: .continuous)
                .fill(rowFill)
        )
        .padding(.horizontal, OrbitMetrics.contextMenuRowHorizontalInset)
        .opacity(item.isEnabled ? 1 : OrbitMetrics.contextMenuDisabledOpacity)
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(OrbitContextMenuView.coordinateSpace))
                Color.clear
                    .onAppear { frameInMenu = frame }
                    .onChange(of: frame) { _, new in frameInMenu = new }
            }
        }
    }

    private var foregroundColor: Color {
        item.isDestructive ? .red : (chrome?.foreground ?? OrbitControlColor.primaryForeground(for: colorScheme))
    }

    private var secondaryColor: Color {
        chrome?.secondaryForeground ?? OrbitControlColor.secondaryForeground(for: colorScheme)
    }

    private var rowFill: Color {
        guard isActive else { return .clear }
        if let chrome, !item.isDestructive { return chrome.hoverFill }
        let opacity = colorScheme == .dark ? OrbitMetrics.contextMenuHoverOpacityDark : OrbitMetrics.contextMenuHoverOpacityLight
        if item.isDestructive { return .red.opacity(opacity * 0.7) }
        return OrbitColor.menuHighlight(for: colorScheme).opacity(opacity)
    }
}
