import SwiftUI

struct LibrarySidebarView: View {
    @Binding var selection: LibrarySection
    var counts: [LibrarySection: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LibraryPalette.textPrimary)
                .padding(.horizontal, LibraryMetrics.navHorizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, 12)

            VStack(spacing: LibraryMetrics.navSectionSpacing) {
                ForEach(LibrarySection.allCases) { section in
                    LibraryNavRow(
                        section: section,
                        isSelected: section == selection,
                        count: counts[section] ?? 0
                    ) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: LibraryMetrics.navWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LibraryPalette.sidebarBackground)
    }
}

private struct LibraryNavRow: View {
    var section: LibrarySection
    var isSelected: Bool
    var count: Int
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbolName)
                    .font(.system(size: LibraryMetrics.navIconSize, weight: .medium))
                    .foregroundStyle(isSelected ? LibraryPalette.textPrimary : LibraryPalette.textSecondary)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: LibraryMetrics.navFontSize, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? LibraryPalette.textPrimary : LibraryPalette.textSecondary)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LibraryPalette.textTertiary)
                }
            }
            .padding(.horizontal, LibraryMetrics.navHorizontalPadding - 8)
            .frame(height: LibraryMetrics.navRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? LibraryPalette.selectedFill : (isHovering ? LibraryPalette.hoverFill : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(OrbitMotion.quick, value: isHovering)
        .animation(OrbitMotion.quick, value: isSelected)
    }
}
