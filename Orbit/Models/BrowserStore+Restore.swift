import Foundation

// MARK: - Scope

nonisolated public enum RestoreDataScope: String, CaseIterable, Identifiable, Sendable {
    case sidebar

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sidebar: return "Sidebar"
        }
    }
}

// MARK: - Outcome

nonisolated public struct RestoreOutcome: Sendable, Equatable {
    public var spaceCount: Int
    public var tabCount: Int
    public var rescuedProfileCount: Int
    public var reassignedSpaceCount: Int

    public init(spaceCount: Int, tabCount: Int, rescuedProfileCount: Int, reassignedSpaceCount: Int) {
        self.spaceCount = spaceCount
        self.tabCount = tabCount
        self.rescuedProfileCount = rescuedProfileCount
        self.reassignedSpaceCount = reassignedSpaceCount
    }
}

// MARK: - Store API

public extension BrowserStore {

    func availableBackups() -> [StateBackup] {
        stateStore.availableBackups()
    }

    @discardableResult
    func restore(from backup: StateBackup, scope: RestoreDataScope = .sidebar) throws -> RestoreOutcome {
        let restored = try stateStore.decodeBackup(backup)

        var newState = state
        var rescuedProfileCount = 0
        var reassignedSpaceCount = 0

        switch scope {
        case .sidebar:
            newState.spaces = restored.spaces
            newState.tabs = restored.tabs
            newState.splitGroups = restored.splitGroups
            newState.activeSpaceID = restored.activeSpaceID
            newState.activeTabBySpace = restored.activeTabBySpace

            let liveProfileIDs = Set(newState.profiles.map(\.id))
            let neededProfileIDs = Set(newState.spaces.map(\.profileID))
            let rescued = restored.profiles.filter {
                neededProfileIDs.contains($0.id) && !liveProfileIDs.contains($0.id)
            }
            newState.profiles.append(contentsOf: rescued)
            rescuedProfileCount = rescued.count

            let survivingProfileIDs = Set(newState.profiles.map(\.id))
            if let fallbackProfileID = newState.profiles.first?.id {
                for index in newState.spaces.indices
                where !survivingProfileIDs.contains(newState.spaces[index].profileID) {
                    newState.spaces[index].profileID = fallbackProfileID
                    reassignedSpaceCount += 1
                }
            }
        }

        newState = newState.strippingEphemeralEntities()
        state = newState

        try saveNow()

        return RestoreOutcome(
            spaceCount: newState.spaces.count,
            tabCount: newState.tabs.count,
            rescuedProfileCount: rescuedProfileCount,
            reassignedSpaceCount: reassignedSpaceCount
        )
    }
}
