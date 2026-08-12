import SwiftUI

struct SidebarMiniPlayerTray: View {
    @Environment(AppEnvironment.self) private var env
    var theme: SpaceTheme

    var alwaysExpanded: Bool = false

    var body: some View {
        let tabs = env.nowPlayingTabs
        if !tabs.isEmpty {
            VStack(spacing: OrbitMetrics.miniPlayerRowSpacing) {
                ForEach(tabs) { tab in
                    SidebarMiniPlayerView(tab: tab, theme: theme, alwaysExpanded: alwaysExpanded)
                }
            }
            .padding(.horizontal, OrbitMetrics.miniPlayerHorizontalInset)
            .padding(.bottom, OrbitMetrics.miniPlayerRowSpacing)
        }
    }
}

struct SidebarMiniPlayerView: View {
    @Environment(AppEnvironment.self) private var env
    var tab: Tab
    var theme: SpaceTheme
    var alwaysExpanded: Bool = false

    @State private var isHovering = false

    // WebContents is not @Observable, so reading contents.mediaState directly in body establishes no dependency; this mirror is what keeps the glyph live.
    private var mediaState: MediaState { env.mediaStates[tab.id] ?? .idle }

    private var isExpanded: Bool { alwaysExpanded || isHovering }

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitMetrics.miniPlayerRowSpacing) {
            if isExpanded {
                titleRow
            }
            controlRow
        }
        .padding(OrbitMetrics.miniPlayerContentPadding)
        .background(
            RoundedRectangle(cornerRadius: OrbitMetrics.miniPlayerCornerRadius)
                .fill(theme.readableForeground.opacity(OrbitMetrics.miniPlayerSurfaceOpacity))
        )
        .onHover { hovering in
            withAnimation(OrbitMotion.quick) { isHovering = hovering }
        }
    }

    // MARK: Title row

    private var titleRow: some View {
        HStack(spacing: OrbitMetrics.sidebarRowContentSpacing) {
            favicon
            Text(env.nowPlayingLabel(for: tab.id))
                .font(OrbitFont.sidebarRow)
                .foregroundStyle(theme.readableForeground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                env.dismissMiniPlayer(for: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: OrbitMetrics.sidebarUtilityGlyphSize, weight: .medium))
                    .frame(width: OrbitMetrics.sidebarCloseButtonSize, height: OrbitMetrics.sidebarCloseButtonSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.readableSecondaryForeground)
            .orbitTooltip("Hide Player")
        }
    }

    private var favicon: some View {
        Button {
            env.activateTab(tab.id)
        } label: {
            FaviconView(url: tab.faviconURL, host: tab.url.host() ?? tab.url.absoluteString)
                .frame(width: OrbitMetrics.iconFavicon, height: OrbitMetrics.iconFavicon)
                .clipShape(RoundedRectangle(cornerRadius: OrbitMetrics.sidebarFaviconCornerRadius))
        }
        .buttonStyle(.plain)
        .orbitTooltip("Go to Tab")
    }

    // MARK: Control row

    private var controlRow: some View {
        HStack(spacing: 0) {
            if isExpanded {
                if env.canDrivePictureInPicture(for: tab.id) {
                    control(
                        systemName: mediaState.isPictureInPictureActive ? "pip.exit" : "pip.enter",
                        help: mediaState.isPictureInPictureActive
                            ? "Exit Picture in Picture"
                            : "Picture in Picture"
                    ) {
                        env.toggleMiniPlayerPictureInPicture(for: tab.id)
                    }
                }
            } else {
                favicon
                    .frame(width: OrbitMetrics.miniPlayerControlSize, height: OrbitMetrics.miniPlayerControlSize)
            }

            Spacer(minLength: 0)

            control(systemName: "backward.fill", help: "Previous Track") {
                Task { await env.mediaTransport(.previousTrack, for: tab.id) }
            }

            Spacer(minLength: 0)

            control(
                systemName: mediaState.isPlaying ? "pause.fill" : "play.fill",
                help: mediaState.isPlaying ? "Pause" : "Play"
            ) {
                Task { await env.toggleMediaPlayback(for: tab.id) }
            }

            Spacer(minLength: 0)

            control(systemName: "forward.fill", help: "Next Track") {
                Task { await env.mediaTransport(.nextTrack, for: tab.id) }
            }

            Spacer(minLength: 0)

            control(
                systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: tab.isMuted ? "Unmute" : "Mute"
            ) {
                env.muteTab(tab.id, muted: !tab.isMuted)
            }
        }
    }

    private func control(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: OrbitMetrics.miniPlayerControlGlyphSize, weight: .medium))
                .foregroundStyle(theme.readableForeground)
                .frame(width: OrbitMetrics.miniPlayerControlSize, height: OrbitMetrics.miniPlayerControlSize)
        }
        .buttonStyle(.plain)
        .orbitTooltip(help)
    }
}
