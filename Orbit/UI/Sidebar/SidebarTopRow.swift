import SwiftUI

// Scales the glyph within its own frame rather than setting .font(size:) equal to .frame, which would fill the box edge-to-edge with no margin.
let sidebarToggleGlyphScale: CGFloat = 0.82

struct SidebarTopRow: View {
    @Environment(AppEnvironment.self) private var env
    var theme: SpaceTheme

    private var trafficLightsClusterWidth: CGFloat {
        OrbitMetrics.trafficLightDiameter * 3 + OrbitMetrics.trafficLightSpacing * 2
    }

    var body: some View {
        HStack(spacing: OrbitMetrics.trafficLightSpacing) {
            Color.clear
                .frame(width: trafficLightsClusterWidth, height: OrbitMetrics.trafficLightDiameter)

            toggleButton

            Spacer(minLength: 0)
        }
        .padding(.leading, OrbitMetrics.trafficLightLeadingInset)
        .padding(.trailing, OrbitMetrics.sidebarHorizontalPadding)
        .frame(height: OrbitMetrics.sidebarTopRowHeight)
    }

    private var toggleButton: some View {
        Button {
            env.perform(.toggleSidebar)
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: OrbitMetrics.sidebarTopRowIconSize * sidebarToggleGlyphScale, weight: .semibold))
                .frame(width: OrbitMetrics.sidebarTopRowIconSize, height: OrbitMetrics.sidebarTopRowIconSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.readableForeground)
        .orbitHoverHighlight(
            fill: theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity),
            cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius
        )
        .orbitTooltip("Show/Hide Sidebar — \u{2318}S")
    }
}
