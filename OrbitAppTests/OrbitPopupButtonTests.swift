import AppKit
import SwiftUI
import XCTest
@testable import Orbit

// MARK: - Shared helpers

private final class SelectionBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
    var binding: Binding<Value> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

@MainActor
private func mouseDownEvent(at point: NSPoint = NSPoint(x: 5, y: 5)) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )!
}

@MainActor
private func keyDownEvent(characters: String) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

@MainActor
private func invoke(_ item: NSMenuItem, file: StaticString = #filePath, line: UInt = #line) {
    guard let target = item.target, let action = item.action else {
        XCTFail("Menu item \"\(item.title)\" has no target/action wired — a real click could never invoke it.", file: file, line: line)
        return
    }
    _ = target.perform(action, with: item)
}

// MARK: - The click path

@MainActor
final class OrbitPopupButtonClickTests: XCTestCase {

    private let policies: [String] = ["Never", "After 12 Hours", "After 24 Hours", "After 7 Days"]

    private func makeControl(
        options: [String],
        box: SelectionBox<String>
    ) -> (host: OrbitPopupButtonMenuHostView, presented: () -> NSMenu?) {
        let button = OrbitPopupButton(
            options: options,
            label: { $0 },
            selection: box.binding,
            accessibilityLabel: "Archive tabs after"
        )
        let host = OrbitPopupButtonMenuHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        host.menuProvider = button.buildMenu
        var presented: NSMenu?
        host.presentMenu = { menu, _ in presented = menu }
        return (host, { presented })
    }

    func test_click_presentsAMenuContainingEveryOptionInOrder() {
        let box = SelectionBox("After 12 Hours")
        let (host, presented) = makeControl(options: policies, box: box)

        host.mouseDown(with: mouseDownEvent())

        guard let menu = presented() else {
            XCTFail("Clicking OrbitPopupButton presented nothing — this is the dead-control bug itself.")
            return
        }
        XCTAssertEqual(menu.items.map(\.title), policies, "Every option passed to OrbitPopupButton must reach the presented menu, in order.")
    }

    func test_selectingAnOption_writesThroughTheBinding() {
        let box = SelectionBox("After 12 Hours")
        let (host, presented) = makeControl(options: policies, box: box)

        host.mouseDown(with: mouseDownEvent())
        guard let menu = presented(), let item = menu.items.first(where: { $0.title == "After 7 Days" }) else {
            XCTFail("The presented menu did not contain the option being selected.")
            return
        }

        XCTAssertEqual(box.value, "After 12 Hours", "test precondition: selection has not changed yet")
        invoke(item)
        XCTAssertEqual(box.value, "After 7 Days", "Picking a row must write the new value through the Binding — this is the whole point of the control.")
    }

    func test_selectingTwiceInARow_writesBothValuesThrough() {
        let box = SelectionBox("Never")
        let (host, presented) = makeControl(options: policies, box: box)

        host.mouseDown(with: mouseDownEvent())
        guard let first = presented()?.items.first(where: { $0.title == "After 24 Hours" }) else {
            XCTFail("First presentation did not contain the option being selected.")
            return
        }
        invoke(first)
        XCTAssertEqual(box.value, "After 24 Hours")

        host.mouseDown(with: mouseDownEvent())
        guard let second = presented()?.items.first(where: { $0.title == "Never" }) else {
            XCTFail("Second presentation did not contain the option being selected.")
            return
        }
        invoke(second)
        XCTAssertEqual(box.value, "Never", "A second pick must write through too — the menu is rebuilt per click, not captured once.")
    }

    func test_checkmarkMarksOnlyTheCurrentSelectionAndMovesWithIt() {
        let box = SelectionBox("After 12 Hours")
        let (host, presented) = makeControl(options: policies, box: box)

        host.mouseDown(with: mouseDownEvent())
        guard let menu = presented() else {
            XCTFail("Clicking OrbitPopupButton presented nothing.")
            return
        }
        let checkedTitles = menu.items.filter { $0.state == .on }.map(\.title)
        XCTAssertEqual(checkedTitles, ["After 12 Hours"], "Exactly the selected option must be checked.")

        guard let item = menu.items.first(where: { $0.title == "Never" }) else {
            XCTFail("The presented menu did not contain the option being selected.")
            return
        }
        invoke(item)

        host.mouseDown(with: mouseDownEvent())
        guard let reopened = presented() else {
            XCTFail("Re-opening OrbitPopupButton presented nothing.")
            return
        }
        XCTAssertEqual(
            reopened.items.filter { $0.state == .on }.map(\.title),
            ["Never"],
            "After picking a new option the checkmark must follow it, not stay on the old one."
        )
    }

