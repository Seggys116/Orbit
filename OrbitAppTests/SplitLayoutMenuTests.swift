//  Regression guard: the split view button opened no dropdown. Drives SplitLayoutOption
//  directly, and buildNSMenu's real NSMenuItem pairs, the way AppKit's own tracking loop does.

import Foundation
import AppKit
import XCTest
@testable import Orbit

@MainActor
final class SplitLayoutMenuTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func makeTab(url: String = "https://example.com") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func cleanup(_ tabIDs: [TabID]) {
        for id in tabIDs {
            env.state.tabs.removeValue(forKey: id)
        }
    }

    // MARK: - Which options are offered (the "list of options" itself)

    func test_options_forAStandalonePane_offersAllFourDirectionsAndNothingElse() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }

        XCTAssertNil(env.splitGroup(for: tab.id), "test precondition: not already split")
        let options = SplitLayoutOption.options(forPaneOf: tab, in: env)

        XCTAssertEqual(options, [.splitRight, .splitLeft, .splitDown, .splitUp])
    }

    func test_options_forAPaneInAnUnderfullSplit_offersArcsFullListInArcsOrder() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        let options = SplitLayoutOption.options(forPaneOf: tabA, in: env)
        XCTAssertEqual(options, [
            .movePaneBackward, .movePaneForward,
            .addSplitTrailing, .addSplitLeading,
            .separateThisTab, .flipToVertical,
            .separateAllTabs, .expandThisPane,
            .shareSplitView,
        ])
    }

    func test_options_forAPaneInAFullSplit_omitsBothAddItems() {
        var tabIDs: [TabID] = []
        for index in 0..<SplitGroup.maximumPanes {
            tabIDs.append(makeTab(url: "https://pane\(index).example.com").id)
        }
        defer { cleanup(tabIDs) }
        guard let groupID = env.store.createSplit(with: tabIDs, axis: .horizontal) else {
            XCTFail("Failed to create a full split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }
        XCTAssertEqual(env.store.splitGroup(for: tabIDs[0])?.tabIDs.count, SplitGroup.maximumPanes, "test precondition: group is genuinely full")

        let options = SplitLayoutOption.options(forPaneOf: env.tab(tabIDs[0])!, in: env)
        XCTAssertEqual(
            options,
            [.movePaneBackward, .movePaneForward, .separateThisTab, .flipToVertical, .separateAllTabs, .expandThisPane, .shareSplitView],
            "Neither Add item may be offered once the group is already at SplitGroup.maximumPanes."
        )
    }

    // MARK: - Move Left / Move Right

    func test_movePair_isAlwaysListed_andDisabledOnlyAtTheEnds() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        let tabC = makeTab(url: "https://c.example.com")
        defer { cleanup([tabA.id, tabB.id, tabC.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id, tabC.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        for tab in [tabA, tabB, tabC] {
            let options = SplitLayoutOption.options(forPaneOf: tab, in: env)
            XCTAssertTrue(options.contains(.movePaneBackward), "Move Left must be listed for every pane, greyed or not.")
            XCTAssertTrue(options.contains(.movePaneForward), "Move Right must be listed for every pane, greyed or not.")
        }

        XCTAssertFalse(SplitLayoutOption.isEnabled(.movePaneBackward, forPaneOf: tabA, in: env), "The first pane cannot move further left.")
        XCTAssertTrue(SplitLayoutOption.isEnabled(.movePaneForward, forPaneOf: tabA, in: env))
        XCTAssertTrue(SplitLayoutOption.isEnabled(.movePaneBackward, forPaneOf: tabB, in: env))
        XCTAssertTrue(SplitLayoutOption.isEnabled(.movePaneForward, forPaneOf: tabB, in: env))
        XCTAssertTrue(SplitLayoutOption.isEnabled(.movePaneBackward, forPaneOf: tabC, in: env))
        XCTAssertFalse(SplitLayoutOption.isEnabled(.movePaneForward, forPaneOf: tabC, in: env), "The last pane cannot move further right — exactly the greyed state the reference capture was taken in.")
    }

    func test_perform_movePaneForward_reordersThePanesAndCarriesTheirFractions() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }
        env.resizeSplit(groupID, fractions: [0.7, 0.3])

        SplitLayoutOption.perform(.movePaneForward, forPaneOf: tabA, in: env)

        guard let group = env.splitGroup(for: tabA.id) else {
            XCTFail("Moving a pane must not dissolve the group.")
            return
        }
        XCTAssertEqual(group.tabIDs, [tabB.id, tabA.id], "\"Move Right\" must put the pane after its neighbour.")
        XCTAssertEqual(group.fractions.count, 2)
        XCTAssertEqual(group.fractions[1], 0.7, accuracy: 0.0001, "The moved pane must keep its own width, not inherit its neighbour's.")
        XCTAssertEqual(group.fractions[0], 0.3, accuracy: 0.0001)
    }

    func test_perform_movePaneBackward_movesThePaneTowardTheLeadingEdge() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        let tabC = makeTab(url: "https://c.example.com")
        defer { cleanup([tabA.id, tabB.id, tabC.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id, tabC.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        SplitLayoutOption.perform(.movePaneBackward, forPaneOf: tabC, in: env)

        XCTAssertEqual(env.splitGroup(for: tabC.id)?.tabIDs, [tabA.id, tabC.id, tabB.id])
    }

    func test_perform_movePane_atTheEnd_changesNothing() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        SplitLayoutOption.perform(.movePaneBackward, forPaneOf: tabA, in: env)

        XCTAssertEqual(env.splitGroup(for: tabA.id)?.tabIDs, [tabA.id, tabB.id])
    }

    func test_movePane_keepsTheFocusOnTheSamePane_notTheSameIndex() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }
        env.activateTab(tabA.id)
        env.focusSplitPane(index: 0)
        XCTAssertEqual(env.focusedSplitPaneIndex, 0, "test precondition: the leading pane is focused")

        SplitLayoutOption.perform(.movePaneForward, forPaneOf: tabA, in: env)

        XCTAssertEqual(env.splitGroup(for: tabA.id)?.tabIDs, [tabB.id, tabA.id])
        XCTAssertEqual(env.focusedSplitPaneIndex, 1, "The focused pane moved to index 1, so the focus index must follow it.")
    }

    // MARK: - Axis-aware titles and icons

    func test_titles_followTheGroupsAxis() {
        XCTAssertEqual(SplitLayoutOption.movePaneBackward.title(inGroupWith: .horizontal), "Move Left")
        XCTAssertEqual(SplitLayoutOption.movePaneForward.title(inGroupWith: .horizontal), "Move Right")
        XCTAssertEqual(SplitLayoutOption.addSplitTrailing.title(inGroupWith: .horizontal), "Add Right Split")
        XCTAssertEqual(SplitLayoutOption.addSplitLeading.title(inGroupWith: .horizontal), "Add Left Split")
        XCTAssertEqual(SplitLayoutOption.separateThisTab.title(inGroupWith: .horizontal), "Separate Tab from Split")
        XCTAssertEqual(SplitLayoutOption.flipToVertical.title(inGroupWith: .horizontal), "Convert to Vertical Split View")
        XCTAssertEqual(SplitLayoutOption.shareSplitView.title(inGroupWith: .horizontal), "Share Split View…")

        XCTAssertEqual(SplitLayoutOption.movePaneBackward.title(inGroupWith: .vertical), "Move Up")
        XCTAssertEqual(SplitLayoutOption.movePaneForward.title(inGroupWith: .vertical), "Move Down")
        XCTAssertEqual(SplitLayoutOption.addSplitTrailing.title(inGroupWith: .vertical), "Add Bottom Split")
        XCTAssertEqual(SplitLayoutOption.addSplitLeading.title(inGroupWith: .vertical), "Add Top Split")
        XCTAssertEqual(SplitLayoutOption.flipToHorizontal.title(inGroupWith: .vertical), "Convert to Horizontal Split View")
    }

    func test_buildNSMenu_forAStackedSplit_usesTheStackedWording() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .vertical) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        let titles = SplitLayoutOption.buildNSMenu(forPaneOf: tabA, in: env).items.map(\.title)

        XCTAssertTrue(titles.contains("Move Up"), "A stacked split must not offer \"Move Left\"; it had: \(titles)")
        XCTAssertTrue(titles.contains("Add Bottom Split"), "…nor \"Add Right Split\"; it had: \(titles)")
        XCTAssertTrue(titles.contains("Convert to Horizontal Split View"))
    }

    func test_buildNSMenu_everyItemCarriesARealSymbolImage() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        for (axis, label) in [(SplitGroup.Axis.horizontal, "side-by-side"), (.vertical, "stacked")] {
            env.setSplitAxis(axis, forGroup: groupID)
            let menu = SplitLayoutOption.buildNSMenu(forPaneOf: tabA, in: env)
            for item in menu.items where !item.isSeparatorItem {
                XCTAssertNotNil(item.image, "\"\(item.title)\" (\(label)) has no icon — its SF Symbol name does not resolve on this OS.")
                XCTAssertTrue(item.image?.isTemplate ?? false, "\"\(item.title)\" (\(label))'s icon must be a template so it greys out with its title.")
            }
        }

        let lone = makeTab(url: "https://lone.example.com")
        defer { cleanup([lone.id]) }
        for item in SplitLayoutOption.buildNSMenu(forPaneOf: lone, in: env).items where !item.isSeparatorItem {
            XCTAssertNotNil(item.image, "\"\(item.title)\" has no icon.")
        }
    }

    // MARK: - Share Split View…

    func test_shareItems_areEveryPanesPageInPaneOrder() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        XCTAssertEqual(
            SplitLayoutOption.shareItems(forPaneOf: tabB, in: env).map(\.absoluteString),
            ["https://a.example.com", "https://b.example.com"]
        )
        XCTAssertTrue(SplitLayoutOption.isEnabled(.shareSplitView, forPaneOf: tabB, in: env))
    }

    func test_shareItems_dropBlankPanes_andTheItemGreysOutWithNothingToShare() {
        let real = makeTab(url: "https://a.example.com")
        let blank = makeTab(url: "orbit://new-tab")
        let blankToo = makeTab(url: "orbit://new-tab")
        defer { cleanup([real.id, blank.id, blankToo.id]) }

        guard let mixedID = env.store.createSplit(with: [real.id, blank.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        XCTAssertEqual(
            SplitLayoutOption.shareItems(forPaneOf: real, in: env).map(\.absoluteString), ["https://a.example.com"],
            "A blank pane has no page to share."
        )
        env.store.dissolveSplit(mixedID)

        guard let blankOnlyID = env.store.createSplit(with: [blank.id, blankToo.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(blankOnlyID) }
        XCTAssertTrue(SplitLayoutOption.shareItems(forPaneOf: blank, in: env).isEmpty)
        XCTAssertFalse(
            SplitLayoutOption.isEnabled(.shareSplitView, forPaneOf: blank, in: env),
            "With nothing shareable the item must be greyed, not silently no-op when clicked."
        )
    }

    // MARK: - Flipping the orientation (Horizontal = side by side, Vertical = top and bottom)

    func test_options_offerOnlyTheFlipThatWouldChangeSomething() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        let sideBySide = SplitLayoutOption.options(forPaneOf: tabA, in: env)
        XCTAssertTrue(sideBySide.contains(.flipToVertical), "a side-by-side split must be offered the stack-them flip")
        XCTAssertFalse(sideBySide.contains(.flipToHorizontal), "…and must not be offered the axis it already has")

        env.setSplitAxis(.vertical, forGroup: groupID)

        let stacked = SplitLayoutOption.options(forPaneOf: tabA, in: env)
        XCTAssertTrue(stacked.contains(.flipToHorizontal))
        XCTAssertFalse(stacked.contains(.flipToVertical))
    }

    func test_perform_flip_changesTheGroupsAxisBothWays() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        SplitLayoutOption.perform(.flipToVertical, forPaneOf: tabA, in: env)
        XCTAssertEqual(env.splitGroup(for: tabA.id)?.axis, .vertical, "picking the flip must actually stack the panes")
        XCTAssertEqual(env.splitGroup(for: tabA.id)?.tabIDs, [tabA.id, tabB.id], "a flip must not drop or reorder panes")

        SplitLayoutOption.perform(.flipToHorizontal, forPaneOf: tabA, in: env)
        XCTAssertEqual(env.splitGroup(for: tabA.id)?.axis, .horizontal, "…and it must flip back")
    }

    func test_perform_flip_actsOnTheMenusOwnPaneNotTheActiveTab() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        let unrelated = makeTab(url: "https://elsewhere.example.com")
        defer { cleanup([tabA.id, tabB.id, unrelated.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }
        env.activateTab(unrelated.id)

        SplitLayoutOption.perform(.flipToVertical, forPaneOf: tabB, in: env)

        XCTAssertEqual(env.splitGroup(for: tabB.id)?.axis, .vertical)
    }

    func test_invokingTheFlipMenuItem_flipsTheGroup() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        let menu = SplitLayoutOption.buildNSMenu(forPaneOf: tabA, in: env)
        guard let item = menu.items.first(where: { $0.title == SplitLayoutOption.flipToVertical.title(inGroupWith: .horizontal) }) else {
            XCTFail("The Split View menu must carry a flip item; it had: \(menu.items.map(\.title))")
            return
        }
        guard let action = item.action, let target = item.target else {
            XCTFail("The flip menu item has no target/action pair, so clicking it would do nothing.")
            return
        }
        _ = target.perform(action, with: item)

        XCTAssertEqual(env.splitGroup(for: tabA.id)?.axis, .vertical)
    }

    // MARK: - What picking an option actually does

    func test_perform_splitRight_createsATwoPaneGroupWithTheExistingTabFirst() {
        let tab = makeTab()
        defer {
            if let group = env.splitGroup(for: tab.id) {
                cleanup(group.tabIDs)
                env.store.dissolveSplit(group.id)
            } else {
                cleanup([tab.id])
            }
        }

        SplitLayoutOption.perform(.splitRight, forPaneOf: tab, in: env)

        guard let group = env.splitGroup(for: tab.id) else {
            XCTFail("SplitLayoutOption.perform(.splitRight, ...) did not create a split group.")
            return
        }
        XCTAssertEqual(group.tabIDs.count, 2)
        XCTAssertEqual(group.tabIDs.first, tab.id, "\"Split Right\" must keep the existing tab in the leading position.")
        XCTAssertEqual(group.axis, .horizontal)
    }

    func test_perform_splitLeft_insertsTheNewPaneBeforeTheExistingTab() {
        let tab = makeTab()
        defer {
            if let group = env.splitGroup(for: tab.id) {
                cleanup(group.tabIDs)
                env.store.dissolveSplit(group.id)
            } else {
                cleanup([tab.id])
            }
        }

        SplitLayoutOption.perform(.splitLeft, forPaneOf: tab, in: env)

        guard let group = env.splitGroup(for: tab.id) else {
            XCTFail("SplitLayoutOption.perform(.splitLeft, ...) did not create a split group.")
            return
        }
        XCTAssertEqual(group.tabIDs.count, 2)
        XCTAssertEqual(group.tabIDs.last, tab.id, "\"Split Left\" must place the existing tab in the trailing position, after the new pane.")
    }

    func test_perform_splitDown_createsAVerticalGroup() {
        let tab = makeTab()
        defer {
            if let group = env.splitGroup(for: tab.id) {
                cleanup(group.tabIDs)
                env.store.dissolveSplit(group.id)
            } else {
                cleanup([tab.id])
            }
        }

        SplitLayoutOption.perform(.splitDown, forPaneOf: tab, in: env)

        guard let group = env.splitGroup(for: tab.id) else {
            XCTFail("SplitLayoutOption.perform(.splitDown, ...) did not create a split group.")
            return
        }
        XCTAssertEqual(group.axis, .vertical)
    }

    func test_perform_addSplitTrailing_extendsAnExistingGroupToThreePanesOnTheTrailingEdge() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }

        SplitLayoutOption.perform(.addSplitTrailing, forPaneOf: tabA, in: env)

        let group = env.splitGroup(for: tabA.id)
        defer {
            cleanup((group?.tabIDs ?? [tabA.id, tabB.id]))
            if let group { env.store.dissolveSplit(group.id) } else { env.store.dissolveSplit(groupID) }
        }
        XCTAssertEqual(group?.tabIDs.count, 3, "\"Add Right Split\" should extend the existing group to three panes.")
        XCTAssertEqual(Array(group?.tabIDs.prefix(2) ?? []), [tabA.id, tabB.id], "The new pane belongs on the trailing edge, after both existing panes.")
        XCTAssertEqual(group?.axis, .horizontal, "Adding a pane must not change the group's axis.")
    }

    func test_perform_addSplitLeading_putsTheNewPaneBeforeEveryExistingOne() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }

        SplitLayoutOption.perform(.addSplitLeading, forPaneOf: tabA, in: env)

        let group = env.splitGroup(for: tabA.id)
        defer {
            cleanup((group?.tabIDs ?? [tabA.id, tabB.id]))
            if let group { env.store.dissolveSplit(group.id) } else { env.store.dissolveSplit(groupID) }
        }
        XCTAssertEqual(group?.tabIDs.count, 3)
        XCTAssertEqual(Array(group?.tabIDs.suffix(2) ?? []), [tabA.id, tabB.id], "\"Add Left Split\" must insert ahead of both existing panes.")
        XCTAssertEqual(group?.axis, .horizontal, "The added pane must stay on the group's own axis — SplitGroup cannot represent a grid.")
    }

    func test_perform_addSplitLeading_onAStackedSplit_addsARowAboveAndKeepsTheAxis() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .vertical) else {
            XCTFail("Failed to create a split group.")
            return
        }

        SplitLayoutOption.perform(.addSplitLeading, forPaneOf: tabA, in: env)

        let group = env.splitGroup(for: tabA.id)
        defer {
            cleanup((group?.tabIDs ?? [tabA.id, tabB.id]))
            if let group { env.store.dissolveSplit(group.id) } else { env.store.dissolveSplit(groupID) }
        }
        XCTAssertEqual(Array(group?.tabIDs.suffix(2) ?? []), [tabA.id, tabB.id])
        XCTAssertEqual(group?.axis, .vertical, "\"Add Top Split\" must keep the split stacked.")
    }

    func test_perform_separateAllTabs_dissolvesTheGroup() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) != nil else {
            XCTFail("Failed to create a split group.")
            return
        }
        XCTAssertNotNil(env.splitGroup(for: tabA.id), "test precondition: actually split")

        SplitLayoutOption.perform(.separateAllTabs, forPaneOf: tabA, in: env)

        XCTAssertNil(env.splitGroup(for: tabA.id), "\"Separate All Tabs\" must dissolve the group for every former member.")
        XCTAssertNil(env.splitGroup(for: tabB.id), "\"Separate All Tabs\" must dissolve the group for every former member.")
        XCTAssertNotNil(env.tab(tabA.id))
        XCTAssertNotNil(env.tab(tabB.id))
    }

    func test_perform_expandThisPane_dissolvesTheSplitAndActivatesThatPane() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) != nil else {
            XCTFail("Failed to create a split group.")
            return
        }
        env.activateTab(tabA.id)
        XCTAssertNotNil(env.splitGroup(for: tabB.id), "test precondition: actually split")

        SplitLayoutOption.perform(.expandThisPane, forPaneOf: tabB, in: env)

        XCTAssertNil(env.splitGroup(for: tabA.id), "Expanding a pane must dissolve the split it was in.")
        XCTAssertNil(env.splitGroup(for: tabB.id), "Expanding a pane must dissolve the split it was in.")
        XCTAssertEqual(env.activeTabID, tabB.id, "The expanded pane's own tab must end up active, or some other tab is what fills the window.")
        XCTAssertNotNil(env.tab(tabA.id), "The former sibling must survive as an ordinary tab — this is \"Separate All Tabs\", not \"close the others\".")
    }

    // MARK: - The real NSMenu a click presents

    private func invoke(_ item: NSMenuItem) {
        guard let target = item.target, let action = item.action else {
            XCTFail("Menu item \"\(item.title)\" has no target/action wired — a real click could never invoke it.")
            return
        }
        _ = target.perform(action, with: item)
    }

    func test_buildNSMenu_itemTitles_matchOptionsExactly() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }

        let menu = SplitLayoutOption.buildNSMenu(forPaneOf: tab, in: env)
        let axis = env.splitGroup(for: tab.id)?.axis
        let expected = SplitLayoutOption.options(forPaneOf: tab, in: env).map { $0.title(inGroupWith: axis) }

        XCTAssertEqual(menu.items.map(\.title), expected)
    }

    func test_buildNSMenu_dividersAndOrderMatchArcsOwnCapture() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer { env.store.dissolveSplit(groupID) }

        let menu = SplitLayoutOption.buildNSMenu(forPaneOf: tabA, in: env)

        XCTAssertEqual(menu.items.map(\.title), [
            "Move Left",
            "Move Right",
            "",                                 // separator
            "Add Right Split",
            "Add Left Split",
            "",                                 // separator
            "Separate Tab from Split",
            "Convert to Vertical Split View",
            "Separate All Tabs",
            "Expand to Full Width",
            "",                                 // separator
            "Share Split View…",
        ])
        for index in [2, 5, 10] {
            XCTAssertTrue(menu.items[index].isSeparatorItem, "Expected a real NSMenuItem.separator() at index \(index).")
        }
    }

    func test_buildNSMenu_everyRealItem_hasAWorkingTargetActionPair() {
        let tab = makeTab()
        defer { cleanup([tab.id]) }

        let menu = SplitLayoutOption.buildNSMenu(forPaneOf: tab, in: env)

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertNotNil(item.target, "\"\(item.title)\" has no target.")
            XCTAssertNotNil(item.action, "\"\(item.title)\" has no action.")
        }
    }

    func test_invokingTheSplitRightMenuItem_createsATwoPaneGroupWithTheExistingTabFirst() {
        let tab = makeTab()
        defer {
            if let group = env.splitGroup(for: tab.id) {
                cleanup(group.tabIDs)
                env.store.dissolveSplit(group.id)
            } else {
                cleanup([tab.id])
            }
        }

        let menu = SplitLayoutOption.buildNSMenu(forPaneOf: tab, in: env)
        guard let splitRightItem = menu.items.first(where: { $0.title == "Split Right" }) else {
            XCTFail("Expected a \"Split Right\" item in the real menu.")
            return
        }

        invoke(splitRightItem)

        guard let group = env.splitGroup(for: tab.id) else {
            XCTFail("Invoking the real \"Split Right\" NSMenuItem did not create a split group.")
            return
        }
        XCTAssertEqual(group.tabIDs.count, 2)
        XCTAssertEqual(group.tabIDs.first, tab.id, "\"Split Right\" must keep the existing tab in the leading position.")
        XCTAssertEqual(group.axis, .horizontal)
    }

    func test_invokingTheSeparateAllTabsMenuItem_dissolvesTheGroup() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        defer { cleanup([tabA.id, tabB.id]) }
        guard env.store.createSplit(with: [tabA.id, tabB.id], axis: .horizontal) != nil else {
            XCTFail("Failed to create a split group.")
            return
        }
        XCTAssertNotNil(env.splitGroup(for: tabA.id), "test precondition: actually split")

        let menu = SplitLayoutOption.buildNSMenu(forPaneOf: tabA, in: env)
        guard let separateItem = menu.items.first(where: { $0.title == "Separate All Tabs" }) else {
            XCTFail("Expected a \"Separate All Tabs\" item in the real menu.")
            return
        }

        invoke(separateItem)

        XCTAssertNil(env.splitGroup(for: tabA.id), "Invoking the real \"Separate All Tabs\" NSMenuItem must dissolve the group.")
        XCTAssertNil(env.splitGroup(for: tabB.id))
        XCTAssertNotNil(env.tab(tabA.id), "\"Separate\", not \"close\" — the tab must survive.")
        XCTAssertNotNil(env.tab(tabB.id))
    }

    func test_perform_separateThisTab_removesOnlyThatPaneFromTheGroupAndKeepsTheTab() {
        let tabA = makeTab(url: "https://a.example.com")
        let tabB = makeTab(url: "https://b.example.com")
        let tabC = makeTab(url: "https://c.example.com")
        defer { cleanup([tabA.id, tabB.id, tabC.id]) }
        guard let groupID = env.store.createSplit(with: [tabA.id, tabB.id, tabC.id], axis: .horizontal) else {
            XCTFail("Failed to create a split group.")
            return
        }
        defer {
            if let remainingGroup = env.splitGroup(for: tabB.id) {
                env.store.dissolveSplit(remainingGroup.id)
            } else {
                env.store.dissolveSplit(groupID)
            }
        }

        SplitLayoutOption.perform(.separateThisTab, forPaneOf: tabB, in: env)

        XCTAssertNil(env.splitGroup(for: tabB.id), "The separated pane must no longer be part of any group.")
        XCTAssertNotNil(env.tab(tabB.id), "\"Separate Tab from Split\" leaves the tab open — that is why it is no longer titled \"Close This Pane\".")
        let remainingGroup = env.splitGroup(for: tabA.id)
        XCTAssertEqual(remainingGroup?.tabIDs.count, 2, "The other two panes must remain grouped together.")
        XCTAssertFalse(remainingGroup?.tabIDs.contains(tabB.id) ?? true)
    }

    // MARK: - Drag-to-split geometry

    // Regression guard: drag previews only ever suggested a horizontal split.
    func test_splitDropZone_suggestsAllFourEdges_notOnlyTheHorizontalOnes() {
        let size = CGSize(width: 1600, height: 900)
        let cases: [(String, CGPoint, SplitEdge)] = [
            ("far left, vertically centred", CGPoint(x: 20, y: 450), .left),
            ("far right, vertically centred", CGPoint(x: 1580, y: 450), .right),
            ("top edge, horizontally centred", CGPoint(x: 800, y: 10), .top),
            ("bottom edge, horizontally centred", CGPoint(x: 800, y: 890), .bottom),
        ]
        for (label, point, expected) in cases {
            XCTAssertEqual(
                SplitDropZoneGeometry.edge(at: point, in: size), expected,
                "A drag at \(label) must preview a \(expected) split. Every point resolving to one direction is the reported defect."
            )
        }

        let distinct = Set(cases.map { SplitDropZoneGeometry.edge(at: $0.1, in: size) })
        XCTAssertEqual(
            distinct.count, 4,
            "All four edges must be reachable somewhere on the card; only \(distinct.count) distinct edge(s) were."
        )
    }

    func test_splitDropZone_hasNoDeadCentre_andTheDiagonalsDecide() {
        let size = CGSize(width: 1000, height: 1000)
        XCTAssertEqual(SplitDropZoneGeometry.edge(at: CGPoint(x: 400, y: 500), in: size), .left)
        XCTAssertEqual(SplitDropZoneGeometry.edge(at: CGPoint(x: 600, y: 500), in: size), .right)
        XCTAssertEqual(SplitDropZoneGeometry.edge(at: CGPoint(x: 500, y: 400), in: size), .top)
        XCTAssertEqual(SplitDropZoneGeometry.edge(at: CGPoint(x: 500, y: 600), in: size), .bottom)
    }

    func test_splitDropZone_withAnExistingSplit_onlyOffersThatSplitsOwnAxis() {
        let size = CGSize(width: 1600, height: 900)
        let everywhere = [
            CGPoint(x: 20, y: 450), CGPoint(x: 1580, y: 450),
            CGPoint(x: 800, y: 10), CGPoint(x: 800, y: 890),
            CGPoint(x: 800, y: 450),
        ]

        for point in everywhere {
            let horizontal = SplitDropZoneGeometry.edge(at: point, in: size, allowedOrientation: .horizontal)
            XCTAssertEqual(
                horizontal.orientation, .horizontal,
                "A side-by-side split must not offer a top/bottom drop at \(point) — that would ask for a grid."
            )
            let vertical = SplitDropZoneGeometry.edge(at: point, in: size, allowedOrientation: .vertical)
            XCTAssertEqual(
                vertical.orientation, .vertical,
                "A top-and-bottom split must not offer a left/right drop at \(point) — that would ask for a grid."
            )
        }

        XCTAssertEqual(SplitDropZoneGeometry.edge(at: CGPoint(x: 20, y: 450), in: size, allowedOrientation: .horizontal), .left)
        XCTAssertEqual(SplitDropZoneGeometry.edge(at: CGPoint(x: 1580, y: 450), in: size, allowedOrientation: .horizontal), .right)
        XCTAssertEqual(SplitDropZoneGeometry.edge(at: CGPoint(x: 800, y: 10), in: size, allowedOrientation: .vertical), .top)
        XCTAssertEqual(SplitDropZoneGeometry.edge(at: CGPoint(x: 800, y: 890), in: size, allowedOrientation: .vertical), .bottom)
    }

    func test_preferredSplitOrientation_splitsAlongTheLongerAxis() {
        XCTAssertEqual(
            AppEnvironment.preferredSplitOrientation(in: CGSize(width: 1600, height: 900)), .horizontal,
            "A wide card must split side by side — stacking it gives two letterbox panes no page is usable in."
        )
        XCTAssertEqual(
            AppEnvironment.preferredSplitOrientation(in: CGSize(width: 900, height: 1600)), .vertical,
            "A tall card must split top and bottom for the same reason, mirrored."
        )
        XCTAssertEqual(
            AppEnvironment.preferredSplitOrientation(in: .zero), .horizontal,
            "Before the first layout pass there is nothing to measure; the answer must be the existing default, not a crash or a divide by zero."
        )
    }

    // For n >= 2, min(w/n, h) >= min(w, h/n) exactly when w >= h, whatever n is — so the
    // production rule takes no pane count, and this guards against reintroducing one.
    func test_preferredSplitOrientation_isDecidedByTheCardsShapeAlone() {
        XCTAssertEqual(AppEnvironment.preferredSplitOrientation(in: CGSize(width: 1001, height: 1000)), .horizontal)
        XCTAssertEqual(AppEnvironment.preferredSplitOrientation(in: CGSize(width: 1000, height: 1001)), .vertical)
        XCTAssertEqual(
            AppEnvironment.preferredSplitOrientation(in: CGSize(width: 1000, height: 1000)), .horizontal,
            "A perfectly square card has no better axis; it must fall to the existing default rather than to whichever comparison ran first."
        )
    }

}
