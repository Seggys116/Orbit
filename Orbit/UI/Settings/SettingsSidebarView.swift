import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsPalette.textPrimary)
                .padding(.horizontal, SettingsMetrics.railHorizontalPadding)
                .padding(.top, SettingsMetrics.railTopPadding)
                .padding(.bottom, SettingsMetrics.railTitleBottomPadding)

            VStack(spacing: SettingsMetrics.railSectionSpacing) {
                ForEach(SettingsPane.allCases) { pane in
                    SettingsNavRow(
                        pane: pane,
                        isSelected: pane == selection
                    ) {
                        selection = pane
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: SettingsMetrics.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsPalette.sidebarBackground)
    }
}

private struct SettingsNavRow: View {
    var pane: SettingsPane
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: pane.symbolName)
                    .font(.system(size: SettingsMetrics.railIconSize, weight: .medium))
                    .foregroundStyle(isSelected ? SettingsPalette.textPrimary : SettingsPalette.textSecondary)
                    .frame(width: 18)
                Text(pane.title)
                    .font(.system(size: SettingsMetrics.railFontSize, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SettingsPalette.textPrimary : SettingsPalette.textSecondary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, SettingsMetrics.railHorizontalPadding - 8)
            .frame(height: SettingsMetrics.railRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? SettingsPalette.selectedFill : (isHovering ? SettingsPalette.hoverFill : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(OrbitMotion.quick, value: isHovering)
        .animation(OrbitMotion.quick, value: isSelected)
    }
}
