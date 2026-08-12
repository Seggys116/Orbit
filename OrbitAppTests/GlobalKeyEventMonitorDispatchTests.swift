//  GlobalKeyEventMonitor once swallowed a matched key event whether or not it
//  was handled, so Cmd+O/Cmd+Shift+O were dead and Cmd+W over a Peek closed the tab beneath it.

import AppKit
import XCTest
@testable import Orbit

@MainActor
final class GlobalKeyEventMonitorDispatchTests: XCTestCase {

    // lazy var, not a computed property: a computed one would hand out a
    // different environment on every `env.` access within a single test.
    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var scratchSpaceID: SpaceID!
    private var originalActiveSpaceID: SpaceID?

    override func setUp() {
        super.setUp()
        PeekState.shared.dismiss()
        PeekState.shared.previewTabID = nil
        originalActiveSpaceID = env.activeSpace?.id
        // Self-healing: sibling suites can replace env.state wholesale without
        // restoring it, so profiles may be empty by the time this runs.
        let profileID = env.createDefaultProfileIfNeeded()
        scratchSpaceID = env.createSpace(
            name: "Key Monitor Scratch",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: profileID
        )
        env.selectSpace(scratchSpaceID)
    }

    override func tearDown() {
        PeekState.shared.dismiss()
        PeekState.shared.previewTabID = nil
        if let scratchSpaceID { env.deleteSpace(scratchSpaceID) }
        if let originalActiveSpaceID, env.space(originalActiveSpaceID) != nil {
            env.selectSpace(originalActiveSpaceID)
        }
        scratchSpaceID = nil
        originalActiveSpaceID = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func keyDown(
        for command: ShortcutCommandID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NSEvent {
        guard let binding = ShortcutRegistry.shared.binding(for: command) else {
            fatalError("\(command) has no effective binding, so no key event can be synthesised for it.")
        }
        return keyDown(key: binding.key, modifiers: binding.modifierFlags)
    }

    private func keyDown(key: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: 0
        ) else {
            fatalError("NSEvent.keyEvent returned nil for \(key) + \(modifiers.rawValue)")
        }
        return event
    }

    @discardableResult
    private func presentPeek(over sourceTabID: TabID) -> TabID {
        let url = URL(string: "https://example.com/peeked")!
        let previewTabID = env.makeDetachedTab(url: url)
        PeekState.shared.present(sourceTabID: sourceTabID, url: url)
        PeekState.shared.previewTabID = previewTabID
        return previewTabID
    }

    // MARK: - Consume vs pass through

    func testHandledCommandRunsAndConsumesTheEvent() {
        let wasVisible = env.isSidebarVisible
        env.isSidebarVisible = true

        let event = keyDown(for: .toggleSidebar)
        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: event), .toggleSidebar,
            "Test precondition: the synthesised event must resolve to .toggleSidebar."
        )

        let result = GlobalKeyEventMonitor.handle(event, in: env)

        XCTAssertNil(result, "A handled command must consume its key event; passing it on would let the menu fire it twice.")
        XCTAssertFalse(env.isSidebarVisible, "The key event reached the monitor but the sidebar never toggled.")

