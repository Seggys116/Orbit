//  Drives SidebarNewItemOption against the real AppEnvironment, invoking the menu items' actions.

import Foundation
import AppKit
import XCTest
@testable import Orbit

@MainActor
final class SidebarNewItemMenuTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private func makeTab(url: String = "https://example.com") -> Orbit.Tab {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab
    }

    // env.activeTabID's setter is a silent no-op when state.activeSpaceID is
    // nil, so a test that needs it to stick must select the tab's space first.
    private func activate(_ tab: Orbit.Tab) {
        env.selectSpace(tab.spaceID)
        env.activeTabID = tab.id
    }

    private func cleanup(_ tabIDs: [TabID]) {
        for id in tabIDs {
            env.state.tabs.removeValue(forKey: id)
        }
    }

    // MARK: - The menu offers exactly the seven items, in order

    func test_allCases_isExactlyTheSevenItemsInTheOriginalMenusOrder() {
        XCTAssertEqual(
            SidebarNewItemOption.allCases,
            [.newTab, .newSplitView, .newFolder, .newSpace, .newNote, .newEasel, .newBoost]
        )
    }

    func test_contextMenuEntries_itemTitles_matchAllCasesInOrder() {
        let titles = SidebarNewItemOption.contextMenuEntries(in: env).compactMap { entry -> String? in
            if case .item(let item) = entry { return item.title }
            return nil
        }
        XCTAssertEqual(titles, SidebarNewItemOption.allCases.map(\.title))
    }

    private func menuItem(titled title: String) -> OrbitContextMenuItem? {
        for entry in SidebarNewItemOption.contextMenuEntries(in: env) {
            if case .item(let item) = entry, item.title == title { return item }
        }
        return nil
    }

    // MARK: - .newTab

    func test_perform_newTab_presentsTheCommandBarInNewTabMode() {
        env.isCommandBarPresented = false
        SidebarNewItemOption.newTab.perform(in: env)
        XCTAssertTrue(env.isCommandBarPresented)
        if case .newTab = env.commandBarMode {
            // expected
        } else {
            XCTFail("Expected commandBarMode == .newTab, found \(env.commandBarMode).")
        }
    }

    func test_invokingTheNewTabMenuItem_presentsTheCommandBar() {
        env.isCommandBarPresented = false
        guard let item = menuItem(titled: "New Tab") else {
            XCTFail("Expected a \"New Tab\" item in the menu.")
            return
        }
        item.action?()
        XCTAssertTrue(env.isCommandBarPresented, "Invoking the \"New Tab\" menu item must present the Command Bar.")
    }

    // MARK: - .newSplitView

    func test_perform_newSplitView_withNoActiveTab_fallsBackToTheCommandBar() {
        env.activeTabID = nil
        env.isCommandBarPresented = false
        SidebarNewItemOption.newSplitView.perform(in: env)
        XCTAssertTrue(env.isCommandBarPresented)
    }

    func test_perform_newSplitView_withAnActiveTab_createsATwoPaneSplitGroup() {
        let tab = makeTab()
        activate(tab)
        defer {
            if let group = env.splitGroup(for: tab.id) {
                cleanup(group.tabIDs)
                env.store.dissolveSplit(group.id)
            } else {
                cleanup([tab.id])
            }
        }

        SidebarNewItemOption.newSplitView.perform(in: env)

        guard let group = env.splitGroup(for: tab.id) else {
            XCTFail("SidebarNewItemOption.newSplitView.perform(in:) did not create a split group.")
            return
        }
        XCTAssertEqual(group.tabIDs.count, 2)
    }

    // MARK: - .newFolder

    func test_perform_newFolder_addsAFolderToTheActiveSpacesPinnedRoot() {
        guard let spaceID = env.activeSpace?.id else {
            XCTFail("test precondition: demo environment must have an active Space.")
            return
        }
        let before = env.pinnedNodes(in: spaceID).count

        SidebarNewItemOption.newFolder.perform(in: env)

        let after = env.pinnedNodes(in: spaceID)
        defer {
            if let added = after.first(where: { node in
                if case .folder(let folder) = node { return folder.name == "New Folder" }
                return false
            }), case .folder(let folder) = added {
                env.deleteFolder(folder.id, in: spaceID, keepingChildren: false)
            }
        }
        XCTAssertEqual(after.count, before + 1, "\"New Folder\" must add exactly one node to the Pinned root.")
    }

    func test_invokingTheNewFolderMenuItem_addsAFolder() {
        guard let spaceID = env.activeSpace?.id else {
            XCTFail("test precondition: demo environment must have an active Space.")
            return
        }
        let before = env.pinnedNodes(in: spaceID).count
        guard let item = menuItem(titled: "New Folder") else {
            XCTFail("Expected a \"New Folder\" item in the menu.")
            return
        }

        item.action?()

        let after = env.pinnedNodes(in: spaceID)
        defer {
            if let added = after.first(where: { node in
                if case .folder(let folder) = node { return folder.name == "New Folder" }
                return false
            }), case .folder(let folder) = added {
                env.deleteFolder(folder.id, in: spaceID, keepingChildren: false)
            }
        }
        XCTAssertEqual(after.count, before + 1, "Invoking the \"New Folder\" menu item must add exactly one node to the Pinned root.")
    }

    // MARK: - .newSpace

    func test_perform_newSpace_postsThePresentNewSpaceFlowNotification() {
        let expectation = expectation(forNotification: .orbitPresentNewSpaceFlow, object: nil, handler: nil)
        SidebarNewItemOption.newSpace.perform(in: env)
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - .newNote / .newEasel

    func test_perform_newNote_opensANewPinnedNoteTabInTheActiveSpace() {
        guard let spaceID = env.activeSpace?.id else {
            XCTFail("test precondition: demo environment must have an active Space.")
            return
        }
        let before = Set(env.pinnedNodes(in: spaceID).map(\.id))

        SidebarNewItemOption.newNote.perform(in: env)

        let after = env.pinnedNodes(in: spaceID)
        let added = after.first { !before.contains($0.id) }
        defer {
            if case .tab(let tabID) = added { env.closeTab(tabID) }
        }
        guard case .tab(let tabID) = added, let tab = env.tab(tabID) else {
            XCTFail("\"New Note\" must open exactly one new pinned tab.")
            return
        }
        XCTAssertEqual(tab.url.scheme, "orbit")
        XCTAssertEqual(tab.url.host(), "note")
    }

    func test_perform_newEasel_opensANewPinnedEaselTabInTheActiveSpace() {
        guard let spaceID = env.activeSpace?.id else {
            XCTFail("test precondition: demo environment must have an active Space.")
            return
        }
        let before = Set(env.pinnedNodes(in: spaceID).map(\.id))

        SidebarNewItemOption.newEasel.perform(in: env)

        let after = env.pinnedNodes(in: spaceID)
        let added = after.first { !before.contains($0.id) }
        defer {
            if case .tab(let tabID) = added { env.closeTab(tabID) }
        }
        guard case .tab(let tabID) = added, let tab = env.tab(tabID) else {
            XCTFail("\"New Easel\" must open exactly one new pinned tab.")
            return
        }
        XCTAssertEqual(tab.url.scheme, "orbit")
        XCTAssertEqual(tab.url.host(), "easel")
    }

    // MARK: - .newBoost

    // Observed manually: expectation(forNotification:object:)'s object-matching is documented
    // against reference-type identity, not guaranteed for a bridged String value.
    func test_perform_newBoost_withAnActiveTab_postsThePresentBoostsEditorNotificationWithItsHost() {
        let tab = makeTab(url: "https://boosts.example.com/page")
        activate(tab)
        defer { cleanup([tab.id]) }

        var receivedHost: String?
        let observer = NotificationCenter.default.addObserver(forName: .orbitPresentBoostsEditor, object: nil, queue: nil) { note in
            receivedHost = note.object as? String
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        SidebarNewItemOption.newBoost.perform(in: env)

        XCTAssertEqual(receivedHost, "boosts.example.com")
    }

    func test_perform_newBoost_withNoActiveTab_postsNoNotification() {
        env.activeTabID = nil
        var received = false
        let observer = NotificationCenter.default.addObserver(forName: .orbitPresentBoostsEditor, object: nil, queue: nil) { _ in
            received = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        SidebarNewItemOption.newBoost.perform(in: env)

        XCTAssertFalse(received, "With no active tab there is no host to Boost, so no notification should fire.")
    }
}