    func test_everyPresentedRowIsEnabledAndHasAWiredAction() {
        let box = SelectionBox("Never")
        let (host, presented) = makeControl(options: policies, box: box)

        host.mouseDown(with: mouseDownEvent())
        guard let menu = presented() else {
            XCTFail("Clicking OrbitPopupButton presented nothing.")
            return
        }
        for item in menu.items {
            XCTAssertTrue(item.isEnabled, "\"\(item.title)\" is disabled and could never be picked.")
            XCTAssertNotNil(item.target, "\"\(item.title)\" has no target.")
            XCTAssertNotNil(item.action, "\"\(item.title)\" has no action.")
        }
    }

    func test_optionalOptions_selectingTheNilRowWritesNilThroughTheBinding() {
        let someID = UUID()
        let box = SelectionBox<UUID?>(someID)
        let button = OrbitPopupButton(
            options: [UUID?.none, UUID?.some(someID)],
            label: { $0 == nil ? "Most Recent Space" : "A Space" },
            selection: box.binding,
            accessibilityLabel: "Destination"
        )
        let host = OrbitPopupButtonMenuHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        host.menuProvider = button.buildMenu
        var presented: NSMenu?
        host.presentMenu = { menu, _ in presented = menu }

        host.mouseDown(with: mouseDownEvent())
        guard let menu = presented else {
            XCTFail("Clicking an Optional-backed OrbitPopupButton presented nothing.")
            return
        }
        XCTAssertEqual(menu.items.map(\.title), ["Most Recent Space", "A Space"])
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["A Space"], "The checkmark must sit on the non-nil selection.")

        invoke(menu.items[0])
        XCTAssertNil(box.value, "Selecting the nil row must write nil through the Binding.")
    }

    func test_noOptions_presentsAnEmptyMenuAndDoesNotCrash() {
        let box = SelectionBox("Never")
        let (host, presented) = makeControl(options: [], box: box)

        host.mouseDown(with: mouseDownEvent())

        XCTAssertEqual(presented()?.items.count, 0, "An empty option list must still present (an empty) menu.")
        XCTAssertEqual(box.value, "Never", "Nothing may be written through the binding when there was nothing to pick.")
    }
}

// MARK: - The keyboard path

@MainActor
final class OrbitPopupButtonKeyboardTests: XCTestCase {

    private func makeHost(box: SelectionBox<String>) -> (OrbitPopupButtonMenuHostView, () -> NSMenu?) {
        let button = OrbitPopupButton(
            options: ["Never", "After 12 Hours"],
            label: { $0 },
            selection: box.binding,
            accessibilityLabel: "Archive tabs after"
        )
        let host = OrbitPopupButtonMenuHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        host.menuProvider = button.buildMenu
        var presented: NSMenu?
        host.presentMenu = { menu, _ in presented = menu }
        return (host, { presented })
    }

    func test_spaceKey_opensTheMenuAndItsRowsStillWriteThrough() {
        let box = SelectionBox("Never")
        let (host, presented) = makeHost(box: box)

        host.keyDown(with: keyDownEvent(characters: " "))

        guard let menu = presented(), let item = menu.items.first(where: { $0.title == "After 12 Hours" }) else {
            XCTFail("Space did not open the menu — the keyboard path is dead.")
            return
        }
        invoke(item)
        XCTAssertEqual(box.value, "After 12 Hours", "A keyboard-opened menu's rows must write through exactly as a clicked one's do.")
    }

    func test_returnKey_opensTheMenu() {
        let box = SelectionBox("Never")
        let (host, presented) = makeHost(box: box)

        host.keyDown(with: keyDownEvent(characters: "\r"))

        XCTAssertNotNil(presented(), "Return did not open the menu.")
    }

    func test_unrelatedKey_doesNotOpenTheMenu() {
        let box = SelectionBox("Never")
        let (host, presented) = makeHost(box: box)

        host.keyDown(with: keyDownEvent(characters: "x"))

        XCTAssertNil(presented(), "An unrelated key must not open the popup's menu.")
    }

