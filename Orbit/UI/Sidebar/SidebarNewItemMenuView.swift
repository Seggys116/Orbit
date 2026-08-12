//  SidebarNewItemMenu.swift owns the action logic; this file is presentation only.

import SwiftUI

struct SidebarNewItemMenuSection: Identifiable {
    var id: String { title }
    var title: String
    var options: [SidebarNewItemOption]
}

extension SidebarNewItemOption {

    var symbolName: String {
        switch self {
        case .newTab: return "plus"
        case .newSplitView: return "square.split.2x1"
        case .newFolder: return "folder.badge.plus"
        case .newSpace: return "plus.square.on.square"
        case .newNote: return "note.text"
        case .newEasel: return "scribble.variable"
        case .newBoost: return "bolt.circle"
        }
    }

    // The same ShortcutCommandID the menu bar and Shortcuts settings bind —
    // reading a live binding through it means a user-remapped shortcut shows
    // up here automatically, never a hardcoded string that can drift from it.
    var shortcutCommandID: ShortcutCommandID {
        switch self {
        case .newTab: return .newTabCommandBar
        case .newSplitView: return .addSplit
        case .newFolder: return .newFolder
        case .newSpace: return .newSpace
        case .newNote: return .newNote
        case .newEasel: return .newEasel
        case .newBoost: return .newBoost
        }
    }

    // nil for a command that ships unbound (e.g. New Folder, New Space, New Boost by default) — the row shows no hint, like the real menu bar for an unbound command.
    func shortcutDisplayString(registry: ShortcutRegistry = .shared) -> String? {
        registry.binding(for: shortcutCommandID)?.displayString
    }

    // Mirrors MainMenuBuilder's gating for New Folder (hasActiveSpace) and
    // New Boost (activeHost != nil); the other five commands are never gated.
    func isAvailable(in env: AppEnvironment) -> Bool {
        switch self {
        case .newFolder:
            return env.activeSpace != nil
        case .newBoost:
            return SidebarNewItemOption.activeHost(in: env) != nil
        case .newTab, .newSplitView, .newSpace, .newNote, .newEasel:
            return true
        }
    }

    func unavailableReason(in env: AppEnvironment) -> String? {
        guard !isAvailable(in: env) else { return nil }
        switch self {
        case .newFolder: return "No Space is open to add a folder to."
        case .newBoost: return "No page is open to attach a Boost to."
        case .newTab, .newSplitView, .newSpace, .newNote, .newEasel: return nil
        }
    }

    static func activeHost(in env: AppEnvironment) -> String? {
        guard let host = env.activeTab?.url.host(), !host.isEmpty else { return nil }
        return host
    }

    // Grouped for presentation only — order and membership are asserted
    // against SidebarNewItemOption.allCases in SidebarNewItemMenuViewTests so
    // this grouping can never silently drop or duplicate a real option.
    static let menuSections: [SidebarNewItemMenuSection] = [
        SidebarNewItemMenuSection(title: "Browse", options: [.newTab, .newSplitView]),
        SidebarNewItemMenuSection(title: "Organize", options: [.newFolder, .newSpace]),
        SidebarNewItemMenuSection(title: "Create", options: [.newNote, .newEasel, .newBoost]),
    ]

    // What SidebarBottomBar's "+" button presents through OrbitContextMenuView.
    // menuSections still decides the grouping, but a divider alone separates
    // the groups -- no uppercase section label.
    static func contextMenuEntries(in env: AppEnvironment, registry: ShortcutRegistry = .shared) -> [OrbitContextMenuEntry] {
        menuSections.enumerated().flatMap { index, section -> [OrbitContextMenuEntry] in
            let items: [OrbitContextMenuEntry] = section.options.map { option in
                .item(OrbitContextMenuItem(
                    title: option.title,
                    systemImage: option.symbolName,
                    shortcut: option.shortcutDisplayString(registry: registry),
                    isEnabled: option.isAvailable(in: env),
                    tooltip: option.unavailableReason(in: env),
                    action: { option.perform(in: env) }
                ))
            }
            return index == 0 ? items : [.divider()] + items
        }
    }
}

// MARK: - Pure row styling (kept free of @State so it is directly unit-testable)

