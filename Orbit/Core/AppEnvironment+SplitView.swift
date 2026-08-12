import Foundation

typealias SplitOrientation = SplitGroup.Axis

enum SplitEdge: Sendable {
    case left, right, top, bottom

    var orientation: SplitOrientation {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    var insertsBefore: Bool {
        switch self {
        case .left, .top: return true
        case .right, .bottom: return false
        }
    }
}

struct SplitDropZone: Equatable {
    var edge: SplitEdge
    var targetTabID: TabID
}

// Single destination partitioned by its own diagonals: separate .dropDestinations positioned with .position(x:y:) would each register over the whole card since that modifier doesn't shrink the hit area.
enum SplitDropZoneGeometry {
    static func edge(
        at location: CGPoint,
        in size: CGSize,
        allowedOrientation: SplitOrientation? = nil
    ) -> SplitEdge {
        guard size.width > 0, size.height > 0 else { return .right }

        let left = location.x / size.width
        let right = 1 - left
        let top = location.y / size.height
        let bottom = 1 - top

        switch allowedOrientation {
        case .horizontal:
            return left <= right ? .left : .right
        case .vertical:
            return top <= bottom ? .top : .bottom
        case nil:
            let nearestHorizontal = min(left, right)
            let nearestVertical = min(top, bottom)
            if nearestHorizontal <= nearestVertical {
                return left <= right ? .left : .right
            }
            return top <= bottom ? .top : .bottom
        }
    }
}

extension AppEnvironment {

    func splitGroup(for tabID: TabID) -> SplitGroup? { store.splitGroup(for: tabID) }

    var activeSplitGroup: SplitGroup? {
        guard let activeTabID else { return nil }
        return splitGroup(for: activeTabID)
    }

    func splitPanes(containing tabID: TabID) -> [Tab] { store.splitPanes(containing: tabID) }

    func preferredSplitOrientation() -> SplitOrientation {
        AppEnvironment.preferredSplitOrientation(in: contentAreaSize)
    }

    static func preferredSplitOrientation(in size: CGSize) -> SplitOrientation {
        guard size.width > 0, size.height > 0 else { return .horizontal }
        let sideBySideShorterSide = min(size.width / 2, size.height)
        let stackedShorterSide = min(size.width, size.height / 2)
        return sideBySideShorterSide >= stackedShorterSide ? .horizontal : .vertical
    }

    func preferredSplitEdge() -> SplitEdge {
        preferredSplitOrientation() == .horizontal ? .right : .bottom
    }

    @discardableResult
    func createSplit(existingTabID: TabID, newTabID: TabID, edge: SplitEdge) -> UUID? {
        guard store.tab(existingTabID) != nil, store.tab(newTabID) != nil else { return nil }

        if let existingGroup = store.splitGroup(for: existingTabID) {
            return addToSplit(tabID: newTabID, groupID: existingGroup.id, edge: edge)
        }

        let orderedIDs = edge.insertsBefore ? [newTabID, existingTabID] : [existingTabID, newTabID]
        guard let groupID = store.createSplit(with: orderedIDs, axis: edge.orientation) else { return nil }
        focusedSplitPaneIndex = orderedIDs.firstIndex(of: newTabID) ?? 0
        materializeWebContents(for: newTabID, url: store.tab(newTabID)?.url ?? URL(string: "orbit://new-tab")!)
        activateTab(existingTabID)
        return groupID
    }

    // Sets the group's axis to edge's own orientation — a pane added from a
    // perpendicular edge without this would silently lay out along the
    // group's existing axis instead of the one the drop highlight showed.
    @discardableResult
    func addToSplit(tabID: TabID, groupID: UUID, edge: SplitEdge) -> UUID? {
        guard state.splitGroups[groupID] != nil else { return nil }
        let insertIndex = edge.insertsBefore ? 0 : nil
        guard store.addToSplit(tabID, groupID: groupID, at: insertIndex) else { return groupID }
        store.setSplitAxis(edge.orientation, forGroup: groupID)
        materializeWebContents(for: tabID, url: store.tab(tabID)?.url ?? URL(string: "orbit://new-tab")!)
        focusedSplitPaneIndex = state.splitGroups[groupID]?.tabIDs.firstIndex(of: tabID) ?? 0
        return groupID
    }

    // focusedSplitPaneIndex is an index, not a tab — resolve to a tab before
    // the move and re-find it after, or a reorder silently shifts the focus border.
    @discardableResult
    func movePane(_ tabID: TabID, by offset: Int) -> Bool {
        var focusedTabID: TabID?
        if let group = store.splitGroup(for: tabID),
           group.id == activeSplitGroup?.id,
           group.tabIDs.indices.contains(focusedSplitPaneIndex) {
            focusedTabID = group.tabIDs[focusedSplitPaneIndex]
        }

        guard store.movePaneInSplit(tabID, by: offset) else { return false }

        if let focusedTabID,
           let moved = store.splitGroup(for: tabID),
           let index = moved.tabIDs.firstIndex(of: focusedTabID) {
            focusedSplitPaneIndex = index
        }
        return true
    }

    func closeSplitPane(_ tabID: TabID) {
        store.removeFromSplit(tabID)
        focusedSplitPaneIndex = 0
    }

    func separateAllTabs(_ groupID: UUID) {
        store.dissolveSplit(groupID)
        focusedSplitPaneIndex = 0
    }

    @discardableResult
    func setSplitAxis(_ axis: SplitOrientation, forGroup groupID: UUID) -> Bool {
        store.setSplitAxis(axis, forGroup: groupID)
    }

    func resizeSplit(_ groupID: UUID, fractions: [Double]) {
        store.setSplitFractions(fractions, forGroup: groupID, minimumFraction: OrbitMetrics.splitMinimumFraction)
    }

    func focusSplitPane(index: Int) {
        guard let group = activeSplitGroup, index >= 0, index < group.tabIDs.count else { return }
        focusedSplitPaneIndex = index
        let tabID = group.tabIDs[index]
        activateTab(tabID)
        // activateTab does not move AppKit's first responder by itself.
        webContents[tabID]?.focus()
    }

    func focusAdjacentSplitPane(offset: Int) {
        guard let group = activeSplitGroup, !group.tabIDs.isEmpty else { return }
        let count = group.tabIDs.count
        let newIndex = ((focusedSplitPaneIndex + offset) % count + count) % count
        focusSplitPane(index: newIndex)
    }
}
