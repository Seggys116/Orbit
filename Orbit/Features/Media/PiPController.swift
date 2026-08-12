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

    static let confirmationTicks = 6

    static let tickInterval: TimeInterval = 0.5

    func start(env: AppEnvironment) {
        guard timer == nil else { return }
        lastActiveTabID = env.activeTabID
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(env: env) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick(env: AppEnvironment) {
        settlePendingRequest(env: env)

        let currentActive = env.activeTabID
        defer { lastActiveTabID = currentActive }

        guard currentActive != lastActiveTabID else { return }

        if let losingFocus = lastActiveTabID, losingFocus != pipTabID,
           pendingRequest?.tabID != losingFocus,
           let state = env.mediaStates[losingFocus], state.hasVideo, state.isPlaying,
           env.webContents[losingFocus] != nil {
            requestPiP(for: losingFocus, env: env)
        }

        if let newlyFocused = currentActive, newlyFocused == pipTabID {
            dismissPiP(for: newlyFocused, env: env)
        }
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
    }

    func _test_hasPendingRequest(for tabID: TabID) -> Bool {
        pendingRequest?.tabID == tabID
    }

    func _test_seedLastActiveTab(_ tabID: TabID?) {
        lastActiveTabID = tabID
    }
    #endif
}
