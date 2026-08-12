//  Superseded by Orbit/UI/Spaces/SpaceSwitcherPagerView.swift; kept only as a minimal fallback, not currently instantiated anywhere.

import SwiftUI

struct SpacePagerView: View {
    @Environment(AppEnvironment.self) private var env
    var theme: SpaceTheme

    private var hasSomethingToSwitchBetween: Bool { env.spaces.count > 1 }

    var body: some View {
        pager
    }

    private var pager: some View {
        HStack(spacing: 6) {
            ForEach(env.spaces) { space in
                Button {
                    withAnimation(OrbitMotion.dramatic) { env.selectSpace(space.id) }
                } label: {
                    iconView(for: space)
                        .frame(width: OrbitMetrics.sidebarBottomBarIconSize, height: OrbitMetrics.sidebarBottomBarIconSize)
                }
                .buttonStyle(.plain)
                .orbitHoverHighlight(
                    fill: theme.readableForeground.opacity(OrbitMetrics.sidebarActiveRowOpacity),
                    cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius
                )
                .orbitTooltip(space.name)
            }
        }
    }

    private func iconView(for space: Space) -> some View {
        let isActive = space.id == env.activeSpace?.id
        return Group {
            if space.iconIsEmoji {
                Text(space.icon).font(.system(size: OrbitMetrics.iconFavicon))
                    .opacity(isActive ? 1 : 0.55)
            } else {
                Image(systemName: space.icon)
                    .font(.system(size: OrbitMetrics.iconFavicon, weight: .medium))
                    .foregroundStyle(theme.readableForeground.opacity(isActive ? 1 : 0.55))
            }
        }
    }
}
