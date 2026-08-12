import Foundation

public extension BrowserStore {

    func splitGroup(for tabID: TabID) -> SplitGroup? {
        guard let groupID = state.tabs[tabID]?.splitGroupID else { return nil }
        return state.splitGroups[groupID]
    }

    func splitPanes(containing tabID: TabID) -> [Tab] {
        guard let group = splitGroup(for: tabID) else {
            return state.tabs[tabID].map { [$0] } ?? []
        }
        return group.tabIDs.compactMap { state.tabs[$0] }
    }

    @discardableResult
    func createSplit(with tabIDs: [TabID], axis: SplitGroup.Axis = .horizontal) -> UUID? {
        let deduped = BrowserStore.removingDuplicates(tabIDs)
        guard deduped.count >= 2, let firstSpaceID = state.tabs[deduped[0]]?.spaceID else { return nil }
        let validIDs = deduped.filter { state.tabs[$0]?.spaceID == firstSpaceID }
        guard validIDs.count >= 2 else { return nil }
        let clamped = Array(validIDs.prefix(SplitGroup.maximumPanes))

        var newState = state
        for tabID in clamped {
            detachFromSplit(tabID, in: &newState)
        }

        let group = SplitGroup(tabIDs: clamped, axis: axis)
        newState.splitGroups[group.id] = group
        assignSplitMetadata(group, in: &newState)
        state = newState
        return group.id
    }

    @discardableResult
    func addToSplit(_ tabID: TabID, groupID: UUID, at index: Int? = nil) -> Bool {
        guard let group = state.splitGroups[groupID], let newTab = state.tabs[tabID] else { return false }
        guard group.tabIDs.count < SplitGroup.maximumPanes else { return false }
        guard !group.tabIDs.contains(tabID) else { return false }
        guard let firstMemberSpaceID = group.tabIDs.first.flatMap({ state.tabs[$0]?.spaceID }),
              newTab.spaceID == firstMemberSpaceID else { return false }

        var newState = state
        detachFromSplit(tabID, in: &newState)
        guard var freshGroup = newState.splitGroups[groupID] else { return false }
        let clampedIndex = index.map { max(0, min($0, freshGroup.tabIDs.count)) } ?? freshGroup.tabIDs.count
        freshGroup.tabIDs.insert(tabID, at: clampedIndex)
        let evenFraction = 1.0 / Double(freshGroup.tabIDs.count)
        freshGroup.fractions = Array(repeating: evenFraction, count: freshGroup.tabIDs.count)
        newState.splitGroups[groupID] = freshGroup
        assignSplitMetadata(freshGroup, in: &newState)
        state = newState
        return true
    }

    @discardableResult
    func movePaneInSplit(_ tabID: TabID, by offset: Int) -> Bool {
        guard offset != 0,
              let groupID = state.tabs[tabID]?.splitGroupID,
              var group = state.splitGroups[groupID],
              let index = group.tabIDs.firstIndex(of: tabID) else { return false }
        let destination = index + offset
        guard destination >= 0, destination < group.tabIDs.count else { return false }

        if group.fractions.count == group.tabIDs.count {
            let fraction = group.fractions.remove(at: index)
            group.fractions.insert(fraction, at: destination)
        }
        group.tabIDs.remove(at: index)
        group.tabIDs.insert(tabID, at: destination)

        var newState = state
        newState.splitGroups[groupID] = group
        assignSplitMetadata(group, in: &newState)
        state = newState
        return true
    }

    func removeFromSplit(_ tabID: TabID) {
        var newState = state
        detachFromSplit(tabID, in: &newState)
        state = newState
    }

    func dissolveSplit(_ groupID: UUID) {
        guard let group = state.splitGroups[groupID] else { return }
        var newState = state
        for tabID in group.tabIDs {
            newState.tabs[tabID]?.splitGroupID = nil
            newState.tabs[tabID]?.splitIndex = 0
        }
        newState.splitGroups.removeValue(forKey: groupID)
        state = newState
    }

    @discardableResult
    func setSplitAxis(_ axis: SplitGroup.Axis, forGroup groupID: UUID) -> Bool {
        guard var group = state.splitGroups[groupID], group.axis != axis else { return false }
        group.axis = axis
        var newState = state
        newState.splitGroups[groupID] = group
        state = newState
        return true
    }

    func setSplitFractions(_ fractions: [Double], forGroup groupID: UUID, minimumFraction: Double = 0.12) {
        guard var group = state.splitGroups[groupID], fractions.count == group.tabIDs.count else { return }
        let clamped = fractions.map { max(minimumFraction, $0) }
        let total = clamped.reduce(0, +)
        guard total > 0 else { return }
        group.fractions = clamped.map { $0 / total }
        var newState = state
        newState.splitGroups[groupID] = group
        state = newState
    }

    // MARK: - Helpers

    private func assignSplitMetadata(_ group: SplitGroup, in newState: inout OrbitState) {
        for (index, tabID) in group.tabIDs.enumerated() {
            newState.tabs[tabID]?.splitGroupID = group.id
            newState.tabs[tabID]?.splitIndex = index
        }
    }

    private static func removingDuplicates(_ ids: [TabID]) -> [TabID] {
        var seen = Set<TabID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