        env.isSidebarVisible = wasVisible
    }

    func testUnhandledCommandPassesTheEventThrough() {
        let event = keyDown(for: .findAndReplace)
        XCTAssertEqual(
            ShortcutRegistry.shared.command(matching: event), .findAndReplace,
            "Test precondition: the event must match a real registry entry — otherwise this would pass for the wrong reason."
        )

        let result = GlobalKeyEventMonitor.handle(event, in: env)

        XCTAssertTrue(
            result === event,
            "A registry-matched but unhandled command swallowed its key event. That is exactly the app-wide dead-key defect."
        )
    }

    func testOpenIntoMainWindowPassesThroughWhenThereIsNothingDetached() {
        XCTAssertNil(env.frontmostDetachedTabSource, "Test precondition: no Peek and no Little Orbit window.")

        let event = keyDown(for: .openIntoMainWindow)
        XCTAssertEqual(ShortcutRegistry.shared.command(matching: event), .openIntoMainWindow, "Test precondition")

        XCTAssertTrue(
            GlobalKeyEventMonitor.handle(event, in: env) === event,
            "⌘O was swallowed with nothing to promote, which is what killed every other claimant on that key."
        )
    }

    func testUnboundKeyCombinationIsNeverConsumed() {
        let event = keyDown(key: "\u{1}", modifiers: [.command, .control, .option, .shift])
        XCTAssertNil(ShortcutRegistry.shared.command(matching: event), "Test precondition: this combination must be unbound.")
        XCTAssertTrue(GlobalKeyEventMonitor.handle(event, in: env) === event)
    }

    // MARK: - The destructive case: ⌘W over a Peek

    func testCommandWWithPeekPresentedDismissesPeekAndDoesNotCloseTheTabUnderneath() {
        let spaceID = scratchSpaceID!
        let underlying = env.openTab(url: URL(string: "https://example.com/underlying")!, in: spaceID, section: .today, activate: true)
        XCTAssertEqual(env.activeTabID, underlying, "Test precondition: the underlying tab is the active one.")

        presentPeek(over: underlying)

        let result = GlobalKeyEventMonitor.handle(keyDown(for: .closeTabOrWindow), in: env)

        XCTAssertNil(result, "The Peek claimed ⌘W, so the event must be consumed rather than reaching anything else.")
        XCTAssertNil(PeekState.shared.activePreview, "⌘W did not dismiss the Peek.")
        XCTAssertNotNil(
            env.tab(underlying),
            "⌘W over a Peek destroyed the tab underneath it — the exact data loss this test exists to prevent."
        )
        XCTAssertEqual(env.tab(underlying)?.section, .today, "The underlying tab was archived out of Today by a ⌘W meant for the Peek.")
        XCTAssertTrue(
            env.todayTabs(in: spaceID).contains { $0.id == underlying },
            "The underlying tab is gone from its Space's Today list."
        )
        XCTAssertEqual(env.activeTabID, underlying, "Dismissing a Peek must not change which tab is active.")
    }

    func testCommandWWithNoPeekStillClosesTheActiveTab() {
        let spaceID = scratchSpaceID!
        let tabID = env.openTab(url: URL(string: "https://example.com/closable")!, in: spaceID, section: .today, activate: true)
        XCTAssertNil(PeekState.shared.activePreview, "Test precondition: no Peek.")

        let result = GlobalKeyEventMonitor.handle(keyDown(for: .closeTabOrWindow), in: env)

        XCTAssertNil(result, "⌘W is a real command with no Peek up; it must still consume its event.")
        XCTAssertEqual(env.tab(tabID)?.section, .archived, "⌘W no longer closes the active tab — functionality was lost, not fixed.")
        XCTAssertFalse(env.todayTabs(in: spaceID).contains { $0.id == tabID })
    }

    // MARK: - ⌘O over a Peek

    func testCommandOWithPeekPresentedPromotesThePreviewIntoTheActiveSpace() {
        let spaceID = scratchSpaceID!
        let source = env.openTab(url: URL(string: "https://example.com/source")!, in: spaceID, section: .pinned, activate: true)
        let previewTabID = presentPeek(over: source)

        let result = GlobalKeyEventMonitor.handle(keyDown(for: .openIntoMainWindow), in: env)

        XCTAssertNil(result, "With a promotable Peek up, ⌘O is handled and must consume its event.")
        XCTAssertNil(PeekState.shared.activePreview, "Promoting the preview must dismiss the Peek.")
        XCTAssertNil(
            PeekState.shared.previewTabID,
            "Ownership of the preview tab must be released, or PeekPanelView's teardown deletes the tab that was just promoted."
        )
        XCTAssertNotNil(env.tab(previewTabID), "The promoted preview tab no longer exists.")
        XCTAssertTrue(
            env.todayTabs(in: spaceID).contains { $0.id == previewTabID },
            "⌘O did not land the preview in the active Space's Today list."
        )
        XCTAssertEqual(env.activeTabID, previewTabID, "The promoted tab should become the active one.")
        XCTAssertEqual(env.tab(source)?.section, .pinned, "The Peek's source tab must be left exactly where it was.")
    }

    // MARK: - ⌘⇧O Space picker

    // Menu built and its item invoked exactly as NSMenu's tracking loop would,
    // so the picking path is proven without a modal tracking loop.
    func testSpacePickerMenuItemPromotesThePreviewIntoTheChosenSpace() {
        let spaceID = scratchSpaceID!
        let destinationID = env.createSpace(
            name: "Picker Destination",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: env.createDefaultProfileIfNeeded()
        )
        env.selectSpace(spaceID)

        let source = env.openTab(url: URL(string: "https://example.com/source")!, in: spaceID, section: .pinned, activate: true)
        let previewTabID = presentPeek(over: source)

        guard let menu = env.spacePickerMenuForFrontmostDetachedTab() else {
            return XCTFail("⌘⇧O built no Space picker even though a Peek with a preview tab is presented.")
        }
        XCTAssertEqual(
            menu.items.count, env.state.spaces.count,
            "The picker must offer every Space. Offered: \(menu.items.map(\.title))"
        )
        guard let item = menu.items.first(where: { $0.title == "Picker Destination" }) else {
            return XCTFail("No item for the destination Space. Offered: \(menu.items.map(\.title))")
        }
        guard let target = item.target, let action = item.action else {
            return XCTFail("The picker item has no target/action wired, so a real click could never invoke it.")
        }

        _ = target.perform(action, with: item)

        XCTAssertNil(PeekState.shared.activePreview, "Picking a Space must dismiss the Peek.")
        XCTAssertNil(PeekState.shared.previewTabID, "Ownership of the preview tab must be released on promotion.")
        XCTAssertEqual(
            env.tab(previewTabID)?.spaceID, destinationID,
            "The preview was not moved into the Space the user picked — this is the destinationSpaceID: parameter no caller ever passed."
        )
        XCTAssertTrue(
            env.todayTabs(in: destinationID).contains { $0.id == previewTabID },
            "The promoted tab is not in the chosen Space's Today list."
        )

        env.deleteSpace(destinationID)
    }

    func testSpacePickerIsAbsentAndKeyPassesThroughWithNothingDetached() {
        XCTAssertNil(env.frontmostDetachedTabSource, "Test precondition: no Peek and no Little Orbit window.")
        XCTAssertNil(env.spacePickerMenuForFrontmostDetachedTab())

        let event = keyDown(for: .openInSpacePicker)
        XCTAssertEqual(ShortcutRegistry.shared.command(matching: event), .openInSpacePicker, "Test precondition")
        XCTAssertTrue(GlobalKeyEventMonitor.handle(event, in: env) === event, "⌘⇧O was swallowed with no picker to show.")
    }
}