    func test_hostViewOptsIntoKeyboardFocus() {
        let host = OrbitPopupButtonMenuHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        XCTAssertTrue(host.acceptsFirstResponder)
        XCTAssertTrue(host.canBecomeKeyView)
    }

    func test_hostViewInheritsClickBehaviourFromTheProvenBaseClass() {
        let host = OrbitPopupButtonMenuHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
        XCTAssertTrue(host.hitTest(NSPoint(x: 10, y: 10)) === host, "The catcher must claim clicks inside its own bounds.")
    }
}

// MARK: - Real call sites, driven through their real state

@MainActor
final class OrbitPopupButtonCallSiteTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    func test_profilesPane_archivePolicyPopup_clickThenPick_changesThePolicyOnTheProfile() {
        let profileID = env.createDefaultProfileIfNeeded()
        let spaceA = env.createSpace(name: "Popup Test A", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        let spaceB = env.createSpace(name: "Popup Test B", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID)
        defer {
            env.state.spaces.removeAll { $0.id == spaceA || $0.id == spaceB }
        }
        let startingPolicy = env.state.profiles.first { $0.id == profileID }?.archivePolicy ?? .after12Hours
        let target: ArchivePolicy = ArchivePolicy.allCases.first { $0 != startingPolicy } ?? .never

        let button = OrbitPopupButton(
            options: ArchivePolicy.allCases,
            label: { $0.menuTitle },
            selection: Binding(
                get: { startingPolicy },
                set: { newPolicy in self.env.store.setArchivePolicy(newPolicy, forProfile: profileID) }
            ),
            accessibilityLabel: "Archive tabs after"
        )

        let host = OrbitPopupButtonMenuHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        host.menuProvider = button.buildMenu
        var presented: NSMenu?
        host.presentMenu = { menu, _ in presented = menu }

        host.mouseDown(with: mouseDownEvent())
        guard let menu = presented else {
            XCTFail("The Profiles pane's archive-policy popup presented nothing when clicked.")
            return
        }
        XCTAssertEqual(menu.items.map(\.title), ArchivePolicy.allCases.map(\.menuTitle), "Every archive policy must be offered.")

        guard let item = menu.items.first(where: { $0.title == target.menuTitle }) else {
            XCTFail("The presented menu did not contain \(target.menuTitle).")
            return
        }
        invoke(item)

        XCTAssertEqual(env.state.profiles.first { $0.id == profileID }?.archivePolicy, target,
                       "Picking a policy must write it onto the Profile the pane is showing.")
        XCTAssertEqual(env.store.archivePolicy(forSpace: spaceA), target,
                       "Every Space on that Profile must resolve to the new policy…")
        XCTAssertEqual(env.store.archivePolicy(forSpace: spaceB), target,
                       "…including a second one, without the value being copied onto either Space.")
        XCTAssertNil(env.state.spaces.first { $0.id == spaceA }?.legacyArchivePolicy,
                     "The retired per-Space carrier must never be written by the picker.")
    }

    func test_profilesPane_addSpacePopup_clickThenPick_movesTheSpaceOntoTheProfile() {
        let originalProfileID = env.createDefaultProfileIfNeeded()
        let destinationID = env.store.createProfile(name: "Add-a-Space Destination Profile")
        let spaceID = env.createSpace(name: "Add-a-Space Popup Test", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: originalProfileID)
        defer {
            env.state.spaces.removeAll { $0.id == spaceID }
            env.state.profiles.removeAll { $0.id == destinationID }
        }

        guard let destination = env.state.profiles.first(where: { $0.id == destinationID }) else {
            XCTFail("createProfile did not add the destination Profile to the store.")
            return
        }

        let candidates = env.spaces.filter { $0.profileID != destinationID }
        let button = OrbitPopupButton(
            options: candidates.map { Optional($0.id) },
            label: { spaceID in spaceID.flatMap { id in self.env.space(id)?.name } ?? "Choose a Space…" },
            selection: Binding<SpaceID?>(
                get: { nil },
                set: { newValue in
                    guard let spaceID = newValue else { return }
                    self.env.store.setProfile(destinationID, forSpace: spaceID)
                }
            ),
            accessibilityLabel: "Add a Space to \(destination.name)"
        )

        let host = OrbitPopupButtonMenuHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        host.menuProvider = button.buildMenu
        var presented: NSMenu?
        host.presentMenu = { menu, _ in presented = menu }

        host.mouseDown(with: mouseDownEvent())
        guard let menu = presented else {
            XCTFail("Settings → Profiles' \"Add a Space\" popup presented nothing when clicked.")
            return
        }
        XCTAssertEqual(menu.items.map(\.title), candidates.map(\.name), "Every candidate Space must be offered.")

        guard let item = menu.items.first(where: { $0.title == "Add-a-Space Popup Test" }) else {
            XCTFail("The presented menu did not contain the test Space.")
            return
        }
        invoke(item)

        XCTAssertEqual(
            env.space(spaceID)?.profileID,
            destination.id,
            "Picking a Space from \"Add a Space\" must move it onto the Profile through the real store."
        )
    }
}

