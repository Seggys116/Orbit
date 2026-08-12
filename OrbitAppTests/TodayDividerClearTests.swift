import AppKit
import XCTest
@testable import Orbit

@MainActor
final class TodayDividerClearTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

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

    private func seedTwoSpacesWithTabs() -> (SpaceID, SpaceID) {
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        state.profiles = [profile]
        let first = Space(name: "Work", profileID: profile.id)
        let second = Space(name: "Home", profileID: profile.id)
        state.spaces = [first, second]
        state.activeSpaceID = first.id
        env.state = state

        env.openTab(url: URL(string: "https://example.com/one")!, in: first.id)
        env.openTab(url: URL(string: "https://example.com/two")!, in: first.id)
        env.openTab(url: URL(string: "https://example.com/other")!, in: second.id)

        if let toPin = env.todayTabs(in: first.id).first {
            env.pinTab(toPin.id)
        }
        return (first.id, second.id)
    }

    // MARK: - 1. The action really does something

    func test_clearAction_archivesEveryTodayTabInTheSpace() {
        let (first, _) = seedTwoSpacesWithTabs()
        XCTAssertFalse(env.todayTabs(in: first).isEmpty, "Precondition: the fixture must actually put Today tabs in this Space, or this test proves nothing.")

        TodayDividerClearAction.perform(spaceID: first, in: env)

        XCTAssertTrue(
            env.todayTabs(in: first).isEmpty,
            "The divider's Clear must archive every Today tab in its Space — this is the whole verb of the control."
        )
    }

    func test_clearAction_leavesPinnedTabsAlone() {
        let (first, _) = seedTwoSpacesWithTabs()
        let pinnedBefore = env.pinnedNodes(in: first).flatMap(\.allTabIDs)
        XCTAssertFalse(pinnedBefore.isEmpty, "Precondition: the fixture must actually pin a tab.")

        TodayDividerClearAction.perform(spaceID: first, in: env)

        XCTAssertEqual(
            env.pinnedNodes(in: first).flatMap(\.allTabIDs),
            pinnedBefore,
            "Clear is the *Today* divider's control. Arc's own tooltip for it is \"Clear Today tabs\" and its Help Center says Tidy/Clear \"only organizes Today Tabs\" — the Pinned tree must be untouched."
        )
    }

    func test_clearAction_leavesOtherSpacesAlone() {
        let (first, second) = seedTwoSpacesWithTabs()
        let otherBefore = env.todayTabs(in: second).map(\.id)
        XCTAssertFalse(otherBefore.isEmpty, "Precondition: the fixture must put a Today tab in the second Space.")

        TodayDividerClearAction.perform(spaceID: first, in: env)

        XCTAssertEqual(
            env.todayTabs(in: second).map(\.id),
            otherBefore,
            "Clear is scoped to one Space — Arc's own string comment for this button is \"Clear unpinned tabs in this space\". Clearing Work must not touch Home."
        )
    }

    // MARK: - 2. A real click really reaches that action

    func test_mouseDown_onTheControlsClickCatcher_clearsTodayTabs() {
        let (first, _) = seedTwoSpacesWithTabs()
        XCTAssertFalse(env.todayTabs(in: first).isEmpty, "Precondition.")

        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 40, height: 16))
        view.action = { TodayDividerClearAction.perform(spaceID: first, in: self.env) }

        view.mouseDown(with: mouseDownEvent())

        XCTAssertTrue(
            env.todayTabs(in: first).isEmpty,
            "A real mouseDown on the control's real click-catching NSView must run the clear. If this fails the control is dead in the app, which is the failure mode this codebase has shipped three times."
        )
    }

    func test_clickCatcher_isTheHitTestTargetForItsOwnBoundsAndNothingOutsideThem() {
        let view = OrbitActionButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 40, height: 16))
        XCTAssertIdentical(
            view.hitTest(NSPoint(x: 20, y: 8)),
            view,
            "The control must claim clicks inside its own bounds, or a neighbouring representable can swallow them — a failure mode this repo has shipped (SpaceSwipeGestureCatcher)."
        )
        XCTAssertNil(
            view.hitTest(NSPoint(x: 200, y: 8)),
            "It must not claim clicks outside its bounds, or it would swallow the divider rule and the rows beside it."
        )
    }

    // MARK: - 3. The shipping views really use that mechanism

    private func source(of relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_theSidebarDividerIsBuiltFromTheAppKitClickCatcher_notAPlainSwiftUIButton() throws {
        let source = try source(of: "Orbit/UI/Sidebar/TodayDividerRow.swift")

        let marker = "private var clearControl: some View {"
        let start = try XCTUnwrap(
            source.range(of: marker),
            "Could not find `clearControl` in TodayDividerRow.swift — this guard's own source walk is broken, or the property was renamed."
        )
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(
            rest.range(of: "\n    }\n"),
            "Could not find the end of `clearControl` — this guard's own source walk is broken."
        )
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(
            body.contains("OrbitNSActionButton"),
            "TodayDividerRow.clearControl must be built with OrbitNSActionButton (a real NSView.mouseDown). See Orbit/UI/Sidebar/OrbitNSActionButton.swift's header for why a plain SwiftUI Button is not trusted to deliver this click in Orbit's hosting configuration."
        )
        XCTAssertTrue(
            body.contains("TodayDividerClearAction.perform"),
            "TodayDividerRow.clearControl must run TodayDividerClearAction.perform — the exact action sections 1 and 2 assert against. An inlined closure here would make those tests prove nothing about the shipping control."
        )
    }

    func test_bothSurfacesRenderTheOneSharedDivider() throws {
        let sidebar = try source(of: "Orbit/UI/Sidebar/SidebarView.swift")
        XCTAssertTrue(
            sidebar.contains("TodayDividerRow(spaceID: space.id, theme: space.theme)"),
            "SidebarView must mount the shared TodayDividerRow between Pinned and Today. A bare Rectangle here is the exact gap this change closed — Arc's divider carries a Clear control (refs/reference/arc-hover-preview-pinned-tab.png, viewed)."
        )

        let manageSpaces = try source(of: "Orbit/UI/Spaces/ManageSpacesView.swift")
        XCTAssertTrue(
            manageSpaces.contains("TodayDividerRow(spaceID: spaceID"),
            "ManageSpacesView must mount the same shared TodayDividerRow. It used to carry its own private copy, which is how the two surfaces came to disagree about what Arc's divider looks like."
        )
    }
}
