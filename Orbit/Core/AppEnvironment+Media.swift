import Foundation

/// The rule for which media tabs get a mini player row, kept free of AppEnvironment so it can be tested with plain values.
///
/// A row is for media that is playing, or that the user paused through Orbit's own controls (the mini player's
/// button or the picture-in-picture window) so the row's play button can resume it. A pause made on the page
/// itself, and media that is idle or has ended, get no row.
enum MiniPlayerVisibility {

    /// Whether a tab with this media state belongs in the tray, before the active-tab, dismissal and live-page checks.
    static func qualifiesForRow(_ state: MediaState, pausedByOrbit: Bool) -> Bool {
        guard state.isMediaActive else { return false }
        return state.isPlaying || pausedByOrbit
    }

    /// The "paused by Orbit" flag for a tab after the engine reports `current`.
    ///
    /// `wasPausedByOrbit` is the flag as it stood before the report: the mini player sets it just before it sends a
    /// pause, so the playing-to-paused report that follows finds it already set. A report that is still "playing"
    /// keeps it, because a report that was in flight before the pause landed must not cancel it; only a genuine
    /// paused-to-playing transition (a resume from anywhere) clears it. A pause with no flag is attributed to
    /// Orbit only when it happened while the tab was floating in picture-in-picture, whose window controls are
    /// Orbit's; anything else was the page's own pause.
    static func pausedByOrbit(
        previous: MediaState?,
        current: MediaState,
        wasPausedByOrbit: Bool
    ) -> Bool {
        guard current.isMediaActive else { return false }
        if current.isPlaying {
            return previous?.isPlaying == true && wasPausedByOrbit
        }
        if wasPausedByOrbit { return true }
        guard previous?.isPlaying == true else { return false }
        return previous?.isPictureInPictureActive == true || current.isPictureInPictureActive
    }
}

extension AppEnvironment {

    // MARK: - Which tabs are in the tray

    var nowPlayingTabs: [Tab] {
        mediaStates
            .compactMap { tabID, mediaState -> Tab? in
                guard MiniPlayerVisibility.qualifiesForRow(
                    mediaState,
                    pausedByOrbit: orbitPausedMediaTabIDs.contains(tabID)
                ) else { return nil }
                guard tabID != activeTabID else { return nil }
                // Media state belongs to a live page; an archived or closed tab has none to show.
                guard webContents[tabID] != nil else { return nil }
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
        // Set before the command goes out so the playing-to-paused report it causes is already attributed to Orbit.
        let markedPausedByOrbit = action == .pause && mediaStates[tabID]?.isPlaying == true
        if markedPausedByOrbit { orbitPausedMediaTabIDs.insert(tabID) }
        let result = try? await contents.evaluateJavaScript(MediaTransportScript.invocation(for: action))
        let handled = (result as? Bool) ?? false
        // A pause nothing acted on leaves the media playing; a later pause on the page must not inherit the mark.
        if markedPausedByOrbit, !handled, mediaStates[tabID]?.isPlaying == true {
            orbitPausedMediaTabIDs.remove(tabID)
        }
        return handled
    }

    @discardableResult
    func toggleMediaPlayback(for tabID: TabID) async -> Bool {
        let isPlaying = mediaStates[tabID]?.isPlaying ?? false
        return await mediaTransport(isPlaying ? .pause : .play, for: tabID)
    }

    // MARK: - Picture-in-picture

    // Gated on mediaStates[tabID].isPictureInPictureAvailable, not hasVideo: the mini-player
    // shows for any active Media Session, including audio-only ones (Spotify, podcasts) that
    // have no video to float, and hasVideo itself only scans the top document (see
    // MediaSessionObserverScript's allFrames: false) so it misses an iframe-hosted player —
    // gating on it would hide the button for a tab PiP would actually work on. This flag is
    // the engine's own PictureInPictureCandidate() answer, forwarded through
    // picture_in_picture_available_changed, which is exactly what togglePictureInPicture()
    // acts on: the button and the toggle can never disagree.
    func canDrivePictureInPicture(for tabID: TabID) -> Bool {
        guard webContents[tabID] != nil else { return false }
        guard mediaStates[tabID]?.isPictureInPictureAvailable == true else { return false }
        return engineCapabilities.contains(.pictureInPicture)
    }

    @discardableResult
    func toggleMiniPlayerPictureInPicture(for tabID: TabID) -> Bool {
        guard canDrivePictureInPicture(for: tabID), let contents = webContents[tabID] else { return false }
        contents.togglePictureInPicture()
        return true
    }
}
