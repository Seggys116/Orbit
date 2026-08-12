//  Proof that every control in Settings -> Links changes what the app actually does:
//  drives the real production write paths and asserts against the real consumers.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class LinksSettingsWiringTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "OrbitAppTests-LinksSettings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        PeekSettings.defaults = defaults
        LittleOrbitSettings.defaults = defaults
        RoutingDefaults.defaults = defaults
    }

    override func tearDown() {
        PeekSettings.defaults = .standard
        LittleOrbitSettings.defaults = .standard
        RoutingDefaults.defaults = .standard
        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        PeekState.shared.activePreview = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private var firstSpaceID: SpaceID {
        if let id = env.spaces.first?.id { return id }
        return env.createSpace(
            name: "Test Space",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: env.createDefaultProfileIfNeeded()
        )
    }

    @discardableResult
    private func makeTab(section: Orbit.TabSection, url: String = "https://source.example.com") -> TabID {
        let tab = Tab(spaceID: firstSpaceID, section: section, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        return tab.id
    }

    private func makeAttachedTab(section: Orbit.TabSection) -> (TabID, MockWebContents) {
        let tabID = makeTab(section: section)
        let mock = MockWebContents()
        env._test_attachWebContents(mock, for: tabID)
        return (tabID, mock)
    }

    private var editor: AirTrafficControlEditor {
        AirTrafficControlEditor(
            rules: Binding(
                get: { self.env.state.routingRules },
                set: { self.env.state.routingRules = $0 }
            )
        )
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - 1. Automatic Peek: the switch changes what shouldPeek returns

    func test_automaticPeekSwitch_changesWhatShouldPeekReturnsForAPinnedTab() {
        let pinned = makeTab(section: .pinned)

        LinksSettingsActions.setAutomaticPeek(true)
        XCTAssertTrue(
            env.shouldPeek(sourceTabID: pinned, modifiers: []),
            "With the Links pane's automatic-Peek switch on, a link click in a Pinned tab must Peek."
        )

        LinksSettingsActions.setAutomaticPeek(false)
        XCTAssertFalse(
            env.shouldPeek(sourceTabID: pinned, modifiers: []),
            "Turning the automatic-Peek switch off must stop a Pinned tab from Peeking — this is the wiring refs/ARC_PARITY_GAPS.md §14 item 6 recorded as missing."
        )

        let favorite = makeTab(section: .favorite)
        XCTAssertFalse(env.shouldPeek(sourceTabID: favorite, modifiers: []))
        LinksSettingsActions.setAutomaticPeek(true)
        XCTAssertTrue(env.shouldPeek(sourceTabID: favorite, modifiers: []))
    }

    func test_automaticPeekSwitch_changesTheRealNavigationDecisionForAPinnedTab() {
        let (_, mock) = makeAttachedTab(section: .pinned)
        let target = url("https://elsewhere.example.com/article")

        LinksSettingsActions.setAutomaticPeek(true)
        PeekState.shared.activePreview = nil
        let allowedWhenOn = env.webContents(mock, shouldAllowNavigationTo: target, kind: .linkActivated, isMainFrame: true)
        XCTAssertFalse(allowedWhenOn, "With automatic Peek on, the navigation must be suppressed in favour of the Peek panel.")
        XCTAssertEqual(PeekState.shared.activePreview?.url, target, "The suppressed navigation must actually have opened a Peek for that URL.")

        LinksSettingsActions.setAutomaticPeek(false)
        PeekState.shared.activePreview = nil
        let allowedWhenOff = env.webContents(mock, shouldAllowNavigationTo: target, kind: .linkActivated, isMainFrame: true)
        XCTAssertTrue(allowedWhenOff, "With automatic Peek off, the click must navigate normally.")
        XCTAssertNil(PeekState.shared.activePreview, "No Peek may be presented once the switch is off.")
    }

    func test_automaticPeekSwitch_keepsTheLegacySiteControlKeyInStep() {
        LinksSettingsActions.setAutomaticPeek(false)
        XCTAssertTrue(
            defaults.bool(forKey: "OrbitDisableAutoPeek"),
            "Disabling automatic Peek must set the legacy key SiteControlPopoverView reads, or the two surfaces disagree."
        )

        LinksSettingsActions.setAutomaticPeek(true)
        XCTAssertFalse(defaults.bool(forKey: "OrbitDisableAutoPeek"))
    }

    // MARK: - 2. Shift-click Peek: the switch changes the .today branch

    func test_shiftClickPeekSwitch_changesWhatTheTodayBranchDoes() {
        let today = makeTab(section: .today)

        LinksSettingsActions.setShiftClickPeek(true)
        XCTAssertTrue(
            env.shouldPeek(sourceTabID: today, modifiers: [.shift]),
            "With the Shift-Peek switch on, Shift+click in a Today tab must Peek."
        )
        XCTAssertFalse(
            env.shouldPeek(sourceTabID: today, modifiers: []),
            "Without Shift held, a Today tab must not Peek regardless of the switch."
        )

        LinksSettingsActions.setShiftClickPeek(false)
        XCTAssertFalse(
            env.shouldPeek(sourceTabID: today, modifiers: [.shift]),
            "Turning the Shift-Peek switch off must stop Shift+click from Peeking — before this setting existed that branch was unconditional."
        )
    }

    func test_theTwoPeekSwitchesDoNotGateEachOther() {
        let today = makeTab(section: .today)
        let pinned = makeTab(section: .pinned)

        LinksSettingsActions.setShiftClickPeek(true)
        LinksSettingsActions.setAutomaticPeek(false)
        XCTAssertTrue(env.shouldPeek(sourceTabID: today, modifiers: [.shift]))
        XCTAssertFalse(env.shouldPeek(sourceTabID: pinned, modifiers: [.shift]))

        LinksSettingsActions.setShiftClickPeek(false)
        LinksSettingsActions.setAutomaticPeek(true)
        XCTAssertFalse(env.shouldPeek(sourceTabID: today, modifiers: [.shift]))
        XCTAssertTrue(env.shouldPeek(sourceTabID: pinned, modifiers: []))
    }

    // MARK: - 3. The ⌥⌘ Little Orbit switch

    func test_modifierClickSwitch_gatesTheOptionCommandLittleOrbitDiversion() {
        LinksSettingsActions.setOpensOnModifierClick(false)
        XCTAssertFalse(
            env.shouldOpenInLittleOrbit(modifiers: [.option, .command]),
            "With the switch off, ⌥⌘ must not divert a link click."
        )

        LinksSettingsActions.setOpensOnModifierClick(true)
        XCTAssertTrue(
            env.shouldOpenInLittleOrbit(modifiers: [.option, .command]),
            "With the switch on, ⌥⌘ must divert the click into Little Orbit — before this, openFromExternalActivation had zero call sites."
        )
        XCTAssertFalse(env.shouldOpenInLittleOrbit(modifiers: [.command]), "⌘ alone is not ⌥⌘.")
        XCTAssertFalse(env.shouldOpenInLittleOrbit(modifiers: [.option]), "⌥ alone is not ⌥⌘.")
        XCTAssertFalse(env.shouldOpenInLittleOrbit(modifiers: [.shift]), "Shift is the Peek modifier, not the Little Orbit one.")
    }

    // MARK: - 4. Editing a route in place

    func test_editingAPatternInPlace_mutatesTheRuleAndChangesWhatMatches() {
        let ruleID = editor.addRoute(defaultDestination: .space(firstSpaceID))
        defer { editor.remove(ruleID) }

        editor.pattern(for: ruleID).wrappedValue = "github.com"

        XCTAssertEqual(env.state.routingRules.first { $0.id == ruleID }?.pattern, "github.com", "Typing in the route's field must write straight through to env.state.routingRules.")
        XCTAssertEqual(env.matchingRoutingRule(for: url("https://github.com/anthropics"))?.id, ruleID, "The edited rule must now match a real URL through the real matcher.")
        XCTAssertNil(env.matchingRoutingRule(for: url("https://example.com/x")), "It must not match an unrelated URL.")

        // Deliberately not figma.com: OrbitState.demo already ships a rule with that
        // pattern, which would let this pass against the demo rule instead of this one.
        editor.pattern(for: ruleID).wrappedValue = "linear.app"
        XCTAssertNil(env.matchingRoutingRule(for: url("https://github.com/anthropics")), "After editing the pattern, the old URL must stop matching.")
        XCTAssertEqual(env.matchingRoutingRule(for: url("https://linear.app/issue/1"))?.id, ruleID)
    }

    func test_editingTheMatchTypeInPlace_switchesBetweenContainsAndIsEqualTo() {
        let ruleID = editor.addRoute(defaultDestination: .space(firstSpaceID))
        defer { editor.remove(ruleID) }
        editor.pattern(for: ruleID).wrappedValue = "https://cooking.nytimes.com/"

        editor.matchType(for: ruleID).wrappedValue = .isEqualTo
        XCTAssertEqual(editor.matchType(for: ruleID).wrappedValue, .isEqualTo)
        XCTAssertEqual(
            editor.pattern(for: ruleID).wrappedValue,
            "https://cooking.nytimes.com/",
            "Switching match type must not disturb what the user typed — the `=` sentinel is storage, not content."
        )
        XCTAssertEqual(env.matchingRoutingRule(for: url("https://cooking.nytimes.com/"))?.id, ruleID, "Is-equal-to must match the whole URL exactly.")
        XCTAssertNil(env.matchingRoutingRule(for: url("https://cooking.nytimes.com/recipes/1")), "Is-equal-to must not match a longer URL.")

        editor.matchType(for: ruleID).wrappedValue = .contains
        XCTAssertEqual(editor.matchType(for: ruleID).wrappedValue, .contains)
        editor.pattern(for: ruleID).wrappedValue = "cooking.nytimes.com"
        XCTAssertEqual(env.matchingRoutingRule(for: url("https://cooking.nytimes.com/recipes/1"))?.id, ruleID, "Contains must match a URL whose host contains the pattern.")
    }

    func test_editingTheDestinationInPlace_changesWhereAMatchedLinkGoes() {
        let spaceID = firstSpaceID
        let secondSpaceID = env.createSpace(
            name: "Routing Destination",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: env.space(spaceID)?.profileID ?? env.createDefaultProfileIfNeeded()
        )
        defer { env.deleteSpace(secondSpaceID) }

        let ruleID = editor.addRoute(defaultDestination: .space(spaceID))
        defer { editor.remove(ruleID) }
        editor.pattern(for: ruleID).wrappedValue = "routed.example.com"

        editor.destination(for: ruleID).wrappedValue = .space(secondSpaceID)
        XCTAssertEqual(env.state.routingRules.first { $0.id == ruleID }?.destination, .space(secondSpaceID))

        // createSpace makes the new Space active; put the original back in front, or
        // "routed to the chosen Space" and "routed to the active Space" are indistinguishable.
        env.selectSpace(spaceID)

        let before = env.space(secondSpaceID)?.today.count ?? 0
        let beforeOriginal = env.space(spaceID)?.today.count ?? 0
        env.handleExternalOpen(url: url("https://routed.example.com/page"))
        XCTAssertEqual(
            env.space(secondSpaceID)?.today.count,
            before + 1,
            "A link matching the edited rule must open in the Space the destination popup was just set to."
        )
        XCTAssertEqual(env.space(spaceID)?.today.count, beforeOriginal, "...and not in the Space that happens to be active.")
    }

    // Regression guard: the "Most Recent Space" option used to create a .littleOrbit route.
    func test_choosingMostRecentSpace_producesMostRecentSpaceNotLittleOrbit() {
        let ruleID = editor.addRoute(defaultDestination: .space(firstSpaceID))
        defer { editor.remove(ruleID) }

        editor.destination(for: ruleID).wrappedValue = .mostRecentSpace

        let stored = env.state.routingRules.first { $0.id == ruleID }?.destination
        XCTAssertEqual(stored, .mostRecentSpace, "Choosing 'Most Recent Space' must store .mostRecentSpace.")
        XCTAssertNotEqual(stored, .littleOrbit, "Choosing 'Most Recent Space' must not silently create a Little Orbit route.")

        editor.pattern(for: ruleID).wrappedValue = "recent.example.com"
        let activeSpaceID = env.state.activeSpaceID ?? firstSpaceID
        let before = env.space(activeSpaceID)?.today.count ?? 0
        env.handleExternalOpen(url: url("https://recent.example.com/x"))
        XCTAssertEqual(env.space(activeSpaceID)?.today.count, before + 1, ".mostRecentSpace must open the link in the last-used Space.")
    }

    func test_newRoute_appendsABlankRouteThatCapturesNothingUntilItIsTypedInto() {
        let countBefore = env.state.routingRules.count
        let ruleID = editor.addRoute(defaultDestination: .space(firstSpaceID))
        defer { editor.remove(ruleID) }

        XCTAssertEqual(env.state.routingRules.count, countBefore + 1)
        XCTAssertEqual(editor.pattern(for: ruleID).wrappedValue, "", "New Route must append a blank, editable route.")
        // Not proof of the isEmpty guards in matchingRoutingRule(for:): deleting them
        // leaves this green too, since Swift's "host".contains("") is already false.
        XCTAssertNil(
            env.matchingRoutingRule(for: url("https://anything.example.com/x")),
            "A blank route must match nothing — a route the user has not typed into yet must not capture every link in the app."
        )
    }

    func test_theMinusButton_removesOnlyThatRoute() {
        let keepID = editor.addRoute(defaultDestination: .space(firstSpaceID))
        let dropID = editor.addRoute(defaultDestination: .littleOrbit)
        defer { editor.remove(keepID) }

        editor.remove(dropID)

        XCTAssertTrue(env.state.routingRules.contains { $0.id == keepID })
        XCTAssertFalse(env.state.routingRules.contains { $0.id == dropID })
    }

    // MARK: - 5. The Default popup is genuinely consulted

    func test_defaultDestination_isConsultedWhenNoRuleMatches() {
        let spaceID = firstSpaceID
        let defaultSpaceID = env.createSpace(
            name: "Default Destination",
            icon: "circle",
            iconIsEmoji: false,
            theme: SpaceTheme(),
            profileID: env.space(spaceID)?.profileID ?? env.createDefaultProfileIfNeeded()
        )
        defer { env.deleteSpace(defaultSpaceID) }

        // createSpace makes the new Space active; put the other Space back in front so
        // "where the default popup says" and "the most recent Space" are different answers.
        env.selectSpace(spaceID)

        RoutingDefaults.destination = .space(defaultSpaceID)
        XCTAssertTrue(env.state.routingRules.isEmpty || env.matchingRoutingRule(for: url("https://unmatched.example.com/x")) == nil, "test precondition: nothing may match this URL")

        let before = env.space(defaultSpaceID)?.today.count ?? 0
        let beforeActive = env.space(spaceID)?.today.count ?? 0
        env.handleExternalOpen(url: url("https://unmatched.example.com/x"))

        XCTAssertEqual(
            env.space(defaultSpaceID)?.today.count,
            before + 1,
            "An external link matching no rule must go where the Air Traffic Control Default popup says — the key OrbitDefaultRoutingDestination was written by that popup and read by nothing (refs/ARC_PARITY_GAPS.md §14 item 7)."
        )
        XCTAssertEqual(
            env.space(spaceID)?.today.count,
            beforeActive,
            "It must not land in the active Space instead — that would mean the fallthrough ignored the stored default and just used the most recent Space."
        )
    }

    func test_defaultDestination_keepsTheExistingStoredVocabularyDecodable() {
        defaults.set("littleOrbit", forKey: RoutingDefaults.key)
        XCTAssertEqual(RoutingDefaults.destination, .littleOrbit)

        defaults.set("mostRecentSpace", forKey: RoutingDefaults.key)
        XCTAssertEqual(RoutingDefaults.destination, .mostRecentSpace)

        let spaceID = UUID()
        defaults.set(spaceID.uuidString, forKey: RoutingDefaults.key)
        XCTAssertEqual(RoutingDefaults.destination, .space(spaceID))

        defaults.removeObject(forKey: RoutingDefaults.key)
        XCTAssertEqual(RoutingDefaults.destination, .mostRecentSpace, "An unset key must read as the same default the old @AppStorage declared.")

        defaults.set("something nobody ever wrote", forKey: RoutingDefaults.key)
        XCTAssertEqual(RoutingDefaults.destination, .mostRecentSpace, "An unrecognised value must degrade to the default rather than trapping.")
    }

    func test_linksFromOtherAppsSwitch_isTheSameStoredValueAsTheDefaultPopup() {
        LinksSettingsActions.setLinksFromOtherAppsOpenInLittleOrbit(true)
        XCTAssertEqual(RoutingDefaults.destination, .littleOrbit)
        XCTAssertTrue(LinksSettingsActions.linksFromOtherAppsOpenInLittleOrbit)

        LinksSettingsActions.setLinksFromOtherAppsOpenInLittleOrbit(false)
        XCTAssertEqual(RoutingDefaults.destination, .mostRecentSpace)
        XCTAssertFalse(LinksSettingsActions.linksFromOtherAppsOpenInLittleOrbit)

        RoutingDefaults.destination = .space(firstSpaceID)
        XCTAssertFalse(LinksSettingsActions.linksFromOtherAppsOpenInLittleOrbit)
        LinksSettingsActions.setLinksFromOtherAppsOpenInLittleOrbit(false)
        XCTAssertEqual(RoutingDefaults.destination, .space(firstSpaceID), "Turning an already-off switch off must not overwrite the chosen Space.")
    }

    // MARK: - 6. Archive Little Orbits after: is read by the scheduler

    func test_archiveIntervalSetting_isReadByTheAutoCloseScheduler() {
        LinksSettingsActions.setArchiveInterval(.oneHour)
        let oneHourTimer = LittleOrbitWindowController.makeAutoCloseTimer {}
        defer { oneHourTimer?.invalidate() }
        guard let oneHourTimer else {
            XCTFail("A one-hour archive interval must schedule a timer.")
            return
        }
        XCTAssertEqual(
            oneHourTimer.fireDate.timeIntervalSinceNow,
            3600,
            accuracy: 30,
            "The auto-close timer must be scheduled at the interval the Links pane's popup stored — this path used to hardcode 6 * 3600."
        )

        LinksSettingsActions.setArchiveInterval(.sixHours)
        let sixHourTimer = LittleOrbitWindowController.makeAutoCloseTimer {}
        defer { sixHourTimer?.invalidate() }
        XCTAssertEqual(sixHourTimer?.fireDate.timeIntervalSinceNow ?? 0, 6 * 3600, accuracy: 30)

        LinksSettingsActions.setArchiveInterval(.never)
        let neverTimer = LittleOrbitWindowController.makeAutoCloseTimer {}
        defer { neverTimer?.invalidate() }
        XCTAssertNil(neverTimer, "\"Never\" must schedule no timer at all, not a distant one.")
    }

    func test_archiveIntervalSetting_roundTripsEveryOptionThePopupOffers() {
        for option in LittleOrbitSettings.ArchiveInterval.allCases {
            LinksSettingsActions.setArchiveInterval(option)
            XCTAssertEqual(LittleOrbitSettings.archiveInterval, option, "\(option.label) did not round-trip through UserDefaults.")
        }
    }
}
