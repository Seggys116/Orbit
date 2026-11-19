import Foundation

// MARK: - Policy

nonisolated public struct TabRendererReleasePolicy: Equatable, Sendable {

    public var minimumIdle: TimeInterval

    public var limit: Int?

    // Whether a released page that was on screen is photographed first, so reselecting it shows the page while it reloads.
    // Off under memory pressure: the picture costs memory and keeps the page's process alive for the capture.
    public var capturesSnapshot: Bool

    public init(minimumIdle: TimeInterval, limit: Int?, capturesSnapshot: Bool = true) {
        self.minimumIdle = minimumIdle
        self.limit = limit
        self.capturesSnapshot = capturesSnapshot
    }

    public static func inactivity(after idleThreshold: TimeInterval) -> TabRendererReleasePolicy {
        TabRendererReleasePolicy(minimumIdle: idleThreshold, limit: nil)
    }

    public static func memoryPressureWarning(idleThreshold: TimeInterval) -> TabRendererReleasePolicy {
        TabRendererReleasePolicy(minimumIdle: idleThreshold, limit: nil, capturesSnapshot: false)
    }

    public static let memoryPressureCritical = TabRendererReleasePolicy(minimumIdle: 0, limit: nil, capturesSnapshot: false)

    public static func budgetOvershoot(_ overshoot: Int, idleThreshold: TimeInterval) -> TabRendererReleasePolicy {
        TabRendererReleasePolicy(minimumIdle: idleThreshold, limit: max(0, overshoot))
    }
}

// MARK: - Store API

public extension BrowserStore {

    // Only what the document alone can decide. Which tabs are on screen is per window (each window's visible Space,
    // the split it shows), so the environment passes those in as protected rather than every Space's active tab
    // and every split being kept here forever.
    func isEligibleForRendererRelease(_ id: TabID) -> Bool {
        guard let tab = state.tabs[id] else { return false }
        guard tab.section != .archived else { return false }
        return true
    }

    func tabsToReleaseRenderers(
        liveTabIDs: Set<TabID>,
        protectedTabIDs: Set<TabID> = [],
        policy: TabRendererReleasePolicy,
        now: Date = Date()
    ) -> [TabID] {
        let candidates = liveTabIDs
            .subtracting(protectedTabIDs)
            .filter { isEligibleForRendererRelease($0) }
            .compactMap { id -> (id: TabID, lastAccessedAt: Date)? in
                guard let tab = state.tabs[id] else { return nil }
                guard now.timeIntervalSince(tab.lastAccessedAt) >= policy.minimumIdle else { return nil }
                return (id, tab.lastAccessedAt)
            }
            .sorted { $0.lastAccessedAt == $1.lastAccessedAt ? $0.id < $1.id : $0.lastAccessedAt < $1.lastAccessedAt }
            .map(\.id)

        guard let limit = policy.limit else { return candidates }
        return Array(candidates.prefix(limit))
    }

    func setRendererLive(_ id: TabID, _ isLive: Bool) {
        guard let tab = state.tabs[id], tab.isUnloaded == isLive else { return }
        var newState = state
        newState.tabs[id]?.isUnloaded = !isLive
        state = newState
    }
}
