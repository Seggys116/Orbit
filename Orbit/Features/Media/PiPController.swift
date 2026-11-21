import AppKit
import Foundation
import OSLog

// Polls activeTabID/mediaStates rather than a focus-change hook, which isn't exposed to this feature.
@MainActor
final class PiPController {
    static let shared = PiPController()
    private init() {}

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "PictureInPicture")

    private var timer: Timer?
    private var lastActiveTabID: TabID?
    // Set only from an observed MediaState.isPictureInPictureActive, never from the act of asking.
    private(set) var pipTabID: TabID?

    private struct PendingRequest {
        let tabID: TabID
        var ticksRemaining: Int
        /// The user came back before the page confirmed. The request was already sent, so the window that opens late has to be closed again, not forgotten.
        var cancelled = false
        /// The tab was off screen at some point since the request, so being on screen again means the user returned to it.
        var leftScreen = false
    }

    private var pendingRequest: PendingRequest?

    /// Whether the floating tab has been off screen since it started floating. A window the user opened while looking at the tab is left alone until they leave and come back.
    private var floatingLeftScreen = false

    /// Tabs whose window was asked to close and has not yet reported closed.
    private var closingWindows: Set<TabID> = []

    // A floating tab whose window closed while the video kept playing: possibly the window's "return to tab" button, possibly a close that has not paused the video yet.
    private var returnCandidate: TabID?

    /// Brings Orbit forward after the user returns to a tab from the floating window. Replaced in tests.
    var presentApp: (AppEnvironment) -> Void = { env in
        NSApp.activate(ignoringOtherApps: true)
        OrbitWindowController.window(for: env)?.makeKeyAndOrderFront(nil)
    }

    static let confirmationTicks = 6

    static let tickInterval: TimeInterval = 0.5

    private var isStarted = false
    private var isObservingIdle = false
    private var startGeneration = 0

    func start(env: AppEnvironment) {
        guard !isStarted else { return }
        isStarted = true
        lastActiveTabID = env.activeTabID
        notePlaybackCadence(env: env)
    }

    /// Nothing playing, floating or pending: focus cannot open or close picture-in-picture, so no timer runs.
    /// A pending request needs `tickInterval` because confirmation is counted in those ticks.
    private func isBusy(env: AppEnvironment) -> Bool {
        pendingRequest != nil
            || pipTabID != nil
            || returnCandidate != nil
            || env.mediaStates.values.contains { $0.isPlaying || $0.isPictureInPictureActive }
    }

    private func armTimer(env: AppEnvironment) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(env: env) }
        }
    }

    /// While idle, a change to the media states or the active tab wakes the controller instead of a timer polling for it.
    private func observeWhileIdle(env: AppEnvironment) {
        guard !isObservingIdle else { return }
        isObservingIdle = true
        let generation = startGeneration
        withObservationTracking {
            _ = env.mediaStates
            _ = env.activeTabID
        } onChange: { [weak self] in
            Task { @MainActor in
                // A registration left over from before stop() must not tick or clear the new one's flag.
                guard let self, self.startGeneration == generation else { return }
                self.isObservingIdle = false
                guard self.isStarted else { return }
                self.tick(env: env)
            }
        }
    }

    private func notePlaybackCadence(env: AppEnvironment) {
        guard isStarted else { return }
        if isBusy(env: env) {
            armTimer(env: env)
        } else {
            timer?.invalidate()
            timer = nil
            observeWhileIdle(env: env)
        }
    }

    func stop() {
        isStarted = false
        isObservingIdle = false
        startGeneration += 1
        timer?.invalidate()
        timer = nil
    }

    func tick(env: AppEnvironment) {
        settlePendingRequest(env: env)
        adoptFloatingTabNobodyAskedFor(env: env)
        settleFloatingWindowClosed(env: env)
        dismissIfUserReturned(env: env)

        let currentActive = env.activeTabID
        defer {
            lastActiveTabID = currentActive
            notePlaybackCadence(env: env)
        }

        guard currentActive != lastActiveTabID else { return }

        // A tab that is still on screen has nothing to float away from: moving focus between the panes of a Split View hides neither.
        if let losingFocus = lastActiveTabID, losingFocus != pipTabID,
           !Self.isOnScreen(losingFocus, env: env),
           pendingRequest?.tabID != losingFocus,
           let state = env.mediaStates[losingFocus], state.isPictureInPictureAvailable, state.isPlaying,
           // Asking a page that already floats is how a window gets closed: the request is a toggle.
           !state.isPictureInPictureActive,
           env.webContents[losingFocus] != nil {
            requestPiP(for: losingFocus, env: env)
        }
    }

    /// A page can float without Orbit asking: from its own video controls, the context menu or the mini player. Its window has the same Return button, so it is tracked from the moment it is seen floating, or Return would leave the person on whatever tab they were looking at.
    private func adoptFloatingTabNobodyAskedFor(env: AppEnvironment) {
        // A window this controller asked to close still reports as open for a moment; it is not one nobody asked for.
        closingWindows = closingWindows.filter { env.mediaStates[$0]?.isPictureInPictureActive == true }
        guard pipTabID == nil, pendingRequest == nil else { return }
        guard let floating = env.mediaStates.first(where: {
            $0.value.isPictureInPictureActive && env.webContents[$0.key] != nil && !closingWindows.contains($0.key)
        })?.key else { return }
        pipTabID = floating
        floatingLeftScreen = !Self.isOnScreen(floating, env: env)
    }

    /// Checked every tick, not only when the active tab changes: a request confirmed after the user already came back changes nothing about the active tab, and its window would otherwise stay open over the page it came from.
    private func dismissIfUserReturned(env: AppEnvironment) {
        if var pending = pendingRequest, !pending.cancelled {
            if Self.isOnScreen(pending.tabID, env: env) {
                if pending.leftScreen { dismissPiP(for: pending.tabID, env: env) }
            } else if !pending.leftScreen {
                pending.leftScreen = true
                pendingRequest = pending
            }
        }
        if let floating = pipTabID {
            if Self.isOnScreen(floating, env: env) {
                if floatingLeftScreen { dismissPiP(for: floating, env: env) }
            } else {
                floatingLeftScreen = true
            }
        }
    }

    /// Whether the tab's page is showing in the window: it is the active tab or a pane of the active Split View.
    static func isOnScreen(_ tabID: TabID, env: AppEnvironment) -> Bool {
        guard let active = env.activeTabID else { return false }
        if tabID == active { return true }
        return env.splitGroup(for: active)?.tabIDs.contains(tabID) == true
    }

    /// The floating window can be closed from its own controls, which Orbit never asked for. Closing it with the
    /// video paused is a dismissal. Closing it with the video still playing is the "return to tab" button, so
    /// the tab comes back to the front. The playing state is read a second time one tick later because a close
    /// pauses the video a moment after the window goes.
    private func settleFloatingWindowClosed(env: AppEnvironment) {
        guard let floating = pipTabID, pendingRequest?.tabID != floating else {
            returnCandidate = nil
            return
        }
        guard env.tab(floating) != nil, let state = env.mediaStates[floating] else {
            pipTabID = nil
            returnCandidate = nil
            return
        }
        guard !state.isPictureInPictureActive else {
            returnCandidate = nil
            return
        }
        guard state.isPlaying else {
            pipTabID = nil
            returnCandidate = nil
            return
        }
        guard returnCandidate == floating else {
            returnCandidate = floating
            return
        }
        returnCandidate = nil
        pipTabID = nil
        env.activateTab(floating)
        presentApp(env)
    }

    private func settlePendingRequest(env: AppEnvironment) {
        guard let pending = pendingRequest else { return }

        // A closed tab has no page left to answer, and nothing floats for it.
        guard env.webContents[pending.tabID] != nil else {
            pendingRequest = nil
            return
        }

        if env.mediaStates[pending.tabID]?.isPictureInPictureActive == true {
            pendingRequest = nil
            pipTabID = pending.tabID
            floatingLeftScreen = pending.leftScreen || !Self.isOnScreen(pending.tabID, env: env)
            if pending.cancelled { dismissPiP(for: pending.tabID, env: env) }
            return
        }

        let remaining = pending.ticksRemaining - 1
        if remaining <= 0 {
            pendingRequest = nil
            Self.logger.error(
                """
                Picture-in-Picture was requested for a tab and never became active. \
                The page rejected the request, or the engine never granted the user \
                activation it needs. Nothing is now recorded as floating.
                """
            )
        } else {
            var updated = pending
            updated.ticksRemaining = remaining
            pendingRequest = updated
        }
    }

    // MARK: - Hook bodies

    // Returns whether the request was dispatched, not whether it succeeded: togglePictureInPicture()
    // is Void and fire-and-forget; success is recorded separately once the page reports it.
    @discardableResult
    func requestPiP(for tabID: TabID, env: AppEnvironment) -> Bool {
        guard let contents = env.webContents[tabID] else { return false }
        guard env.engineCapabilities.contains(.pictureInPicture) else { return false }
        contents.togglePictureInPicture()
        pendingRequest = PendingRequest(
            tabID: tabID,
            ticksRemaining: Self.confirmationTicks,
            leftScreen: !Self.isOnScreen(tabID, env: env)
        )
        return true
    }

    func dismissPiP(for tabID: TabID, env: AppEnvironment) {
        if returnCandidate == tabID { returnCandidate = nil }
        if let contents = env.webContents[tabID], contents.mediaState.isPictureInPictureActive {
            // The toggle is an exit only while the window is open; sent early it would open one.
            closingWindows.insert(tabID)
            contents.togglePictureInPicture()
            if pendingRequest?.tabID == tabID { pendingRequest = nil }
        } else if var pending = pendingRequest, pending.tabID == tabID {
            // The request is already on its way to the page; forgetting it would leave its window open with nothing tracking it.
            pending.cancelled = true
            pendingRequest = pending
        }
        if pipTabID == tabID {
            pipTabID = nil
            floatingLeftScreen = false
        }
    }

    #if DEBUG
    func _test_reset() {
        stop()
        lastActiveTabID = nil
        pipTabID = nil
        pendingRequest = nil
        returnCandidate = nil
        closingWindows = []
        floatingLeftScreen = false
        presentApp = { _ in }
    }

    func _test_hasPendingRequest(for tabID: TabID) -> Bool {
        pendingRequest?.tabID == tabID
    }

    func _test_seedLastActiveTab(_ tabID: TabID?) {
        lastActiveTabID = tabID
    }
    #endif
}
