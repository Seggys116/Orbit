import SwiftUI

/// The Library's narrow rail of icon-over-label tiles, one per section.
struct LibraryRailView: View {
    @Binding var selection: LibrarySection

    var body: some View {
        // Falls back to a scroller when the window is too short for every tile, so a tile is never clipped.
        ViewThatFits(in: .vertical) {
            tiles
            ScrollView(.vertical) { tiles }
                .scrollIndicators(.hidden)
        }
        .padding(LibraryModeMetrics.railPadding)
        .frame(width: LibraryModeMetrics.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tiles: some View {
        VStack(spacing: LibraryModeMetrics.railTileSpacing) {
            ForEach(LibrarySection.allCases) { section in
                LibraryRailTile(section: section, isSelected: section == selection) {
                    selection = section
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct LibraryRailTile: View {
    var section: LibrarySection
    var isSelected: Bool
    var action: () -> Void

    @Environment(\.libraryStyle) private var style
    @State private var isHovering = false

    private var fill: Color {
        if isSelected { return style.selectedFill }
        return isHovering ? style.hoverFill : .clear
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: OrbitSpacing.xs) {
                Image(systemName: section.symbolName)
                    .font(.system(size: LibraryModeMetrics.railTileIconSize - 4, weight: .medium))
                    .foregroundStyle(style.foreground.opacity(isSelected ? OrbitMetrics.sidebarRowLabelOpacityActive : OrbitMetrics.sidebarRowLabelOpacityInactive))
                    .frame(height: LibraryModeMetrics.railTileIconSize)
                Text(section.rawValue)
                    .font(.system(size: LibraryModeMetrics.railTileLabelFontSize, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? style.foreground : style.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, OrbitSpacing.xs)
            .padding(.vertical, LibraryModeMetrics.railTileVerticalPadding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .orbitAnimation(OrbitMotion.quick, value: isHovering)
        .orbitAnimation(OrbitMotion.quick, value: isSelected)
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
