import Foundation

public enum SyncScope {

    // MARK: - Predicates

    public static func ephemeralProfileIDs(in state: OrbitState) -> Set<ProfileID> {
        Set(state.profiles.filter { OrbitState.isEphemeral($0) }.map(\.id))
    }

    public static func ephemeralSpaceIDs(in state: OrbitState) -> Set<SpaceID> {
        let ephemeralProfiles = ephemeralProfileIDs(in: state)
        return Set(
            state.spaces
                .filter { $0.isEphemeral || ephemeralProfiles.contains($0.profileID) }
                .map(\.id)
        )
    }

    public static func isSyncable(_ profile: Profile) -> Bool {
        !OrbitState.isEphemeral(profile)
    }

    // MARK: - The filter

    // Only guard against pushing an Incognito Profile/Space/Tab to CloudKit; SyncRecordMapping has none of its own.
    public static func syncable(_ state: OrbitState) -> OrbitState {
        let droppedProfiles = ephemeralProfileIDs(in: state)
        let droppedSpaces = ephemeralSpaceIDs(in: state)
        guard !droppedProfiles.isEmpty || !droppedSpaces.isEmpty else { return state }

        var scoped = state
        scoped.profiles.removeAll { droppedProfiles.contains($0.id) }
        scoped.spaces.removeAll { droppedSpaces.contains($0.id) }

        var droppedTabIDs: Set<TabID> = []
        var droppedSplitGroupIDs: Set<UUID> = []
        for (tabID, tab) in state.tabs where droppedSpaces.contains(tab.spaceID) {
            droppedTabIDs.insert(tabID)
            if let groupID = tab.splitGroupID { droppedSplitGroupIDs.insert(groupID) }
            scoped.tabs.removeValue(forKey: tabID)
        }
        for groupID in droppedSplitGroupIDs {
            scoped.splitGroups.removeValue(forKey: groupID)
        }
        for spaceID in droppedSpaces {
            scoped.activeTabBySpace.removeValue(forKey: spaceID)
        }
        if let active = scoped.activeSpaceID, droppedSpaces.contains(active) {
            scoped.activeSpaceID = scoped.spaces.first?.id
        }

        scoped.routingRules.removeAll { rule in
            switch rule.destination {
            case .space(let id): return droppedSpaces.contains(id)
            case .profile(let id): return droppedProfiles.contains(id)
            case .application, .littleOrbit, .mostRecentSpace: return false
            }
        }

        return scoped
    }
}
