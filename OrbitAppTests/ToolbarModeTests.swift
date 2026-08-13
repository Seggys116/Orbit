//  Geometry assertions are relationships, never a pinned number. Persistence is read back
//  through a second, freshly constructed UserDefaults over the same suite, never the writer.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class ToolbarModeTests: XCTestCase {

    private var suiteName: String!
    private var writingStore: UserDefaults!
    private var settings: ToolbarSettings!
    private var originalShared: ToolbarSettings!

    private var developerModeSuiteName: String!
    private var developerModeWritingStore: UserDefaults!

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        suiteName = "OrbitAppTests-Toolbar-\(UUID().uuidString)"
        writingStore = UserDefaults(suiteName: suiteName)
        settings = ToolbarSettings(defaults: writingStore)
        originalShared = ToolbarSettings.shared
        ToolbarSettings.shared = settings

        developerModeSuiteName = "OrbitAppTests-Toolbar-DevMode-\(UUID().uuidString)"
        developerModeWritingStore = UserDefaults(suiteName: developerModeSuiteName)
        DeveloperModeSettings.defaults = developerModeWritingStore
    }

    override func tearDown() {
        ToolbarSettings.shared = originalShared
        writingStore?.removePersistentDomain(forName: suiteName)
        settings = nil
        writingStore = nil

        DeveloperModeSettings.defaults = OrbitDefaults.standard
        developerModeWritingStore?.removePersistentDomain(forName: developerModeSuiteName)
        developerModeWritingStore = nil
        developerModeSuiteName = nil
        super.tearDown()
    }

    private func reloadedStore() -> UserDefaults {
        guard let store = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not construct a second UserDefaults over \(suiteName!).")
            return .standard
        }
        return store
    }

    private func makeTab(url: String) -> Orbit.Tab {
        let tab = Orbit.Tab(spaceID: env.activeSpace?.id ?? UUID(), section: .today, url: URL(string: url)!)
        env.state.tabs[tab.id] = tab
        return tab
    }

    private func cleanup(_ ids: [TabID]) {
        for id in ids { env.state.tabs.removeValue(forKey: id) }
    }

    // MARK: - 1. The switch itself, and that it survives a relaunch

    func test_toolbarDefaultsVisible_soTheAdjudicatedPaneHeaderLayoutIsUnchanged() {
        XCTAssertTrue(
            settings.isVisible,
            "refs/ARC_PANE_CHROME.md: with no stored preference the Toolbar must default to visible, because the per-pane header it gates is the layout the user rejected a change away from. A false default would reintroduce that regression."
        )
        XCTAssertFalse(
            settings.showsFullURL,
            "refs/ARC_SPEC.md §1.3: Arc's address indicator defaults to the compressed domain, and off is also the no-change default — ToolbarView showed the domain before this setting existed."
        )
    }

    func test_toggleVisible_flipsTheFlagAndSurvivesAReload() {
        XCTAssertTrue(settings.isVisible, "Test precondition: the fresh scratch suite should start visible.")

        settings.toggleVisible()

        XCTAssertFalse(settings.isVisible, "toggleVisible() should have flipped the in-memory flag.")
        XCTAssertEqual(
            reloadedStore().object(forKey: ToolbarSettings.visibilityDefaultsKey) as? Bool, false,
            "Hiding the Toolbar must reach disk: a second UserDefaults over the same suite — the store the next launch builds — should read false under \(ToolbarSettings.visibilityDefaultsKey)."
        )

        let relaunched = ToolbarSettings(defaults: reloadedStore())
        XCTAssertFalse(
            relaunched.isVisible,
            "A newly constructed ToolbarSettings over the same stored suite came up visible — the preference did not survive, which is exactly the failure mode a default of `true` would hide."
        )
    }

    func test_toggleFullURL_flipsTheFlagAndSurvivesAReload() {
        settings.toggleFullURL()

        XCTAssertTrue(settings.showsFullURL)
        XCTAssertEqual(
            reloadedStore().object(forKey: ToolbarSettings.fullURLDefaultsKey) as? Bool, true,
            "Arc's Settings > Advanced switch is described as persistent (\"If you would always like the full URL visible\"), so this must reach disk under \(ToolbarSettings.fullURLDefaultsKey)."
        )
        XCTAssertTrue(ToolbarSettings(defaults: reloadedStore()).showsFullURL)
    }

    // MARK: - 2. The flag actually gates the chrome it claims to gate

    func test_hidingTheToolbar_removesThePaneHeaderBandFromTheRenderedPane() {
        let tab = makeTab(url: "https://example.com/a/page")
        defer { cleanup([tab.id]) }

        env.themeColors[tab.id] = ThemeColor(red: 0.85, green: 0.15, blue: 0.15)
        defer { env.themeColors.removeValue(forKey: tab.id) }

        let size = CGSize(width: 420, height: OrbitToolbarMetrics.totalHeight + 120)
        let headerBand = CGRect(x: 150, y: OrbitToolbarMetrics.topPadding + 4, width: 120, height: OrbitToolbarMetrics.height - 8)
        let contentBand = CGRect(x: 150, y: OrbitToolbarMetrics.totalHeight + 40, width: 120, height: 40)

        settings.isVisible = true
        let withToolbar = render(SingleTabContentView(tab: tab).environment(env), size: size)
        let shownHeader = withToolbar.averageColor(in: headerBand)
        let shownContent = withToolbar.averageColor(in: contentBand)

        settings.isVisible = false
        let withoutToolbar = render(SingleTabContentView(tab: tab).environment(env), size: size)
        let hiddenHeader = withoutToolbar.averageColor(in: headerBand)
        let hiddenContent = withoutToolbar.averageColor(in: contentBand)

        XCTAssertFalse(
            shownHeader.isApproximately(shownContent),
            "With the Toolbar shown, the top band (\(shownHeader)) should not match the web content below it (\(shownContent)) — that difference is the header. If they match, the header is not being drawn at all and the rest of this test proves nothing."
        )
        XCTAssertTrue(
            hiddenHeader.isApproximately(hiddenContent),
            "refs/ARC_PARITY_GAPS.md §13.2: with the Toolbar hidden the page must run to the pane card's top edge, so the strip where the header used to be (\(hiddenHeader)) should now be the same colour as the content below it (\(hiddenContent)). A difference means the flag flipped but the view tree did not."
        )
        XCTAssertFalse(
            shownHeader.isApproximately(hiddenHeader),
            "Toggling the Toolbar changed nothing about the rendered top band (\(shownHeader) vs \(hiddenHeader)) — the setting is not reaching SingleTabContentView."
        )
    }

    // MARK: - 3. The full-URL setting changes what the address field resolves to

    func test_fullURLSetting_changesTheResolvedAddressText() {
        let url = URL(string: "https://allthings.how/how-to-turn-a-video-into-a-gif-on-iphone")!

        let domain = ToolbarAddressText.text(for: url, showsFullURL: false)
        let full = ToolbarAddressText.text(for: url, showsFullURL: true)

        XCTAssertEqual(domain, "allthings.how", "refs/ARC_SPEC.md §1.3: the compressed default is the host alone.")
        XCTAssertEqual(
            full, "allthings.how/how-to-turn-a-video-into-a-gif-on-iphone",
            "refs/reference/web/arc-toolbar-full-url-shown-allthingshow.png (viewed) renders exactly this string — host and path, no scheme."
        )
        XCTAssertNotEqual(domain, full, "If the two forms agree for a URL with a path, the setting is doing nothing.")
    }

    func test_fullURLText_stripsTheSchemeAndTheBareHostsTrailingSlash() {
        let bare = URL(string: "https://example.com/")!
        XCTAssertEqual(
            ToolbarAddressText.text(for: bare, showsFullURL: true), "example.com",
            "A bare host must not render a dangling slash — the Arc capture shows `allthings.how`, not `allthings.how/`."
        )
        XCTAssertEqual(
            ToolbarAddressText.text(for: bare, showsFullURL: true)?.contains("://"), false,
            "Arc's full URL omits the scheme entirely."
        )
    }

    func test_internalSurfacesWithNoDocumentIdentity_neverRenderAnAddress_inEitherMode() {
        for raw in ["orbit://new-tab", "view-source:https://example.com"] {
            let url = URL(string: raw)!
            XCTAssertNil(
                ToolbarAddressText.text(for: url, showsFullURL: false),
                "\(raw) is an internal surface with no document identity of its own — not a page the user typed a URL for, and not a Note/Easel with a name to show — so it must fall back to the placeholder."
            )
            XCTAssertNil(
                ToolbarAddressText.text(for: url, showsFullURL: true),
                "Switching on full URLs must not make \(raw) start rendering an internal URL in the address bar."
            )
        }
    }

    func test_noteAndEaselDocuments_renderUntitled_inEitherMode() {
        for raw in ["orbit://note/\(UUID().uuidString)", "orbit://easel/\(UUID().uuidString)"] {
            let url = URL(string: raw)!
            XCTAssertEqual(
                ToolbarAddressText.text(for: url, showsFullURL: false), "untitled",
                "\(raw) is a document surface with a real identity, not an empty tab — it must read \"untitled\", never fall back to the placeholder."
            )
            XCTAssertEqual(
                ToolbarAddressText.text(for: url, showsFullURL: true), "untitled",
                "Switching on full URLs must not change what \(raw) shows — there is no URL to lengthen."
            )
        }
    }

    func test_theHeaderItselfRedrawsWhenTheFullURLSettingChanges() {
        let tab = makeTab(url: "https://example.com/a-distinctly-long-path-segment")
        defer { cleanup([tab.id]) }

        let size = CGSize(width: 460, height: OrbitToolbarMetrics.totalHeight)
        let addressBand = CGRect(
            x: OrbitToolbarMetrics.addressSideReserve + OrbitToolbarMetrics.leadingPadding,
            y: OrbitToolbarMetrics.topPadding,
            width: size.width - 2 * (OrbitToolbarMetrics.addressSideReserve + OrbitToolbarMetrics.leadingPadding),
            height: OrbitToolbarMetrics.height
        )

        settings.showsFullURL = false
        let domainRender = render(ToolbarView(tab: tab).environment(env), size: size)

        settings.showsFullURL = true
        let fullRender = render(ToolbarView(tab: tab).environment(env), size: size)

        let domainInk = domainRender.averageColor(in: addressBand)
        let fullInk = fullRender.averageColor(in: addressBand)

        XCTAssertFalse(
            domainInk.isApproximately(fullInk, tolerance: 0.005),
            "ToolbarView rendered identically with showsFullURL off (\(domainInk)) and on (\(fullInk)). A longer string lays down more ink across the same band, so identical output means the header is not reading the setting at all — the §14 failure mode this work exists to avoid."
        )
    }

    // MARK: - 4. The right-click menu's actions really act

    func test_copyURL_putsTheRealURLOnThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "OrbitAppTests-Toolbar-\(UUID().uuidString)"))
        let url = URL(string: "https://example.com/deep/path?q=1#frag")!

        pasteboard.clearContents()
        pasteboard.setString("stale contents that must be replaced", forType: .string)

        ToolbarContextMenuAction.copyURL(url, to: pasteboard)

        XCTAssertEqual(
            pasteboard.string(forType: .string), url.absoluteString,
            "RN2023 Aug 31: right-clicking the Toolbar offers `Copy URL`. It must put the whole absolute URL on the pasteboard — the same thing TabRowView's own Copy URL copies — not the shortened display string."
        )
    }

    func test_contextMenuRowTitles_flipWithTheStateTheyReport() {
        XCTAssertEqual(settings.visibilityMenuTitle, "Hide Toolbar")
        XCTAssertEqual(settings.fullURLMenuTitle, "Show Full URL")

        settings.toggleVisible()
        settings.toggleFullURL()

        XCTAssertEqual(
            settings.visibilityMenuTitle, "Show Toolbar",
            "RN2024 Mar 28: the row reads `Show Toolbar` when it is off and `Hide Toolbar` when it is on."
        )
        XCTAssertEqual(
            settings.fullURLMenuTitle, "Hide Full URL",
            "refs/reference/web/arc-toolbar-hide-full-url-context-menu-allthingshow.png (viewed): once full URLs are on, the row reads `Hide Full URL`."
        )
    }

    // MARK: - 5. View > Show/Hide Toolbar, and Cmd-Shift-D

    func test_viewMenuItem_togglesTheRealSettingAndPersistsIt() {
        let item = ToolbarVisibilityMenuItem(settings: settings)

        XCTAssertEqual(item.title, "Hide Toolbar", "The item is built from live state, so with the Toolbar on it must offer to hide it.")
        guard let action = item.action, let target = item.target else {
            XCTFail("The menu item carries no target/action, so nothing would happen when it is chosen.")
            return
        }

        _ = target.perform(action)

        XCTAssertFalse(settings.isVisible, "Choosing View > Hide Toolbar must flip the real setting, not a copy of it.")
        XCTAssertEqual(
            reloadedStore().object(forKey: ToolbarSettings.visibilityDefaultsKey) as? Bool, false,
            "Choosing the menu item must persist, the same as toggling it any other way."
        )
        XCTAssertEqual(item.title, "Show Toolbar", "After hiding, the row must offer to show it again (RN2024 Mar 28)." )
    }

    func test_viewMenuItemTitle_correctsItselfWhenTheStateChangedElsewhere() {
        let item = ToolbarVisibilityMenuItem(settings: settings)
        XCTAssertEqual(item.title, "Hide Toolbar")

        settings.toggleVisible()

        _ = item.validateMenuItem(item)

        XCTAssertEqual(
            item.title, "Show Toolbar",
            "The View menu row went stale after the Toolbar was hidden from its own context menu — validateMenuItem is the hook that has to reconcile them."
        )
    }

    func test_theMenuItemCarriesArcsOwnShortcut() {
        let item = ToolbarVisibilityMenuItem(settings: settings)
        XCTAssertEqual(
            item.keyEquivalent, "d",
            "Arc's Help Center article 25625458052247: \"Enable the Toolbar using the keyboard shortcut Command-Shift-D\"."
        )
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func test_commandShiftD_isNotSwallowedByTheShortcutRegistry() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("NSEvent.keyEvent returned nil for Cmd-Shift-D.")
            return
        }

        XCTAssertNil(
            ShortcutRegistry.shared.command(matching: event),
            "Cmd-Shift-D must not resolve to a ShortcutCommandID — Cmd-D alone is pinUnpinTab, and command(matching:) requires exact modifier equality. If this fails, the Toolbar's menu item will never see the key."
        )
        XCTAssertNotNil(
            GlobalKeyEventMonitor.handle(event, in: env),
            "GlobalKeyEventMonitor consumed Cmd-Shift-D. It must return the event unchanged so it reaches the responder chain and the View > Show/Hide Toolbar item's key equivalent — see MainMenuBuilder's ToolbarVisibilityMenuItem for why the shortcut is wired this way."
        )
    }

    // MARK: - 6. The back/forward history menu

    private func history() -> [SessionHistoryEntry] {
        [
            SessionHistoryEntry(id: -2, url: URL(string: "https://example.com/two-back")!, title: "Two Back", offset: -2),
            SessionHistoryEntry(id: -1, url: URL(string: "https://example.com/one-back")!, title: "One Back", offset: -1),
            SessionHistoryEntry(id: 0, url: URL(string: "https://example.com/here")!, title: "Here", offset: 0),
            SessionHistoryEntry(id: 1, url: URL(string: "https://example.com/one-forward")!, title: "One Forward", offset: 1)
        ]
    }

    func test_backHistoryRows_areNearestFirstAndExcludeTheCurrentPage() {
        let rows = ToolbarNavHistory.entries(from: history(), direction: .back)

        XCTAssertEqual(
            rows.map(\.offset), [-1, -2],
            "RN2023 Aug 10 (\"Long-press on the Toolbar's back button will now show tab history\"): back history reads nearest-first, and never lists the page you are already on (offset 0, which go(offset:) treats as a no-op anyway)."
        )
        XCTAssertEqual(rows.map(\.title), ["One Back", "Two Back"])
    }

    func test_forwardHistoryRows_areTheOtherDirectionOnly() {
        let rows = ToolbarNavHistory.entries(from: history(), direction: .forward)
        XCTAssertEqual(rows.map(\.offset), [1], "RN2023 Aug 31 added right-click to the forward button too; it must list forward entries, not back ones.")
    }

    func test_historyRowsFallBackToTheURLWhenAnEntryHasNoTitle() {
        let untitled = [SessionHistoryEntry(id: -1, url: URL(string: "https://example.com/some/page")!, title: "   ", offset: -1)]
        let rows = ToolbarNavHistory.entries(from: untitled, direction: .back)
        XCTAssertEqual(
            rows.first?.title, "example.com/some/page",
            "A history entry with no usable title would render as a blank, unclickable menu row. It falls back to the same host+path shape the Toolbar's own full-URL mode renders."
        )
    }

    func test_commandClickTarget_isThePageOneStepAway() {
        XCTAssertEqual(
            ToolbarNavHistory.immediateURL(from: history(), direction: .back)?.absoluteString,
            "https://example.com/one-back",
            "RN2023 Dec 14: \"CMD-left-click ... on the back / forward buttons now navigate back/forward in a new tab\" — the new tab must open the page a plain click would have gone to."
        )
        XCTAssertEqual(
            ToolbarNavHistory.immediateURL(from: history(), direction: .forward)?.absoluteString,
            "https://example.com/one-forward"
        )
        XCTAssertNil(
            ToolbarNavHistory.immediateURL(from: [], direction: .back),
            "With no history there is nothing to open, and the Cmd-click branch must fall back to an ordinary navigation rather than opening an empty tab."
        )
    }

    func test_theHoldMenuIsBuiltFromTheSameRowsAndItsItemsReallyNavigate() {
        var selected: [Int] = []
        let rows = ToolbarNavHistory.entries(from: history(), direction: .back)
        let menu = ToolbarNavHistory.buildNSMenu(items: rows) { selected.append($0) }

        XCTAssertEqual(
            menu.items.map(\.title), ["One Back", "Two Back"],
            "The press-and-hold menu and the right-click menu must offer the same history, in the same order — they are built from one function so they cannot diverge."
        )

        guard let first = menu.items.first, let action = first.action, let target = first.target else {
            XCTFail("The first history row carries no target/action, so choosing it would do nothing.")
            return
        }
        _ = target.perform(action)

        XCTAssertEqual(
            selected, [-1],
            "Choosing the first row must ask the engine to go to offset -1 (WebContents.go(offset:)). An empty result means the menu draws but does not navigate."
        )
    }

    // MARK: - 7. ToolbarNavButtonClickCatchingView

    private func navMouseEvent(
        type: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1,
        at point: NSPoint = NSPoint(x: 5, y: 5)
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    func test_clickCatcher_isNeverAWindowDragHandle() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "ToolbarNavButtonClickCatchingView must never report itself as a window-drag handle — that is precisely what let AppKit swallow the back/forward buttons' mouseDown to move/zoom the window instead of delivering it here, which is the user's exact 'whole bar drags, buttons are dead' report."
        )
    }

    func test_clickCatcher_hitTest_claimsOwnBoundsOnly() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertTrue(view.hitTest(NSPoint(x: 12, y: 12)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 40, y: 40)))
    }

    func test_clickCatcher_acceptsFirstMouse() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertTrue(
            view.acceptsFirstMouse(for: nil),
            "A click on a background window's back/forward button must not be wasted, matching every sibling click-catcher in this codebase."
        )
    }

    func test_plainClick_navigatesOnce_andNeverPresentsTheMenu() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var navigateCount = 0
        var presentedCount = 0
        view.onNavigate = { navigateCount += 1 }
        view.historyMenu = { NSMenu() }
        view.presentMenu = { _ in presentedCount += 1 }

        view.mouseDown(with: navMouseEvent(type: .leftMouseDown))
        view.mouseUp(with: navMouseEvent(type: .leftMouseUp))

        XCTAssertEqual(navigateCount, 1, "A plain click must navigate exactly once — this is the user's exact 'buttons are dead' complaint, now proven fixed with a real mouseDown/mouseUp pair.")
        XCTAssertEqual(presentedCount, 0, "A plain click must never present the press-and-hold/right-click menu.")
        XCTAssertFalse(view.isPressPending, "The press must have cleanly resolved by mouseUp.")
    }

    func test_commandClick_opensInNewTabInstead() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let expectedURL = URL(string: "https://example.com/one-back")!
        var navigateCount = 0
        var openedURL: URL?
        view.onNavigate = { navigateCount += 1 }
        view.immediateURL = { expectedURL }
        view.onNavigateInNewTab = { openedURL = $0 }

        view.mouseDown(with: navMouseEvent(type: .leftMouseDown, modifierFlags: .command))
        view.mouseUp(with: navMouseEvent(type: .leftMouseUp, modifierFlags: .command))

        XCTAssertEqual(openedURL, expectedURL, "RN2023 Dec 14: Cmd-click must open the page one step away in a new tab.")
        XCTAssertEqual(navigateCount, 0, "A Cmd-click must not also navigate the current tab.")
    }

    func test_commandClick_withNoImmediateURL_fallsBackToOrdinaryNavigate() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var navigateCount = 0
        view.onNavigate = { navigateCount += 1 }
        view.immediateURL = { nil }
        view.onNavigateInNewTab = { _ in XCTFail("Must not open a new tab when there is nothing to open.") }

        view.mouseDown(with: navMouseEvent(type: .leftMouseDown, modifierFlags: .command))
        view.mouseUp(with: navMouseEvent(type: .leftMouseUp, modifierFlags: .command))

        XCTAssertEqual(navigateCount, 1)
    }

    func test_disabledDirection_neverNavigates_eitherWay() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        view.isEnabled = { false }
        view.onNavigate = { XCTFail("A disabled direction must not navigate on a plain click.") }
        view.immediateURL = { URL(string: "https://example.com/one-back")! }
        view.onNavigateInNewTab = { _ in XCTFail("A disabled direction must not navigate on a Cmd-click either.") }

        view.mouseDown(with: navMouseEvent(type: .leftMouseDown))
        view.mouseUp(with: navMouseEvent(type: .leftMouseUp))
        view.mouseDown(with: navMouseEvent(type: .leftMouseDown, modifierFlags: .command))
        view.mouseUp(with: navMouseEvent(type: .leftMouseUp, modifierFlags: .command))
    }

    func test_pressAndHold_presentsTheMenu_andTheFollowingMouseUpDoesNotNavigate() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let expectedMenu = NSMenu()
        var presentedMenu: NSMenu?
        view.historyMenu = { expectedMenu }
        view.presentMenu = { presentedMenu = $0 }
        view.onNavigate = { XCTFail("A press-and-hold must not also count as a plain click.") }

        view.mouseDown(with: navMouseEvent(type: .leftMouseDown))
        XCTAssertTrue(view.isPressPending, "A press must be tracked between mouseDown and its resolution.")

        view.holdTimerFired()
        XCTAssertTrue(presentedMenu === expectedMenu, "The hold firing must present the exact NSMenu historyMenu() returns.")
        XCTAssertFalse(view.isPressPending, "The hold firing must resolve the press.")

        view.mouseUp(with: navMouseEvent(type: .leftMouseUp))
    }

    func test_pressAndHold_withNoHistory_presentsNothing() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var presentedCount = 0
        view.historyMenu = { nil }
        view.presentMenu = { _ in presentedCount += 1 }

        view.mouseDown(with: navMouseEvent(type: .leftMouseDown))
        view.holdTimerFired()

        XCTAssertEqual(presentedCount, 0)
    }

    func test_quickClick_neverPresentsTheHoldMenu() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var presentedCount = 0
        view.historyMenu = { NSMenu() }
        view.presentMenu = { _ in presentedCount += 1 }
        view.onNavigate = {}

        view.mouseDown(with: navMouseEvent(type: .leftMouseDown))
        view.mouseUp(with: navMouseEvent(type: .leftMouseUp))
        view.holdTimerFired()

        XCTAssertEqual(presentedCount, 0, "A quick click must never let a late-firing hold timer present the menu after the press already resolved.")
    }

    func test_rightClick_presentsTheSameMenuThePressAndHoldPathDoes() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let expectedMenu = NSMenu()
        var presentedMenu: NSMenu?
        view.historyMenu = { expectedMenu }
        view.presentMenu = { presentedMenu = $0 }

        view.rightMouseDown(with: navMouseEvent(type: .rightMouseDown))

        XCTAssertTrue(presentedMenu === expectedMenu)
    }

    func test_rightClick_withNoHistory_presentsNothing() {
        let view = ToolbarNavButtonClickCatchingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var presentedCount = 0
        view.historyMenu = { nil }
        view.presentMenu = { _ in presentedCount += 1 }

        view.rightMouseDown(with: navMouseEvent(type: .rightMouseDown))

        XCTAssertEqual(presentedCount, 0)
    }

    func test_toolbarNavButton_isBuiltFromTheAppKitClickCatcher_notPlainSwiftUIGestures() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Orbit/UI/Toolbar/ToolbarNavHistory.swift"),
            encoding: .utf8
        )

        let marker = "struct ToolbarNavButton: View {"
        let start = try XCTUnwrap(
            source.range(of: marker),
            "Could not find `ToolbarNavButton` in ToolbarNavHistory.swift — this guard's own source walk is broken, or the type was renamed."
        )
        let body = source[start.upperBound...]

        XCTAssertTrue(
            body.contains("ToolbarNavButtonCatcher"),
            "ToolbarNavButton must build its interactive surface from ToolbarNavButtonCatcher (the real AppKit click-catcher) — see this file's header, 'Interaction fix (2026-08-06)'."
        )
        XCTAssertFalse(
            body.contains("Button(action:"),
            "ToolbarNavButton must not go back to a plain SwiftUI Button — that is precisely the mechanism whose mouseDown AppKit's window-drag arbitration was found to swallow inside the toolbar's titlebar band."
        )
        XCTAssertFalse(
            body.contains(".contextMenu"),
            "Right-click must stay on ToolbarNavButtonClickCatchingView.rightMouseDown, not a SwiftUI .contextMenu — the latter was never proven to be part of the defect, but reintroducing it here would split right-click's presentation path back away from the hold path's shared historyMenu/presentMenu closures."
        )
        XCTAssertFalse(
            body.contains("LongPressGesture"),
            "Press-and-hold must stay on ToolbarNavButtonClickCatchingView's own Timer-based mouseDown/holdTimerFired, not a SwiftUI LongPressGesture — the same dead-inside-the-titlebar-band mechanism as the old Button."
        )
    }
}
