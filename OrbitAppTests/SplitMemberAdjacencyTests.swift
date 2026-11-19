//  Regression cover: panes of a split group left apart in the sidebar list rendered as two separate rows,
//  because the sidebar only joins adjacent members of one group into a single cell.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class SplitMemberAdjacencyTests: XCTestCase {

    private func makeStore() -> BrowserStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitTests-SplitAdjacency-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BrowserStore(stateStore: StateStore(rootDirectory: root, maxBackups: 0), autoArchiveInterval: nil)
    }

    private func openToday(_ store: BrowserStore, _ host: String, in spaceID: SpaceID, at index: Int? = nil) -> TabID {
        store.openTab(url: URL(string: "https://\(host).example.com")!, in: spaceID, section: .today, at: index, activate: false)
    }

    private func rows(_ store: BrowserStore, in spaceID: SpaceID) -> [SidebarSplitRowGroup<Tab>] {
        let today = store.state.spaces.first { $0.id == spaceID }?.today ?? []
        return groupedSidebarRows(today.compactMap { store.state.tabs[$0] }, splitGroup: { store.splitGroup(for: $0) })
    }

    private func today(_ store: BrowserStore, in spaceID: SpaceID) -> [TabID] {
        store.state.spaces.first { $0.id == spaceID }?.today ?? []
    }

    // MARK: - Pure ordering

    func test_gathered_pullsLaterMembersToTheEarliestOne_inPaneOrder() {
        let ids = (0..<5).map { _ in UUID() }
        let result = SplitMemberOrdering.gathered([ids[3], ids[1]], in: ids)
        XCTAssertEqual(result, [ids[0], ids[3], ids[1], ids[2], ids[4]])
    }

    func test_gathered_leavesTheListAloneForFewerThanTwoPresentMembers() {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(SplitMemberOrdering.gathered([ids[2], UUID()], in: ids), ids)
        XCTAssertEqual(SplitMemberOrdering.gathered([], in: ids), ids)
    }

    func test_gathered_isIdempotent() {
        let ids = (0..<6).map { _ in UUID() }
        let once = SplitMemberOrdering.gathered([ids[5], ids[0], ids[2]], in: ids)
        XCTAssertEqual(SplitMemberOrdering.gathered([ids[5], ids[0], ids[2]], in: once), once)
    }

    func test_gathered_inTree_gathersSiblingsAndLeavesOtherFoldersAlone() {
        let a = UUID(), b = UUID(), other = UUID(), inFolderA = UUID(), inFolderB = UUID()
        let nodes: [SidebarNode] = [
            .tab(a),
            .tab(other),
            .tab(b),
            .folder(Folder(name: "F", children: [.tab(inFolderA), .tab(inFolderB)])),
        ]
        let result = SplitMemberOrdering.gathered([a, b], in: nodes)
        XCTAssertEqual(result.map(\.id), [a, b, other, nodes[3].id])

        // Members in different lists cannot share a cell, so nothing moves.
        let split = SplitMemberOrdering.gathered([a, inFolderA], in: nodes)
        XCTAssertEqual(split, nodes)
    }

    // MARK: - Store entry points

    func test_createSplit_withTabsApart_joinsThemIntoOneRow() {
        let store = makeStore()
        let spaceID = store.spaces[0].id
        let first = openToday(store, "a", in: spaceID)
        let between = openToday(store, "between", in: spaceID)
        let second = openToday(store, "b", in: spaceID)

        XCTAssertNotNil(store.createSplit(with: [first, second]))

        XCTAssertEqual(today(store, in: spaceID).filter { [first, between, second].contains($0) }, [first, second, between])
        let splitRows = rows(store, in: spaceID).compactMap { row -> [Tab]? in
            if case .split(_, let members) = row { return members }
            return nil
        }
        XCTAssertEqual(splitRows.count, 1, "The pair must be a single joined row.")
        XCTAssertEqual(splitRows.first?.map(\.id), [first, second])
        let singles = rows(store, in: spaceID).compactMap { row -> TabID? in
            if case .single(let tab) = row { return tab.id }
            return nil
        }
        XCTAssertTrue(singles.contains(between), "The bystander stays an ordinary row.")
    }

    func test_addToSplit_withTheNewTabAtTheEnd_stacksItBesideItsGroup() {
        // The keyboard split opens the blank pane with activate: false, which appends it to the end of Today.
        let store = makeStore()
        let spaceID = store.spaces[0].id
        let existing = openToday(store, "existing", in: spaceID)
        let bystander = openToday(store, "bystander", in: spaceID)
        let blank = openToday(store, "blank", in: spaceID)

        let groupID = store.createSplit(with: [existing, blank])
        XCTAssertNotNil(groupID)
        XCTAssertEqual(today(store, in: spaceID).filter { [existing, bystander, blank].contains($0) }, [existing, blank, bystander])

        let third = openToday(store, "third", in: spaceID)
        XCTAssertTrue(store.addToSplit(third, groupID: groupID!))
        let grouped = rows(store, in: spaceID).filter { if case .split = $0 { return true }; return false }
        XCTAssertEqual(grouped.count, 1)
        guard case .split(_, let members) = grouped[0] else { return XCTFail("Expected the three panes in one row.") }
        XCTAssertEqual(members.map(\.id), [existing, blank, third])
        XCTAssertEqual(today(store, in: spaceID).filter { [existing, blank, third, bystander].contains($0) }, [existing, blank, third, bystander])
    }

    func test_movePaneInSplit_reordersTheRowToMatchPaneOrder() {
        let store = makeStore()
        let spaceID = store.spaces[0].id
        let left = openToday(store, "left", in: spaceID)
        let right = openToday(store, "right", in: spaceID)
        XCTAssertNotNil(store.createSplit(with: [left, right]))

        XCTAssertTrue(store.movePaneInSplit(left, by: 1))

        let joined = rows(store, in: spaceID).compactMap { row -> [Tab]? in
            if case .split(_, let members) = row { return members }
            return nil
        }
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined.first?.map(\.id), [right, left])
    }

    // MARK: - Repair of existing data

    func test_repairingSidebarMembership_joinsGroupsSavedWithPanesApart() {
        let store = makeStore()
        let spaceID = store.spaces[0].id
        let first = openToday(store, "a", in: spaceID)
        let between = openToday(store, "between", in: spaceID)
        let second = openToday(store, "b", in: spaceID)
        XCTAssertNotNil(store.createSplit(with: [first, second]))

        // What an older build persisted: the group exists, the panes are not adjacent.
        var legacy = store.state
        let index = legacy.spaces.firstIndex { $0.id == spaceID }!
        let others = legacy.spaces[index].today.filter { ![first, between, second].contains($0) }
        legacy.spaces[index].today = others + [first, between, second]

        let repaired = legacy.repairingSidebarMembership()
        XCTAssertEqual(repaired?.spaces[index].today, others + [first, second, between])
        XCTAssertNil(repaired?.repairingSidebarMembership(), "A repaired state must need no further repair.")
    }
}
