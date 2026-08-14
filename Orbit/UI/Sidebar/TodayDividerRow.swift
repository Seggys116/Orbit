import SwiftUI

@MainActor
enum TodayDividerClearAction {
    static func perform(spaceID: SpaceID, in env: AppEnvironment) {
        env.clearTodayTabs(in: spaceID)
    }
}

@MainActor
enum TodayDividerTidyAction {
    // Never both: a failed model call does not silently fall back to a host tidy, because the user could not tell the difference by looking.
    static func perform(spaceID: SpaceID, in env: AppEnvironment) {
        TidyTabsCoordinator.shared.dismissError()
        if TidyTabsCoordinator.shouldUseModel(todayTabCount: env.todayTabs(in: spaceID).count) {
            TidyTabsCoordinator.shared.tidy(spaceID: spaceID, env: env)
        } else {
            withAnimation(OrbitMotion.interactive) {
                _ = env.tidyTodayTabsByHost(in: spaceID)
            }
        }
    }
}

struct TodayDividerRow: View {
    @Environment(AppEnvironment.self) private var env

    var spaceID: SpaceID

    // nil inside the Manage Spaces panel, which sits on a system surface rather than a full-bleed theme and takes Color.primary instead.
    var theme: SpaceTheme?

    // True while the pointer is anywhere over the sidebar; Manage Spaces never reveals the broom.
    var revealsBroom: Bool = false

    private var foreground: Color {
        theme?.readableForeground ?? Color.primary
    }

    private var hasTodayTabs: Bool {
        !env.todayTabs(in: spaceID).isEmpty
    }

    private var hasTidyableTodayTabs: Bool {
        env.shouldShowTidyTabsBroom(in: spaceID)
    }

    private var tidyPhase: TidyTabsCoordinator.Phase {
        TidyTabsCoordinator.shared.phase(for: spaceID)
    }

    var body: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            Rectangle()
                .fill(foreground.opacity(OrbitMetrics.sidebarDividerOpacity))
                .frame(height: 1)

            if hasTidyableTodayTabs {
                tidyControl
            }

            if hasTodayTabs {
                clearControl
            }
        }
        // Fixed height regardless of whether clearControl is showing, so the Pinned/Today gap doesn't visibly jump when Today's last tab is cleared or reopened.
        .frame(height: OrbitMetrics.todayDividerRowHeight)
    }

    private var tidyControl: some View {
        OrbitNSActionButton {
            TodayDividerTidyAction.perform(spaceID: spaceID, in: env)
        } label: {
            Image(systemName: "wind")
                .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .semibold))
                .fixedSize()
                .contentShape(Rectangle())
        }
        .foregroundStyle(foreground.opacity(OrbitMetrics.sidebarRowLabelOpacityInactive))
        // Hidden rather than removed so Clear does not slide sideways as the pointer enters the sidebar.
        .opacity(revealsBroom ? 1 : 0)
        .allowsHitTesting(revealsBroom && tidyPhase != .tidying)
        .orbitTooltip(tidyTabsHelp)
        .accessibilityLabel("Tidy Tabs")
    }

    private var tidyTabsHelp: String {
        TidyTabsCoordinator.shouldUseModel(todayTabCount: env.todayTabs(in: spaceID).count)
            ? "Tidy Tabs — group Today tabs by subject, using your AI provider"
            : "Tidy Tabs — group Today tabs by site"
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
