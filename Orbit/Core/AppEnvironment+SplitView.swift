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

    var label: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }

    var symbolName: String {
        switch self {
        case .left, .right: "rectangle.split.2x1"
        case .top, .bottom: "rectangle.split.1x2"
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
        // The pane that just arrived takes focus, as the active tab, when the split is the one on screen.
        if activeSplitGroup?.id == groupID, let index = state.splitGroups[groupID]?.tabIDs.firstIndex(of: tabID) {
            focusedSplitPaneIndex = index
        }
        return groupID
    }

    @discardableResult
    func movePane(_ tabID: TabID, by offset: Int) -> Bool {
        // The focused pane is the one holding the active tab, so it follows the move by itself.
        store.movePaneInSplit(tabID, by: offset)
    }

    /// Where a pane lands when it is dropped on `edge` of another pane of its split: just before or after that pane, in the order of the split.
    static func rearrangedIndex(from source: Int, onto target: Int, edge: SplitEdge) -> Int {
        var destination = edge.insertsBefore ? target : target + 1
        if source < destination { destination -= 1 }
        return destination
    }

    /// Moves a pane to the side of another pane of the same split. The active tab does not change, so the focus follows the page.
    @discardableResult
    func rearrangePane(_ tabID: TabID, onto targetTabID: TabID, edge: SplitEdge) -> Bool {
        guard tabID != targetTabID, let group = splitGroup(for: tabID), group.tabIDs.contains(targetTabID),
              let source = group.tabIDs.firstIndex(of: tabID), let target = group.tabIDs.firstIndex(of: targetTabID) else { return false }
        let destination = Self.rearrangedIndex(from: source, onto: target, edge: edge)
        guard destination != source else { return false }
        return movePane(tabID, by: destination - source)
    }

    /// Takes the pane out of its split and leaves its page open. The pane's close control is `closeSplitPaneTab`.
    func closeSplitPane(_ tabID: TabID) {
        store.removeFromSplit(tabID)
    }

    /// What the close control on a pane does: closes that one page, by the same rule as Close Tab, and leaves
    /// the other panes as they were. A split of three keeps its other two; a split of two leaves the survivor
    /// full size. Focus lands on the pane beside the closed one, not on whichever tab the Space last used.
    func closeSplitPaneTab(_ tabID: TabID) {
        let survivor = splitGroup(for: tabID).flatMap { group -> TabID? in
            guard let index = group.tabIDs.firstIndex(of: tabID) else { return nil }
            let neighbours = [index + 1, index - 1].filter { group.tabIDs.indices.contains($0) }
            return neighbours.first.map { group.tabIDs[$0] }
        }
        let wasActive = activeTabID == tabID

        if let page = tab(tabID), NewTabPageModel.isUnlisted(page) {
            discardNewTabPage(tabID)
        } else {
            closeTabPreservingBookmark(tabID)
        }

        guard wasActive, let survivor, tab(survivor) != nil else { return }
        activateTab(survivor)
    }

    func separateAllTabs(_ groupID: UUID) {
        store.dissolveSplit(groupID)
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
