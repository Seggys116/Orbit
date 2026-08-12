import SwiftUI

@MainActor
enum TodayDividerClearAction {
    static func perform(spaceID: SpaceID, in env: AppEnvironment) {
        env.clearTodayTabs(in: spaceID)
    }
}

struct TodayDividerRow: View {
    @Environment(AppEnvironment.self) private var env

    var spaceID: SpaceID

    // nil inside the Manage Spaces panel, which sits on a system surface rather than a full-bleed theme and takes Color.primary instead.
    var theme: SpaceTheme?

    private var foreground: Color {
        theme?.readableForeground ?? Color.primary
    }

    private var hasTodayTabs: Bool {
        !env.todayTabs(in: spaceID).isEmpty
    }

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            Rectangle()
                .fill(foreground.opacity(OrbitMetrics.sidebarDividerOpacity))
                .frame(height: 1)

            if hasTodayTabs {
                clearControl
            }
        }
        // Fixed height regardless of whether clearControl is showing, so the Pinned/Today gap doesn't visibly jump when Today's last tab is cleared or reopened.
        .frame(height: OrbitMetrics.todayDividerRowHeight)
    }

    private var clearControl: some View {
        OrbitNSActionButton {
            TodayDividerClearAction.perform(spaceID: spaceID, in: env)
        } label: {
            HStack(spacing: OrbitMetrics.sidebarPinnedSlashSpacing) {
                Image(systemName: "arrow.down")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize - 3, weight: .semibold))
                Text("Clear")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize - 1, weight: .semibold))
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .foregroundStyle(foreground.opacity(OrbitMetrics.sidebarRowLabelOpacityInactive))
        .orbitTooltip("Clear Today tabs")
        .accessibilityLabel("Clear Today tabs")
    }
}
