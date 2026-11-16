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

    private var pendingRequest: (tabID: TabID, ticksRemaining: Int)?

    // A floating tab whose window closed while the video kept playing: possibly the window's "return to tab" button, possibly a close that has not paused the video yet.
    private var returnCandidate: TabID?

    /// Brings Orbit forward after the user returns to a tab from the floating window. Replaced in tests.
    var presentApp: (AppEnvironment) -> Void = { env in
        NSApp.activate(ignoringOtherApps: true)
        OrbitWindowController.window(for: env)?.makeKeyAndOrderFront(nil)
    }

    static let confirmationTicks = 6

    static let tickInterval: TimeInterval = 0.5

    /// Nothing playing and nothing floating: focus cannot open or close picture-in-picture.
    /// A pending request stays on `tickInterval`, because confirmation is counted in those ticks.
    private static let idleTickInterval: TimeInterval = 2

    func start(env: AppEnvironment) {
        guard timer == nil else { return }
        lastActiveTabID = env.activeTabID
        armTimer(env: env, interval: desiredTickInterval(env: env))
    }

    private func desiredTickInterval(env: AppEnvironment) -> TimeInterval {
        let busy = pendingRequest != nil
            || pipTabID != nil
            || env.mediaStates.values.contains { $0.isPlaying || $0.isPictureInPictureActive }
        return busy ? Self.tickInterval : Self.idleTickInterval
    }

    private func armTimer(env: AppEnvironment, interval: TimeInterval) {
        timer?.invalidate()
        let armed = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(env: env) }
        }
        if interval > Self.tickInterval {
            armed.tolerance = 0.5
        }
        timer = armed
    }

    private func notePlaybackCadence(env: AppEnvironment) {
        guard let timer else { return }
        let interval = desiredTickInterval(env: env)
        guard abs(timer.timeInterval - interval) > 0.001 else { return }
        armTimer(env: env, interval: interval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick(env: AppEnvironment) {
        settlePendingRequest(env: env)
        settleFloatingWindowClosed(env: env)

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
           env.webContents[losingFocus] != nil {
            requestPiP(for: losingFocus, env: env)
        }

        if let floating = pipTabID, Self.isOnScreen(floating, env: env) {
            dismissPiP(for: floating, env: env)
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

        if env.mediaStates[pending.tabID]?.isPictureInPictureActive == true {
            pendingRequest = nil
            pipTabID = pending.tabID
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
            pendingRequest = (pending.tabID, remaining)
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
        pendingRequest = (tabID, Self.confirmationTicks)
        return true
    }

    func dismissPiP(for tabID: TabID, env: AppEnvironment) {
        if pendingRequest?.tabID == tabID {
            pendingRequest = nil
        }
        if returnCandidate == tabID { returnCandidate = nil }
        guard pipTabID == tabID else { return }
        if let contents = env.webContents[tabID], contents.mediaState.isPictureInPictureActive {
            contents.togglePictureInPicture()
        }
        pipTabID = nil
    }

    #if DEBUG
    func _test_reset() {
        stop()
        lastActiveTabID = nil
        pipTabID = nil
        pendingRequest = nil
        returnCandidate = nil
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