// MARK: - Notes' heading menu (the other converted click-to-open Menu)

@MainActor
final class NotesHeadingMenuTests: XCTestCase {

    private func makeController() -> (RichTextController, NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        textView.string = "A paragraph of note text."
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let controller = RichTextController()
        controller.textView = textView
        return (controller, textView)
    }

    func test_click_presentsAllFourHeadingOptionsInOrder() {
        let (controller, _) = makeController()
        let host = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
        host.menuProvider = { NotesHeadingOption.buildNSMenu(for: controller) }
        var presented: NSMenu?
        host.presentMenu = { menu, _ in presented = menu }

        host.mouseDown(with: mouseDownEvent())

        XCTAssertEqual(
            presented?.items.map(\.title),
            NotesHeadingOption.allCases.map(\.title),
            "Clicking the Notes heading control must present the same four options the old SwiftUI Menu offered."
        )
    }

    func test_pickingHeading1_makesTheParagraphFontLargerAndBoldThanBody() {
        let (controller, textView) = makeController()
        let host = OrbitMenuButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
        host.menuProvider = { NotesHeadingOption.buildNSMenu(for: controller) }
        var presented: NSMenu?
        host.presentMenu = { menu, _ in presented = menu }

        func paragraphFont() -> NSFont? {
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        }

        host.mouseDown(with: mouseDownEvent())
        guard let bodyItem = presented?.items.first(where: { $0.title == NotesHeadingOption.body.title }) else {
            XCTFail("The presented menu did not contain the Body option.")
            return
        }
        invoke(bodyItem)
        guard let bodyFont = paragraphFont() else {
            XCTFail("Applying Body left no font attribute on the paragraph at all.")
            return
        }

        host.mouseDown(with: mouseDownEvent())
        guard let headingItem = presented?.items.first(where: { $0.title == NotesHeadingOption.heading1.title }) else {
            XCTFail("The presented menu did not contain the Heading 1 option.")
            return
        }
        invoke(headingItem)
        guard let headingFont = paragraphFont() else {
            XCTFail("Applying Heading 1 left no font attribute on the paragraph at all.")
            return
        }

        XCTAssertGreaterThan(headingFont.pointSize, bodyFont.pointSize, "Heading 1 must render larger than Body.")
        XCTAssertTrue(
            NSFontManager.shared.traits(of: headingFont).contains(.boldFontMask),
            "Heading 1 must be bold; Body is not."
        )
        XCTAssertFalse(
            NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask),
            "test precondition: Body text is not bold."
        )
    }

    func test_headingLevelsDescendInSize() {
        let (controller, textView) = makeController()
        let menuFor = { NotesHeadingOption.buildNSMenu(for: controller) }

        func applyThenMeasure(_ option: NotesHeadingOption) -> CGFloat? {
            let menu = menuFor()
            guard let item = menu.items.first(where: { $0.title == option.title }) else {
                XCTFail("Menu did not contain \(option.title).")
                return nil
            }
            invoke(item)
            return (textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        }

        guard let h1 = applyThenMeasure(.heading1),
              let h2 = applyThenMeasure(.heading2),
              let h3 = applyThenMeasure(.heading3) else { return }

        XCTAssertGreaterThan(h1, h2, "Heading 1 must be larger than Heading 2.")
        XCTAssertGreaterThan(h2, h3, "Heading 2 must be larger than Heading 3.")
    }
}
