//  chrome.contextMenus items are worthless if they are registered and never
//  rendered, so these assert the rendering half: the grouping rule Chrome's own
//  ContextMenuMatcher uses, and that selecting a row reaches the engine.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ExtensionContextMenuEntriesTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private let capabilities: EngineCapabilities = [.developerTools, .audioMuting]

    private func id(_ extensionID: String, _ stringUID: String) -> ExtensionContextMenuItemID {
        ExtensionContextMenuItemID(extensionID: extensionID, stringUID: stringUID)
    }

    private func entries(
        _ groups: [ExtensionContextMenuGroup],
        contents: MockWebContents
    ) -> [OrbitContextMenuEntry] {
        env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com")),
            capabilities: capabilities,
            extensionGroups: groups
        )
    }

    // MARK: - Grouping

    func test_oneNormalTopLevelItem_isShownDirectlyUnderItsOwnTitle() {
        let contents = MockWebContents()
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Dark Reader",
            items: [ExtensionContextMenuItem(id: id("aaaa", "toggle"), title: "Toggle for this site")]
        )]

        let result = entries(groups, contents: contents)
        let item = result.first(titled: "Toggle for this site")
        XCTAssertNotNil(
            item,
            """
            A single normal top-level item must appear under its own title, not buried in a \
            submenu named after the extension. Present: \(result.flattenedItems.map(\.title))
            """
        )
        XCTAssertNil(
            result.first(titled: "Dark Reader"),
            "A lone item must not also be wrapped in an extension-named submenu."
        )
        XCTAssertFalse(item?.hasSubmenu ?? true)
    }

    func test_twoTopLevelItems_areGroupedUnderTheExtensionName() {
        let contents = MockWebContents()
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Stylus",
            items: [
                ExtensionContextMenuItem(id: id("aaaa", "one"), title: "Write style for this site"),
                ExtensionContextMenuItem(id: id("aaaa", "two"), title: "Find styles"),
            ]
        )]

        let result = entries(groups, contents: contents)
        guard let parent = result.first(titled: "Stylus") else {
            return XCTFail("Two top-level items must be grouped under the extension's own name. Present: \(result.flattenedItems.map(\.title))")
        }
        XCTAssertTrue(parent.hasSubmenu)
        XCTAssertEqual(
            parent.submenu?.flattenedItems.map(\.title),
            ["Write style for this site", "Find styles"],
            "The submenu must carry both items, in the order the extension created them."
        )
    }

    func test_aLoneCheckboxItem_isStillGroupedUnderTheExtensionName() {
        let contents = MockWebContents()
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Stylus",
            items: [ExtensionContextMenuItem(id: id("aaaa", "on"), title: "Enabled", type: .checkbox, isChecked: true)]
        )]

        let result = entries(groups, contents: contents)
        XCTAssertNotNil(
            result.first(titled: "Stylus"),
            """
            Only a NORMAL lone item is promoted to the top level; a checkbox or radio keeps its \
            extension-named parent, exactly as ContextMenuMatcher::GetTopLevelContextMenuTitle does.
            """
        )
    }

    func test_eachExtensionGetsItsOwnEntry() {
        let contents = MockWebContents()
        let groups = [
            ExtensionContextMenuGroup(
                extensionID: "aaaa", extensionName: "Dark Reader",
                items: [ExtensionContextMenuItem(id: id("aaaa", "a"), title: "Toggle")]
            ),
            ExtensionContextMenuGroup(
                extensionID: "bbbb", extensionName: "Stylus",
                items: [ExtensionContextMenuItem(id: id("bbbb", "b"), title: "Write style")]
            ),
        ]

        let result = entries(groups, contents: contents)
        XCTAssertNotNil(result.first(titled: "Toggle"))
        XCTAssertNotNil(result.first(titled: "Write style"))
    }

    // MARK: - Item shape

    func test_nestedChildren_becomeASubmenu() {
        let contents = MockWebContents()
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Nested",
            items: [ExtensionContextMenuItem(
                id: id("aaaa", "parent"), title: "Parent",
                children: [
                    ExtensionContextMenuItem(id: id("aaaa", "child1"), title: "Child one"),
                    ExtensionContextMenuItem(id: id("aaaa", "child2"), title: "Child two"),
                ]
            )]
        )]

        let result = entries(groups, contents: contents)
        guard let parent = result.first(titled: "Parent") else { return XCTFail("no Parent item") }
        XCTAssertTrue(parent.hasSubmenu)
        XCTAssertEqual(parent.submenu?.flattenedItems.map(\.title), ["Child one", "Child two"])
        XCTAssertNil(parent.action, "A parent that opens a submenu must not also fire onClicked.")
    }

    func test_checkedItemsRenderAsChecked_andDisabledItemsAsDisabled() {
        let contents = MockWebContents()
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "States",
            items: [
                ExtensionContextMenuItem(id: id("aaaa", "on"), title: "On", type: .checkbox, isChecked: true),
                ExtensionContextMenuItem(id: id("aaaa", "off"), title: "Off", type: .checkbox, isChecked: false),
                ExtensionContextMenuItem(id: id("aaaa", "dead"), title: "Dead", isEnabled: false),
            ]
        )]

        let result = entries(groups, contents: contents)
        XCTAssertEqual(result.first(titled: "On")?.isChecked, true)
        XCTAssertEqual(result.first(titled: "Off")?.isChecked, false)
        XCTAssertEqual(result.first(titled: "Dead")?.isEnabled, false)
    }

    func test_aSeparatorItem_becomesADivider() {
        let contents = MockWebContents()
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Split",
            items: [
                ExtensionContextMenuItem(id: id("aaaa", "a"), title: "Above"),
                ExtensionContextMenuItem(id: id("aaaa", "sep"), title: "", type: .separator),
                ExtensionContextMenuItem(id: id("aaaa", "b"), title: "Below"),
            ]
        )]

        let result = entries(groups, contents: contents)
        let submenu = result.first(titled: "Split")?.submenu ?? []
        var sawDivider = false
        for entry in submenu {
            if case .divider = entry { sawDivider = true }
        }
        XCTAssertTrue(sawDivider, "A `separator` item must render as a divider, not as a blank row.")
        XCTAssertNil(
            submenu.first(titled: ""),
            "A separator must not also appear as an empty, clickable item."
        )
    }

    func test_aRunOfRadioItems_isFencedOffFromTheItemsAroundIt() {
        let contents = MockWebContents()
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Radios",
            items: [
                ExtensionContextMenuItem(id: id("aaaa", "n"), title: "Normal"),
                ExtensionContextMenuItem(id: id("aaaa", "r1"), title: "One", type: .radio, isChecked: true),
                ExtensionContextMenuItem(id: id("aaaa", "r2"), title: "Two", type: .radio),
                ExtensionContextMenuItem(id: id("aaaa", "n2"), title: "After"),
            ]
        )]

        let submenu = entries(groups, contents: contents).first(titled: "Radios")?.submenu ?? []
        var titlesAndDividers: [String] = []
        for entry in submenu {
            switch entry {
            case .item(let item): titlesAndDividers.append(item.title)
            case .divider: titlesAndDividers.append("---")
            case .section: break
            }
        }
        XCTAssertEqual(
            titlesAndDividers, ["Normal", "---", "One", "Two", "---", "After"],
            "A run of adjacent radio items is a group, and Chrome fences each run with separators."
        )
    }

    // MARK: - Selecting an item reaches the engine

    func test_selectingAnItem_dispatchesItByItsOwnId() {
        let contents = MockWebContents()
        let itemID = id("aaaa", "toggle")
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Dark Reader",
            items: [ExtensionContextMenuItem(id: itemID, title: "Toggle for this site")]
        )]

        let result = entries(groups, contents: contents)
        result.first(titled: "Toggle for this site")?.action?()

        XCTAssertEqual(
            contents.performedExtensionContextMenuItemIDs, [itemID],
            """
            Selecting the row must fire exactly that item's onClicked. Ids are per-extension, so \
            the extension id has to travel with the uid -- otherwise one extension's item can \
            dispatch another's.
            """
        )
    }

    func test_selectingANestedChild_dispatchesTheChildNotTheParent() {
        let contents = MockWebContents()
        let childID = id("aaaa", "child")
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Nested",
            items: [ExtensionContextMenuItem(
                id: id("aaaa", "parent"), title: "Parent",
                children: [ExtensionContextMenuItem(id: childID, title: "Child")]
            )]
        )]

        let result = entries(groups, contents: contents)
        result.flattenedItems.first { $0.title == "Child" }?.action?()

        XCTAssertEqual(contents.performedExtensionContextMenuItemIDs, [childID])
    }

    func test_integerIdsSurviveIntoTheDispatch() {
        let contents = MockWebContents()
        let itemID = ExtensionContextMenuItemID(extensionID: "aaaa", uid: 7)
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Generated",
            items: [ExtensionContextMenuItem(id: itemID, title: "Generated")]
        )]

        entries(groups, contents: contents).first(titled: "Generated")?.action?()

        XCTAssertEqual(contents.performedExtensionContextMenuItemIDs.first?.uid, 7)
        XCTAssertEqual(contents.performedExtensionContextMenuItemIDs.first?.stringUID, "")
    }

    // MARK: - The rest of the menu is untouched

    func test_noExtensionItems_leavesTheMenuExactlyAsItWas() {
        let contents = MockWebContents()
        let withNone = entries([], contents: contents)
        XCTAssertEqual(
            withNone.flattenedItems.last?.title, "Inspect Element",
            "With no extension items the menu must be unchanged, ending in Inspect Element."
        )
    }

    func test_extensionItemsSitAboveInspectElement() {
        let contents = MockWebContents()
        let groups = [ExtensionContextMenuGroup(
            extensionID: "aaaa", extensionName: "Dark Reader",
            items: [ExtensionContextMenuItem(id: id("aaaa", "toggle"), title: "Toggle for this site")]
        )]

        let titles = entries(groups, contents: contents).flattenedItems.map(\.title)
        guard let extensionIndex = titles.firstIndex(of: "Toggle for this site"),
              let inspectIndex = titles.firstIndex(of: "Inspect Element")
        else { return XCTFail("expected both items. Present: \(titles)") }
        XCTAssertLessThan(
            extensionIndex, inspectIndex,
            "Extension items belong above Inspect Element, as they do in Chrome."
        )
    }

    // MARK: - Decoding the engine's payload

    func test_decodingTheEnginePayload_readsIdsTypesAndNesting() {
        let json = """
        [{"extensionId":"aaaa","extensionName":"Dark Reader","items":[
          {"id":{"extensionId":"aaaa","stringUid":"parent"},"title":"Parent","type":"normal","checked":false,"enabled":true,
           "children":[{"id":{"extensionId":"aaaa","uid":3},"title":"Child","type":"radio","checked":true,"enabled":false}]}
        ]}]
        """

        let groups = ExtensionContextMenuGroup.decode(json: json)
        XCTAssertEqual(groups.count, 1)
        let parent = groups.first?.items.first
        XCTAssertEqual(parent?.id.stringUID, "parent")
        XCTAssertNil(parent?.id.uid)
        let child = parent?.children.first
        XCTAssertEqual(child?.id.uid, 3)
        XCTAssertEqual(child?.type, .radio)
        XCTAssertEqual(child?.isChecked, true)
        XCTAssertEqual(child?.isEnabled, false)
    }

    func test_aMalformedPayload_contributesNoItemsRatherThanBreakingTheMenu() {
        XCTAssertEqual(ExtensionContextMenuGroup.decode(json: "not json").count, 0)
        XCTAssertEqual(ExtensionContextMenuGroup.decode(json: "[]").count, 0)
    }
}
