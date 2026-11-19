import Foundation

// The sidebar joins split panes into one cell only when they are adjacent siblings in the same list, so the model keeps them adjacent, in pane order, instead of leaving each call site that creates or extends a split to remember to.
nonisolated public enum SplitMemberOrdering {

    /// Moves every id in `members` that is present in `ids` to sit together, in `members` order, at the position of the earliest one. Ids outside `members` keep their relative order. Returns `ids` unchanged when fewer than two members are present.
    public static func gathered(_ members: [TabID], in ids: [TabID]) -> [TabID] {
        let memberSet = Set(members)
        let present = members.filter { ids.contains($0) }
        guard present.count > 1, let anchor = ids.firstIndex(where: { memberSet.contains($0) }) else { return ids }

        var result: [TabID] = []
        result.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() {
            if index == anchor { result.append(contentsOf: present) }
            if !memberSet.contains(id) { result.append(id) }
        }
        return result
    }

    /// The same rule over a pinned tree. Each sibling list is gathered on its own: panes in different folders, or one pinned and one in Today, cannot share a cell, so they are left where they are.
    public static func gathered(_ members: [TabID], in nodes: [SidebarNode]) -> [SidebarNode] {
        let memberSet = Set(members)
        let present = members.filter { id in nodes.contains { if case .tab(let tabID) = $0 { return tabID == id }; return false } }

        var result: [SidebarNode] = []
        result.reserveCapacity(nodes.count)
        let anchor = present.count > 1
            ? nodes.firstIndex(where: { if case .tab(let id) = $0 { return memberSet.contains(id) }; return false })
            : nil

        for (index, node) in nodes.enumerated() {
            if index == anchor { result.append(contentsOf: present.map { SidebarNode.tab($0) }) }
            switch node {
            case .tab(let id):
                if anchor != nil, memberSet.contains(id) { continue }
                result.append(node)
            case .folder(var folder):
                folder.children = gathered(members, in: folder.children)
                result.append(.folder(folder))
            }
        }
        return result
    }
}

extension OrbitState {

    /// Re-orders the group's panes to be adjacent and in pane order wherever they share a list.
    mutating func gatherSplitMembers(of groupID: UUID) {
        guard let group = splitGroups[groupID], group.tabIDs.count > 1 else { return }
        for index in spaces.indices {
            spaces[index].today = SplitMemberOrdering.gathered(group.tabIDs, in: spaces[index].today)
            spaces[index].pinned = SplitMemberOrdering.gathered(group.tabIDs, in: spaces[index].pinned)
        }
    }

    /// Repairs every group, for state saved or synced before the model kept panes adjacent.
    mutating func gatherAllSplitMembers() {
        for groupID in splitGroups.keys { gatherSplitMembers(of: groupID) }
    }
}
