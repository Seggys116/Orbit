import AppKit
import XCTest
@testable import Orbit

@MainActor
final class ManageSpacesLibrarySectionTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var scratchSpaceIDs: [SpaceID] = []

    override func tearDown() {
        for id in scratchSpaceIDs where env.space(id) != nil {
            env.deleteSpace(id)
        }
        scratchSpaceIDs = []
        super.tearDown()
    }

    private func makeSpace(named name: String) -> SpaceID {
        let profileID = env.createDefaultProfileIfNeeded()
        let id = env.createSpace(name: name, icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        scratchSpaceIDs.append(id)
        return id
    }

    private func noopActions(
        rename: @escaping () -> Void = {},
        changeIcon: @escaping () -> Void = {},
        editTheme: @escaping () -> Void = {}
    ) -> ManageSpacesOverflowMenu.Actions {
        .init(rename: rename, changeIcon: changeIcon, editTheme: editTheme)
    }

    private func invoke(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target else {
            return XCTFail("\(item.title) has no target/action pair — it cannot do anything when clicked.")
        }
        _ = target.perform(action, with: item)
    }

    // MARK: - The `…` overflow the reference draws on every column footer

    func testEveryOverflowMenuItemHasATargetAndAction() {
        let spaceID = makeSpace(named: "Overflow Wiring")
        let space = try! XCTUnwrap(env.space(spaceID))

        let menu = ManageSpacesOverflowMenu.build(for: space, in: env, actions: noopActions())

        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                for subitem in submenu.items where !subitem.isSeparatorItem {
                    XCTAssertNotNil(subitem.action, "`\(item.title) ▸ \(subitem.title)` does nothing when clicked.")
                    XCTAssertNotNil(subitem.target, "`\(item.title) ▸ \(subitem.title)` has no target.")
                }
            } else {
                XCTAssertNotNil(item.action, "`\(item.title)` does nothing when clicked.")
                XCTAssertNotNil(item.target, "`\(item.title)` has no target.")
            }
        }
    }

    func testOverflowMenuRenameChangeIconAndThemeAllCallBack() {
        let spaceID = makeSpace(named: "Overflow Callbacks")
        let space = try! XCTUnwrap(env.space(spaceID))

        var renamed = false
        var iconChanged = false
        var themeEdited = false
        let menu = ManageSpacesOverflowMenu.build(
            for: space,
            in: env,
            actions: noopActions(
                rename: { renamed = true },
                changeIcon: { iconChanged = true },
                editTheme: { themeEdited = true }
            )
        )

        for title in ["Rename Space", "Change Icon…", "Theme…"] {
            guard let item = menu.items.first(where: { $0.title == title }) else {
                return XCTFail("The `…` overflow lost `\(title)`.")
            }
            invoke(item)
        }

        XCTAssertTrue(renamed, "`Rename Space` did not start a rename.")
        XCTAssertTrue(iconChanged, "`Change Icon…` did not open the icon chooser.")
        XCTAssertTrue(themeEdited, "`Theme…` did not open the theme editor.")
    }

    func testOverflowDeleteSpaceReallyDeletesTheSpace() {
        let spaceID = makeSpace(named: "Overflow Delete")
        let space = try! XCTUnwrap(env.space(spaceID))
        XCTAssertGreaterThan(env.spaces.count, 1, "test precondition: more than one Space exists, so deletion is permitted")

        let menu = ManageSpacesOverflowMenu.build(for: space, in: env, actions: noopActions())
        guard let item = menu.items.first(where: { $0.title == "Delete Space" }) else {
            return XCTFail("The `…` overflow lost `Delete Space`; nothing else in this surface can delete a Space.")
        }
        XCTAssertTrue(item.isEnabled, "`Delete Space` is disabled while more than one Space exists.")
        invoke(item)

        XCTAssertNil(env.space(spaceID), "`Delete Space` did not delete the Space.")
    }

    // MARK: - The round `+` past the last column

    func testTheRoundPlusReachesTheOneNewSpaceFlow() {
        let center = NotificationCenter()
        var received = 0
        let token = center.addObserver(forName: .orbitPresentNewSpaceFlow, object: nil, queue: nil) { _ in
            received += 1
        }
        defer { center.removeObserver(token) }

        var broughtABrowserWindowForward = false
        ManageSpacesAddSpaceAction.perform(
            activateBrowserWindow: { broughtABrowserWindowForward = true },
            notificationCenter: center
        )

        XCTAssertEqual(received, 1, "The round `+` did not reach the New Space flow — it is a button that does nothing.")
        XCTAssertTrue(
            broughtABrowserWindowForward,
            "The `+` posted the New Space flow without bringing a browser window forward. Arc's New Space flow is a panel inside a browser window's sidebar, so from the Library window it would open somewhere nobody is looking."
        )
    }

    // MARK: - Placement: it is the Library's Spaces section, not a sheet

    func testEveryManageSpacesEntryPointOpensTheLibrarysSpacesSection() throws {
        let routed = "LibraryWindowController.show(section: .spaces)"
        for file in [
            "UI/Sidebar/SpaceTitleRow.swift",
            "UI/Root/BrowserWindowView.swift",
            "Core/MainMenuBuilder.swift",
        ] {
            let code = try executableSource(of: file)
            XCTAssertTrue(
                code.contains(routed),
                "\(file)'s `Manage Spaces…` no longer opens the Library window's Spaces section. That is where Arc's is — refs/reference/web/arc-manage-spaces-panel-allthingshow.png shows the Library rail beside it."
            )
        }

        let browserWindow = try executableSource(of: "UI/Root/BrowserWindowView.swift")
        XCTAssertFalse(
            browserWindow.contains("ManageSpacesView()"),
            "BrowserWindowView presents a Manage Spaces sheet again. Arc has no such sheet; it is a Library section."
        )
    }

    func testSpacesRendersItsOwnScrollingAndNoOtherSectionDoes() {
        XCTAssertTrue(
            LibrarySection.spaces.rendersItsOwnScrolling,
            "Spaces must render outside the Library's vertical ScrollView, or its full-height columns collapse to their content height."
        )
        for section in LibrarySection.allCases where section != .spaces {
            XCTAssertFalse(
                section.rendersItsOwnScrolling,
                "\(section.rawValue) is a vertical list of cards and wants the window's own scroller."
            )
        }
    }

    // MARK: - Source helper

    private func executableSource(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orbit")
        let url = root.appendingPathComponent(relativePath)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
