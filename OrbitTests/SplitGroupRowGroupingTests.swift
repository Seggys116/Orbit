import XCTest

final class SplitGroupRowGroupingTests: XCTestCase {

    private func makeTab(spaceID: SpaceID) -> Tab {
        Tab(spaceID: spaceID, url: URL(string: "https://example.com")!)
    }

    // MARK: - [Tab] overload (TodaySectionView)

    func test_groupedSidebarRows_tabs_collapsesConsecutiveSplitPaneIntoOneEntry() {
        let spaceID = SpaceID()
        var first = makeTab(spaceID: spaceID)
        var second = makeTab(spaceID: spaceID)
        let group = SplitGroup(tabIDs: [first.id, second.id])
        first.splitGroupID = group.id
        second.splitGroupID = group.id
        let third = makeTab(spaceID: spaceID)

        let result = groupedSidebarRows([first, second, third]) { tabID in
            tabID == first.id || tabID == second.id ? group : nil
        }

        XCTAssertEqual(result.count, 2, "Expected exactly two row entries: the joined pair, then the lone third tab.")
        guard case .split(let resultGroup, let members) = result[0] else {
            XCTFail("Expected the first entry to be a .split, got \(result[0]).")
            return
        }
        XCTAssertEqual(resultGroup.id, group.id)
        XCTAssertEqual(members.map(\.id), [first.id, second.id], "Split members must stay in their original list order.")
        guard case .single(let lastTab) = result[1] else {
            XCTFail("Expected the second entry to be a .single, got \(result[1]).")
            return
        }
        XCTAssertEqual(lastTab.id, third.id)
    }

    func test_groupedSidebarRows_tabs_aSoloSplitMemberWithNoAdjacentSiblingStaysSingle() {
        let spaceID = SpaceID()
        var lone = makeTab(spaceID: spaceID)
        let group = SplitGroup(tabIDs: [lone.id, UUID()])
        lone.splitGroupID = group.id
        let other = makeTab(spaceID: spaceID)

        let result = groupedSidebarRows([lone, other]) { tabID in
            tabID == lone.id ? group : nil
        }

        XCTAssertEqual(result.count, 2, "A split member with no adjacent same-group sibling in this list must render as two ordinary singles, not force a one-member joined row.")
        for entry in result {
            guard case .single = entry else {
                XCTFail("Expected every entry to be .single when no run of 2+ same-group tabs exists, got \(entry).")
                return
            }
        }
    }

    func test_groupedSidebarRows_tabs_withNoSplitGroupsAtAll_returnsAllSingles() {
        let spaceID = SpaceID()
        let tabs = (0..<4).map { _ in makeTab(spaceID: spaceID) }

        let result = groupedSidebarRows(tabs) { _ in nil }

        XCTAssertEqual(result.count, tabs.count)
        XCTAssertEqual(
            result.compactMap { entry -> TabID? in
                if case .single(let tab) = entry { return tab.id }
                return nil
            },
            tabs.map(\.id),
            "Ungrouped tabs must stay in their original order, one .single entry per tab."
        )
    }

    func test_groupedSidebarRows_tabs_threePaneSplitCollapsesIntoOneEntry() {
        let spaceID = SpaceID()
        var tabs = (0..<3).map { _ in makeTab(spaceID: spaceID) }
        let group = SplitGroup(tabIDs: tabs.map(\.id))
        for index in tabs.indices { tabs[index].splitGroupID = group.id }

        let result = groupedSidebarRows(tabs) { tabID in
            tabs.contains { $0.id == tabID } ? group : nil
        }

        XCTAssertEqual(result.count, 1)
        guard case .split(_, let members) = result[0] else {
            XCTFail("Expected a single .split entry for all three panes, got \(result).")
            return
        }
        XCTAssertEqual(members.map(\.id), tabs.map(\.id))
    }

    // MARK: - [SidebarNode] overload (PinnedSectionView)

    func test_groupedSidebarRows_nodes_aFolderBetweenSplitPanesBreaksTheRun() {
        let spaceID = SpaceID()
        var first = makeTab(spaceID: spaceID)
        var second = makeTab(spaceID: spaceID)
        let group = SplitGroup(tabIDs: [first.id, second.id])
        first.splitGroupID = group.id
        second.splitGroupID = group.id
        let folder = Folder(name: "Reading")

        let nodes: [SidebarNode] = [.tab(first.id), .folder(folder), .tab(second.id)]
        let tabsByID = [first.id: first, second.id: second]

        let result = groupedSidebarRows(nodes, tab: { tabsByID[$0] }, splitGroup: { $0 == first.id || $0 == second.id ? group : nil })

        XCTAssertEqual(result.count, 3, "A folder between the two split panes must prevent them from collapsing into one entry.")
        for entry in result {
            guard case .single = entry else {
                XCTFail("Expected every entry to be .single once a folder interrupts the run, got \(entry).")
                return
            }
        }
    }

    func test_groupedSidebarRows_nodes_collapsesConsecutiveSplitTabNodesIntoOneEntry() {
        let spaceID = SpaceID()
        var first = makeTab(spaceID: spaceID)
        var second = makeTab(spaceID: spaceID)
        let group = SplitGroup(tabIDs: [first.id, second.id])
        first.splitGroupID = group.id
        second.splitGroupID = group.id
        let tabsByID = [first.id: first, second.id: second]

        let nodes: [SidebarNode] = [.tab(first.id), .tab(second.id)]
        let result = groupedSidebarRows(nodes, tab: { tabsByID[$0] }, splitGroup: { $0 == first.id || $0 == second.id ? group : nil })

        XCTAssertEqual(result.count, 1)
        guard case .split(let resultGroup, let members) = result[0] else {
            XCTFail("Expected a single .split entry, got \(result).")
            return
        }
        XCTAssertEqual(resultGroup.id, group.id)
        XCTAssertEqual(members.map(\.id), [first.id, second.id])
    }
}