enum SidebarNewItemMenuStyle {
    static func rowForeground(isAvailable: Bool, colorScheme: ColorScheme) -> Color {
        let base = OrbitControlColor.primaryForeground(for: colorScheme)
        return isAvailable ? base : base.opacity(OrbitControlMetrics.buttonDisabledOpacity)
    }

    static func shortcutForeground(colorScheme: ColorScheme) -> Color {
        OrbitControlColor.secondaryForeground(for: colorScheme)
    }

    static func sectionHeaderForeground(colorScheme: ColorScheme) -> Color {
        OrbitControlColor.secondaryForeground(for: colorScheme)
    }

    // A disabled row must never paint a hover fill, however the pointer got there.
    static func rowBackground(isHovering: Bool, isAvailable: Bool, colorScheme: ColorScheme) -> Color {
        guard isHovering, isAvailable else { return .clear }
        return OrbitControlColor.hoverFill(for: colorScheme)
    }
}

enum SidebarNewItemMenuMetrics {
    static let width: CGFloat = 232
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 10
    static let rowCornerRadius: CGFloat = 6
    static let rowHorizontalPadding: CGFloat = 8
    static let iconWidth: CGFloat = 18
    static let iconFontSize: CGFloat = 13
    static let sectionTopPadding: CGFloat = 6
    static let sectionBottomPadding: CGFloat = 2
    static let containerPadding: CGFloat = 6
    static let dividerVerticalPadding: CGFloat = 4
}

// MARK: - Content view

struct SidebarNewItemMenuView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @State private var registry = ShortcutRegistry.shared

    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SidebarNewItemOption.menuSections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Divider().padding(.vertical, SidebarNewItemMenuMetrics.dividerVerticalPadding)
                }
                sectionView(section)
            }
        }
        .padding(SidebarNewItemMenuMetrics.containerPadding)
        .frame(width: SidebarNewItemMenuMetrics.width)
    }

    private func sectionView(_ section: SidebarNewItemMenuSection) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(section.title.uppercased())
                .font(.system(size: OrbitControlMetrics.sectionHeaderFontSize, weight: .semibold))
                .foregroundStyle(SidebarNewItemMenuStyle.sectionHeaderForeground(colorScheme: colorScheme))
                .padding(.horizontal, SidebarNewItemMenuMetrics.rowHorizontalPadding)
                .padding(.top, SidebarNewItemMenuMetrics.sectionTopPadding)
                .padding(.bottom, SidebarNewItemMenuMetrics.sectionBottomPadding)
            ForEach(section.options, id: \.self) { option in
                SidebarNewItemMenuRow(
                    option: option,
                    isAvailable: option.isAvailable(in: env),
                    unavailableReason: option.unavailableReason(in: env),
                    shortcutDisplayString: option.shortcutDisplayString(registry: registry)
                ) {
                    option.perform(in: env)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - One row

struct SidebarNewItemMenuRow: View {
    var option: SidebarNewItemOption
    var isAvailable: Bool
    var unavailableReason: String?
    var shortcutDisplayString: String?
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarNewItemMenuMetrics.rowSpacing) {
                Image(systemName: option.symbolName)
                    .font(.system(size: SidebarNewItemMenuMetrics.iconFontSize, weight: .medium))
                    .frame(width: SidebarNewItemMenuMetrics.iconWidth)
                Text(option.title)
                    .font(.system(size: OrbitControlMetrics.buttonFontSize, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcutDisplayString {
                    Text(shortcutDisplayString)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(SidebarNewItemMenuStyle.shortcutForeground(colorScheme: colorScheme))
                }
            }
            .foregroundStyle(SidebarNewItemMenuStyle.rowForeground(isAvailable: isAvailable, colorScheme: colorScheme))
            .padding(.horizontal, SidebarNewItemMenuMetrics.rowHorizontalPadding)
            .frame(height: SidebarNewItemMenuMetrics.rowHeight)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: SidebarNewItemMenuMetrics.rowCornerRadius, style: .continuous)
                    .fill(SidebarNewItemMenuStyle.rowBackground(isHovering: isHovering, isAvailable: isAvailable, colorScheme: colorScheme))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .onHover { isHovering = $0 }
        .orbitTooltip(unavailableReason ?? "")
        .accessibilityLabel(isAvailable ? option.title : "\(option.title): unavailable — \(unavailableReason ?? "")")
    }
}
