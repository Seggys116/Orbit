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
            VStack(spacing: LibraryMetrics.rowSpacing) {
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
    @State private var router = LibraryRouter.shared
    var tab: Tab
    var state: MediaState

    private var isSelected: Bool {
        router.selection == .media(tab.id)
    }

    // Only worth spreading into columns once the list isn't squeezed down to make room for the
    // preview pane (see LibraryRootView.showsPreview).
    private var isWide: Bool { router.selection == nil }

    private var subtitleText: String {
        state.nowPlayingArtist ?? (tab.url.host() ?? tab.url.absoluteString)
    }

    var body: some View {
        LibraryRowCard(isSelected: isSelected) {
            HStack(spacing: 10) {
                Image(systemName: state.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(LibraryPalette.accent)
                    .frame(width: LibraryMetrics.rowIconSize, height: LibraryMetrics.rowIconSize)

                if isWide {
                    Text(state.nowPlayingTitle ?? tab.displayTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LibraryPalette.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LibraryColumnText(text: subtitleText, width: LibraryMetrics.rowMetaColumnWidth)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.nowPlayingTitle ?? tab.displayTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LibraryPalette.textPrimary)
                            .lineLimit(1)
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundStyle(LibraryPalette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                LibraryActionButton(symbol: state.isMuted ? "speaker.slash" : "speaker.wave.1", help: state.isMuted ? "Unmute" : "Mute") {
                    env.muteTab(tab.id, muted: !state.isMuted)
                }
                LibraryActionButton(symbol: "arrow.up.right.square", help: "Go to Tab") {
                    env.activateTab(tab.id)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { router.select(.media(tab.id)) }
    }
}
