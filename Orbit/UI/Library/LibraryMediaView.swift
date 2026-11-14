import SwiftUI

struct LibraryMediaView: View {
    @Environment(AppEnvironment.self) private var env
    var searchQuery: String

    private var playing: [(Tab, MediaState)] {
        // isMediaActive (not isPlaying) so a paused track stays listed.
        let all = env.mediaStates.compactMap { tabID, state -> (Tab, MediaState)? in
            guard state.isMediaActive, let tab = env.tab(tabID) else { return nil }
            return (tab, state)
        }
        guard !searchQuery.isEmpty else { return all }
        let query = searchQuery.lowercased()
        return all.filter { tab, state in
            (state.nowPlayingTitle ?? tab.displayTitle).lowercased().contains(query)
                || (state.nowPlayingArtist?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        if !playing.isEmpty {
            VStack(spacing: LibraryModeMetrics.rowSpacing) {
                ForEach(playing, id: \.0.id) { tab, state in
                    MediaRow(tab: tab, state: state)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MediaRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.libraryStyle) private var style
    var tab: Tab
    var state: MediaState

    private var router: LibraryRouter { env.libraryRouter }

    private var isSelected: Bool {
        router.selection == .media(tab.id)
    }

    private var subtitleText: String {
        state.nowPlayingArtist ?? (tab.url.host() ?? tab.url.absoluteString)
    }

    private var actions: [LibraryRowAction] {
        [
            LibraryRowAction(title: state.isMuted ? "Unmute" : "Mute", symbol: state.isMuted ? "speaker.slash" : "speaker.wave.1") {
                env.muteTab(tab.id, muted: !state.isMuted)
            },
            LibraryRowAction(title: "Go to Tab", symbol: "arrow.up.right.square") {
                env.activateTab(tab.id)
            },
        ]
    }

    var body: some View {
        LibraryRowCard(isSelected: isSelected, actions: actions) {
            Image(systemName: state.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.system(size: OrbitMetrics.iconChrome - 4))
                .foregroundStyle(style.foreground)
                .frame(width: LibraryModeMetrics.rowIconSize, height: LibraryModeMetrics.rowIconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OrbitSpacing.xxs) {
                Text(state.nowPlayingTitle ?? tab.displayTitle)
                    .font(OrbitFont.sidebarRowActive)
                    .foregroundStyle(style.foreground)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(OrbitFont.commandBarRowSubtitle)
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withOrbitAnimation(OrbitMotion.standard) { router.select(.media(tab.id)) }
        }
    }
}
