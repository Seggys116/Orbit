import Foundation

// MARK: - Policy

nonisolated public struct TabRendererReleasePolicy: Equatable, Sendable {

    public var minimumIdle: TimeInterval

    public var limit: Int?

    public init(minimumIdle: TimeInterval, limit: Int?) {
        self.minimumIdle = minimumIdle
        self.limit = limit
    }

    public static func inactivity(after idleThreshold: TimeInterval) -> TabRendererReleasePolicy {
        TabRendererReleasePolicy(minimumIdle: idleThreshold, limit: nil)
    }

    public static func memoryPressureWarning(idleThreshold: TimeInterval) -> TabRendererReleasePolicy {
        TabRendererReleasePolicy(minimumIdle: idleThreshold, limit: nil)
    }

    public static let memoryPressureCritical = TabRendererReleasePolicy(minimumIdle: 0, limit: nil)

    public static func budgetOvershoot(_ overshoot: Int, idleThreshold: TimeInterval) -> TabRendererReleasePolicy {
        TabRendererReleasePolicy(minimumIdle: idleThreshold, limit: max(0, overshoot))
    }
}

// MARK: - Store API

public extension BrowserStore {

    func isEligibleForRendererRelease(_ id: TabID) -> Bool {
        guard let tab = state.tabs[id] else { return false }
        guard tab.section != .archived else { return false }
        guard tab.splitGroupID == nil else { return false }
        guard !state.activeTabBySpace.values.contains(id) else { return false }
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
