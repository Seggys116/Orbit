import Foundation

extension AppEnvironment {

    // MARK: - Which tabs are in the tray

    var nowPlayingTabs: [Tab] {
        mediaStates
            .compactMap { tabID, mediaState -> Tab? in
                guard mediaState.isMediaActive else { return nil }
                guard tabID != activeTabID else { return nil }
                guard !dismissedMiniPlayerTabIDs.contains(tabID) else { return nil }
                return tab(tabID)
            }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    func nowPlayingLabel(for tabID: TabID) -> String {
        let state = mediaStates[tabID]
        let fallback = tab(tabID)?.displayTitle ?? ""
        guard let title = state?.nowPlayingTitle, !title.isEmpty else { return fallback }
        guard let artist = state?.nowPlayingArtist, !artist.isEmpty else { return title }
        return "\(title) • \(artist)"
    }

    // MARK: - Dismissal

    // Does not stop playback — only hides the card until the media stops.
    func dismissMiniPlayer(for tabID: TabID) {
        dismissedMiniPlayerTabIDs.insert(tabID)
    }

    // MARK: - Transport

    @discardableResult
    func mediaTransport(_ action: MediaTransportScript.Action, for tabID: TabID) async -> Bool {
        guard let contents = webContents[tabID] else { return false }
        let result = try? await contents.evaluateJavaScript(MediaTransportScript.invocation(for: action))
        return (result as? Bool) ?? false
    }

    @discardableResult
    func toggleMediaPlayback(for tabID: TabID) async -> Bool {
        let isPlaying = mediaStates[tabID]?.isPlaying ?? false
        return await mediaTransport(isPlaying ? .pause : .play, for: tabID)
    }

    // MARK: - Picture-in-picture

    func canDrivePictureInPicture(for tabID: TabID) -> Bool {
        guard webContents[tabID] != nil else { return false }
        return engineCapabilities.contains(.pictureInPicture)
    }

    @discardableResult
    func toggleMiniPlayerPictureInPicture(for tabID: TabID) -> Bool {
        guard canDrivePictureInPicture(for: tabID), let contents = webContents[tabID] else { return false }
        contents.togglePictureInPicture()
        return true
    }
}
