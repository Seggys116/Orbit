import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class SiteControlWiringTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    private var defaultsSuiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "OrbitAppTests-SiteControl-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: defaultsSuiteName)
        PeekSettings.defaults = scratchDefaults
    }

    override func tearDown() {
        scratchDefaults.removePersistentDomain(forName: defaultsSuiteName)
        PeekSettings.defaults = OrbitDefaults.standard
        super.tearDown()
    }

    private func makePinnedTab() -> TabID {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Tab(spaceID: spaceID, section: .pinned, url: URL(string: "https://example.com/")!, title: "")
        env.state.tabs[tab.id] = tab
        return tab.id
    }

    // MARK: - Open Links in Modal (§14 N1)

    func testPressingOpenLinksInModalChangesWhetherALinkPeeks() {
        let pinnedTabID = makePinnedTab()

        SiteControlPopoverView.setOpenLinksInModal(true)
        XCTAssertTrue(
            env.shouldPeek(sourceTabID: pinnedTabID, modifiers: []),
            "With the row on, a link clicked from a Pinned tab must open in a Peek."
        )

        SiteControlPopoverView.setOpenLinksInModal(false)
        XCTAssertFalse(
            env.shouldPeek(sourceTabID: pinnedTabID, modifiers: []),
            "Turning the row off changed its own label and nothing else — the exact defect this closes."
        )

        SiteControlPopoverView.setOpenLinksInModal(true)
        XCTAssertTrue(env.shouldPeek(sourceTabID: pinnedTabID, modifiers: []), "…and back on again.")
    }

    func testSiteControlAndSettingsLinksReadTheSameValue() {
        PeekSettings.isAutomaticPeekEnabled = false
        XCTAssertFalse(SiteControlPopoverView.isOpenLinksInModalEnabled, "The Site Control row seeded from a different value than the Links pane writes.")

        PeekSettings.isAutomaticPeekEnabled = true
        XCTAssertTrue(SiteControlPopoverView.isOpenLinksInModalEnabled)

        SiteControlPopoverView.setOpenLinksInModal(false)
        XCTAssertFalse(PeekSettings.isAutomaticPeekEnabled, "The row must write the value the Links pane reads, not a second one.")
    }

    func testTheLegacyKeyIsMirroredBySettingItselfNotByTheRow() {
        SiteControlPopoverView.setOpenLinksInModal(false)
        XCTAssertTrue(
            scratchDefaults.bool(forKey: "OrbitDisableAutoPeek"),
            "The legacy key must still be kept in step — by PeekSettings' setter."
        )
        SiteControlPopoverView.setOpenLinksInModal(true)
        XCTAssertFalse(scratchDefaults.bool(forKey: "OrbitDisableAutoPeek"))
    }

    // MARK: - Permission rows (§14 item 9)

    func testAPermissionRowAppearsOnlyOnceTheEngineHasARuleForTheSite() {
        let session = MockEngineSession()
        let url = URL(string: "https://example.com/inbox")!
        let manageable = Set(PermissionKind.allCases)

        XCTAssertEqual(
            SiteControlPopoverView.permissionRows(origin: url, session: session, manageable: manageable).count, 0,
            "A site nobody has answered for showed a permission row. Arc shows none either — arc-site-control-center-gmail.png has no permission row at all."
        )

        session.setContentSetting(.block, for: .geolocation, url: url)
        let rows = SiteControlPopoverView.permissionRows(origin: url, session: session, manageable: manageable)

        XCTAssertEqual(rows.map(\.kind), [.geolocation], "Blocking Location produced \(rows.map(\.kind)) rather than exactly one Location row.")
        XCTAssertEqual(rows.first?.title, "Location", "arc-site-control-center.png labels this row `Location`.")
        XCTAssertEqual(rows.first?.valueLabel, "Blocked", "arc-site-control-center.png shows the value `Blocked`, and Arc's own binary carries that string.")

        session.setContentSetting(.allow, for: .geolocation, url: url)
        XCTAssertEqual(
            SiteControlPopoverView.permissionRows(origin: url, session: session, manageable: manageable).first?.valueLabel,
            "Allowed",
            "The row did not follow the stored value — it is reporting something other than the engine's state."
        )

        session.setContentSetting(.ask, for: .geolocation, url: url)
        XCTAssertEqual(
            SiteControlPopoverView.permissionRows(origin: url, session: session, manageable: manageable).count, 0,
            "Revoking left the row behind, so the popover would still claim a decision the engine no longer holds."
        )
    }

    func testNoRowIsBuiltForAValueThatIsNotADecision() {
        let session = MockEngineSession()
        let url = URL(string: "https://example.com/")!

        for kind in PermissionKind.allCases {
            session.setContentSetting(.allow, for: kind, url: url)
        }
        let rows = SiteControlPopoverView.permissionRows(
            origin: url,
            session: session,
            manageable: Set(PermissionKind.allCases)
        )

        XCTAssertEqual(rows.count, PermissionKind.allCases.count)
        for row in rows {
            XCTAssertTrue(
                row.setting == .allow || row.setting == .block,
                "A row was built for \(row.kind.rawValue) = \(row.setting.rawValue); only a real decision may become a row."
            )
            XCTAssertFalse(row.valueLabel.isEmpty, "\(row.kind.rawValue)'s row has no value to show.")
        }
    }

    func testAPermissionTheEngineCannotHonourGetsNoRow() {
        let honourable: Set<PermissionKind> = [.camera, .microphone]
        let session = MockEngineSession()
        session.manageableContentSettings = honourable
        let url = URL(string: "https://example.com/")!

        session.setContentSetting(.block, for: .geolocation, url: url)
        session.setContentSetting(.block, for: .camera, url: url)

        let rows = SiteControlPopoverView.permissionRows(
            origin: url,
            session: session,
            manageable: honourable
        )

        XCTAssertEqual(
            rows.map(\.kind), [.camera],
            "The popover showed \(rows.map(\.kind)) for an engine that manages only camera and microphone; a Location row there would be the original defect wearing a real API."
        )
    }

    func testPressingBlockOnAPermissionRowWritesThroughToTheEngine() throws {
        let session = MockEngineSession()
        let url = URL(string: "https://example.com/inbox")!
        session.setContentSetting(.allow, for: .geolocation, url: url)

        let row = try XCTUnwrap(
            SiteControlPopoverView.permissionRows(origin: url, session: session, manageable: Set(PermissionKind.allCases)).first
        )
        var reloadCount = 0
        let menu = SiteControlPopoverView.makePermissionMenu(for: row, origin: url, session: session) { reloadCount += 1 }

        XCTAssertEqual(menu.items.map(\.title), ["Allow", "Block", "Ask"])
        XCTAssertEqual(
            menu.items.first(where: { $0.title == "Allow" })?.state, .on,
            "The menu does not mark the value the site currently has."
        )

        let block = try XCTUnwrap(menu.items.first(where: { $0.title == "Block" }))
        _ = block.target?.perform(block.action, with: block)

        XCTAssertEqual(
            session.contentSetting(.geolocation, for: url), .block,
            "Pressing Block changed nothing in the engine — the row is decorative again."
        )
        XCTAssertEqual(reloadCount, 1, "The popover was not told to re-read its rows, so it would keep showing the old value.")

        let ask = try XCTUnwrap(menu.items.first(where: { $0.title == "Ask" }))
        _ = ask.target?.perform(ask.action, with: ask)
        XCTAssertEqual(
            session.contentSetting(.geolocation, for: url), .ask,
            "Revoke from the row's menu did not reach the engine."
        )
    }

    func testARuleWrittenFromOnePageAppliesAcrossTheWholeSite() {
        let session = MockEngineSession()
        let inbox = URL(string: "https://example.com/inbox")!
        let settings = URL(string: "https://example.com/settings?tab=2")!

        SiteControlPopoverView.setPermission(.block, kind: .camera, origin: inbox, session: session)

        XCTAssertEqual(
            SiteControlPopoverView.permissionRows(origin: settings, session: session, manageable: Set(PermissionKind.allCases)).map(\.kind),
            [.camera],
            "The rule was keyed by page, not by site."
        )
    }

    // MARK: - Notifications nobody can deliver (§14 N6)

    func testANotificationPermissionRequestIsRefusedWithoutPrompting() {
        let origin = URL(string: "https://example.com/")!
        XCTAssertEqual(
            AppEnvironment.refusalWithoutPrompting(for: PermissionRequest(kinds: [.notifications], origin: origin)),
            .denyAlways,
            "Orbit has no code that displays a notification — granting one promises the site something that can never arrive."
        )
    }

    func testPermissionsOrbitCanHonourStillReachTheUser() {
        let origin = URL(string: "https://example.com/")!
        for kind in [PermissionKind.camera, .microphone, .geolocation, .clipboardRead] {
            XCTAssertNil(
                AppEnvironment.refusalWithoutPrompting(for: PermissionRequest(kinds: [kind], origin: origin)),
                "\(kind.rawValue) was refused without asking — only kinds Orbit cannot deliver may be."
            )
        }
        XCTAssertNil(
            AppEnvironment.refusalWithoutPrompting(for: PermissionRequest(kinds: [.camera, .notifications], origin: origin)),
            "A request carrying something answerable must still be put to the user."
        )
    }

    func testNothingInOrbitDisplaysANotification() throws {
        let hits = try Self.orbitSourceFiles().filter { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return code.contains("UNUserNotificationCenter") || code.contains("NSUserNotification")
        }
        XCTAssertTrue(
            hits.isEmpty,
            "Something now posts a system notification (\(hits.map(\.lastPathComponent))) — revisit AppEnvironment's undeliverablePermissionKinds."
        )
    }

    // MARK: - Library routing (§14 item 14)

    func testEachLibraryCommandRoutesToTheSectionItNames() {
        XCTAssertEqual(AppEnvironment.librarySection(for: .downloads), .downloads)
        XCTAssertEqual(
            AppEnvironment.librarySection(for: .archivedTabs),
            .archivedTabs,
            "\"Show Archived Tabs\" must reach Archived Tabs. It used to open Downloads."
        )
        XCTAssertNotEqual(
            AppEnvironment.librarySection(for: .archivedTabs),
            AppEnvironment.librarySection(for: .downloads),
            "These two were byte-identical calls; if they are equal again the defect is back."
        )
        XCTAssertNil(
            AppEnvironment.librarySection(for: .library),
            "⇧⌘L names the Library window (Arc's `toggleLibrary:`), not a section of it, so it must not force one."
        )
    }

    func testTheArchiveMenuItemIsWiredToTheArchivedTabsCommand() throws {
        let previousDefaults = ShortcutRegistry.defaults
        let suiteName = "OrbitAppTests-ArchiveMenu-\(UUID().uuidString)"
        let menuDefaults = UserDefaults(suiteName: suiteName)!
        ShortcutRegistry.defaults = menuDefaults
        defer {
            ShortcutRegistry.shared.resetToDefaults()
            menuDefaults.removePersistentDomain(forName: suiteName)
            ShortcutRegistry.defaults = previousDefaults
            ShortcutRegistry.shared.reloadOverridesFromStore()
        }

        let probe = KeyBinding(key: "8", modifiers: [.control, .option, .shift])
        ShortcutRegistry.shared.setBinding(probe, for: .archivedTabs)

        let archiveMenu = try XCTUnwrap(
            MainMenuBuilder.build().items.compactMap(\.submenu).first { $0.title == "Archive" },
            "The Archive menu is gone."
        )
        let item = try XCTUnwrap(
            archiveMenu.items.first { $0.title == "Show Archived Tabs" },
            "The \"Show Archived Tabs\" item is gone."
        )

        XCTAssertEqual(item.keyEquivalent, probe.menuKeyEquivalent)
        XCTAssertEqual(item.keyEquivalentModifierMask, probe.modifierFlags)

        let libraryBinding = try XCTUnwrap(ShortcutRegistry.shared.binding(for: .library))
        XCTAssertNotEqual(
            item.keyEquivalent,
            libraryBinding.menuKeyEquivalent,
            "The item is still wired to .library, whose handler never reaches Archived Tabs."
        )
    }

    func testShowArchivedTabsShipsUnboundAndRemappable() {
        XCTAssertNil(
            ShortcutRegistry.shared.command(for: .archivedTabs)?.defaultBinding,
            "Arc's Archive ▸ View Archive carries no key equivalent (read from Arc 1.152.0's own MainMenu.nib)."
        )
        XCTAssertNotNil(ShortcutRegistry.shared.command(for: .archivedTabs), "The command must be in the table so Settings → Shortcuts can bind it.")
    }

    // MARK: - First-run controls that were not controls

    func testClosingTheOnboardingWindowSkipsSetupAndOpensABrowserWindow() {
        AppEnvironment.defaults = scratchDefaults
        let originalOpen = OnboardingWindowController.openBrowserWindow
        defer {
            AppEnvironment.defaults = OrbitDefaults.standard
            OnboardingWindowController.openBrowserWindow = originalOpen
        }
        var windowsOpened = 0
        OnboardingWindowController.openBrowserWindow = { windowsOpened += 1 }

        env.hasCompletedOnboarding = false

        XCTAssertTrue(
            OnboardingWindowController.handleWindowClosed(env: env, isTerminating: false),
            "Closing an unfinished onboarding window must be handled as a skip."
        )
        XCTAssertTrue(
            env.hasCompletedOnboarding,
            "Closing the window left onboarding incomplete, so the whole flow starts again on the next launch for a user who already dismissed it."
        )
        XCTAssertEqual(
            windowsOpened, 1,
            "Closing the only window on a first run must open a browser window — otherwise Orbit is running with nothing on screen."
        )
    }

    func testFinishingOnboardingNormallyDoesNotOpenASecondWindow() {
        AppEnvironment.defaults = scratchDefaults
        let originalOpen = OnboardingWindowController.openBrowserWindow
        defer {
            AppEnvironment.defaults = OrbitDefaults.standard
            OnboardingWindowController.openBrowserWindow = originalOpen
        }
        var windowsOpened = 0
        OnboardingWindowController.openBrowserWindow = { windowsOpened += 1 }

        env.hasCompletedOnboarding = true  // what `onFinished` writes first

        XCTAssertFalse(
            OnboardingWindowController.handleWindowClosed(env: env, isTerminating: false),
            "A close arriving after onboarding already completed is not a skip."
        )
        XCTAssertEqual(windowsOpened, 0, "The Finish path opens its own window; the close handler must not open another.")
    }

    func testQuittingDuringOnboardingNeitherCompletesItNorOpensAWindow() {
        AppEnvironment.defaults = scratchDefaults
        let originalOpen = OnboardingWindowController.openBrowserWindow
        defer {
            AppEnvironment.defaults = OrbitDefaults.standard
            OnboardingWindowController.openBrowserWindow = originalOpen
        }
        var windowsOpened = 0
        OnboardingWindowController.openBrowserWindow = { windowsOpened += 1 }

        env.hasCompletedOnboarding = false

        XCTAssertFalse(OnboardingWindowController.handleWindowClosed(env: env, isTerminating: true))
        XCTAssertFalse(env.hasCompletedOnboarding, "Quitting mid-onboarding must leave it to be offered again.")
        XCTAssertEqual(windowsOpened, 0, "Nothing may open a window while the app is terminating.")
    }

    func testForceShowAllowanceIsSpentAfterTheFirstPresentationOfALaunch() {
        let original = OnboardingWindowController.didForceShowThisLaunch
        defer { OnboardingWindowController.didForceShowThisLaunch = original }
        OnboardingWindowController.didForceShowThisLaunch = false

        XCTAssertTrue(
            OnboardingWindowController.consumeForceShowAllowance(flagEnabled: true),
            "The first call of a launch is the one the debug flag is for."
        )
        XCTAssertFalse(
            OnboardingWindowController.consumeForceShowAllowance(flagEnabled: true),
            "Every later call must fall back to the persisted completion flag — otherwise finishing onboarding re-presents it, forever."
        )
        XCTAssertFalse(
            OnboardingWindowController.consumeForceShowAllowance(flagEnabled: true),
            "The latch stays spent for the rest of the process."
        )
    }

    func testForceShowAllowanceIsNeverGrantedWhileTheFlagIsOff() {
        let original = OnboardingWindowController.didForceShowThisLaunch
        defer { OnboardingWindowController.didForceShowThisLaunch = original }
        OnboardingWindowController.didForceShowThisLaunch = false

        XCTAssertFalse(OnboardingWindowController.consumeForceShowAllowance(flagEnabled: false))
        XCTAssertFalse(
            OnboardingWindowController.didForceShowThisLaunch,
            "A disabled flag must not silently burn the allowance a later enabled call would need."
        )
    }

    func testWarnBeforeQuittingActuallyDecidesWhetherQuittingStops() {
        let original = QuitConfirmation.defaults
        defer { QuitConfirmation.defaults = original }
        QuitConfirmation.defaults = scratchDefaults

        scratchDefaults.set(false, forKey: QuitConfirmation.enabledKey)
        XCTAssertFalse(
            QuitConfirmation.shouldConfirm(openTabCount: 9),
            "With the switch off, nothing may interrupt Cmd+Q."
        )

        scratchDefaults.set(true, forKey: QuitConfirmation.enabledKey)
        XCTAssertTrue(
            QuitConfirmation.shouldConfirm(openTabCount: 9),
            "The toggle persists but does not change the quit decision — which is what it did for its whole life before this test existed."
        )
    }

    func testWarnBeforeQuittingHonoursItsOwnMultipleTabsPromise() {
        let original = QuitConfirmation.defaults
        defer { QuitConfirmation.defaults = original }
        QuitConfirmation.defaults = scratchDefaults
        scratchDefaults.set(true, forKey: QuitConfirmation.enabledKey)

        XCTAssertFalse(QuitConfirmation.shouldConfirm(openTabCount: 0))
        XCTAssertFalse(QuitConfirmation.shouldConfirm(openTabCount: 1))
        XCTAssertTrue(QuitConfirmation.shouldConfirm(openTabCount: 2))
    }

    func testOpenTabCountExcludesArchivedTabs() {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        env.state.tabs.removeAll()

        let before = env.openTabCount
        for section in [TabSection.today, .pinned, .archived] {
            let tab = Tab(spaceID: spaceID, section: section, url: URL(string: "https://example.com/\(section.rawValue)")!, title: "")
            env.state.tabs[tab.id] = tab
        }
        XCTAssertEqual(
            env.openTabCount, before + 2,
            "openTabCount counted the archived tab, so 'Warn before quitting' would fire on a session with nothing open in it."
        )
    }

    func testWalkingPastTheDefaultBrowserStepIsRecordedAsADecline() {
        let original = DefaultBrowser.defaults
        defer { DefaultBrowser.defaults = original }
        DefaultBrowser.defaults = scratchDefaults
        scratchDefaults.removeObject(forKey: DefaultBrowser.declinedKey)

        OnboardingView.commitDefaultBrowserDecision(wasOffered: true, didRequest: false)
        XCTAssertTrue(
            scratchDefaults.bool(forKey: DefaultBrowser.declinedKey),
            "Finishing onboarding without setting the default browser must be recorded, or shouldOfferToBecomeDefault can never return false."
        )
    }

    func testNeitherPressingTheButtonNorNeverSeeingItCountsAsADecline() {
        let original = DefaultBrowser.defaults
        defer { DefaultBrowser.defaults = original }
        DefaultBrowser.defaults = scratchDefaults

        scratchDefaults.removeObject(forKey: DefaultBrowser.declinedKey)
        OnboardingView.commitDefaultBrowserDecision(wasOffered: true, didRequest: true)
        XCTAssertFalse(scratchDefaults.bool(forKey: DefaultBrowser.declinedKey), "Pressing 'Set as Default Browser' is not declining it.")

        scratchDefaults.removeObject(forKey: DefaultBrowser.declinedKey)
        OnboardingView.commitDefaultBrowserDecision(wasOffered: false, didRequest: false)
        XCTAssertFalse(scratchDefaults.bool(forKey: DefaultBrowser.declinedKey), "A step that never offered the button cannot record a decline against it.")
    }

    func testARecordedDeclineStopsTheOfferComingBack() {
        let original = DefaultBrowser.defaults
        defer { DefaultBrowser.defaults = original }
        DefaultBrowser.defaults = scratchDefaults
        scratchDefaults.removeObject(forKey: DefaultBrowser.declinedKey)

        try? XCTSkipIf(DefaultBrowser.isDefault, "Orbit is the default browser on this machine, so the offer is already suppressed for a different reason.")

        DefaultBrowser.recordDeclined()
        XCTAssertFalse(
            DefaultBrowser.shouldOfferToBecomeDefault,
            "recordDeclined() did not suppress the offer, so the 'ask once' policy its doc comment describes is still not real."
        )
    }

    func testFaviconFetchesGiveUpLongBeforeURLSessionsDefaultMinute() throws {
        XCTAssertLessThan(
            FaviconCache.downloadTimeout, 60,
            "The favicon fetch is back on URLSession's 60s default, which is a blank sidebar on a first run with no network."
        )
        XCTAssertGreaterThan(FaviconCache.downloadTimeout, 0, "A zero or negative timeout means URLSession uses its default.")

        let source = try Self.productionSource(named: "FaviconCache.swift")
        XCTAssertTrue(
            source.contains("request.timeoutInterval = FaviconCache.downloadTimeout"),
            "FaviconCache.download no longer applies downloadTimeout to its URLRequest, so the constant is decorative."
        )
        XCTAssertFalse(
            source.contains("URLSession.shared.data(from: url)"),
            "FaviconCache.download is back on the timeout-less URLSession.shared.data(from:) convenience."
        )
    }

    private static func productionSource(named fileName: String) throws -> String {
        guard let match = try orbitSourceFiles().first(where: { $0.lastPathComponent == fileName }) else {
            XCTFail("Could not find \(fileName) under Orbit/.")
            return ""
        }
        return try String(contentsOf: match, encoding: .utf8)
    }

    // MARK: - Source lookup

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OrbitAppTests
            .deletingLastPathComponent()  // repo root
    }

    private static func orbitSourceFiles() throws -> [URL] {
        let root = repositoryRoot.appendingPathComponent("Orbit")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            ["swift", "mm", "m", "h", "hpp"].contains($0.pathExtension)
        }
    }
}
