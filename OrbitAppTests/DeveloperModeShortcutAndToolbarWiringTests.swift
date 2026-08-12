import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class DeveloperModeShortcutAndToolbarWiringTests: XCTestCase {

    private var suiteName: String!
    private var writingStore: UserDefaults!
    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        suiteName = "OrbitAppTests-DevModeWiring-\(UUID().uuidString)"
        writingStore = UserDefaults(suiteName: suiteName)
        DeveloperModeSettings.defaults = writingStore
    }

    override func tearDown() {
        writingStore?.removePersistentDomain(forName: suiteName)
        DeveloperModeSettings.defaults = .standard
        writingStore = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 1. ⌃D actually toggles the real, persisted flag

    func test_performToggleDeveloperMode_flipsTheRealPersistedFlag() {
        XCTAssertFalse(DeveloperModeSettings.isEnabled, "test precondition: off in the scratch suite")

        XCTAssertTrue(
            env.perform(.toggleDeveloperMode),
            "perform(_:) must report that it handled .toggleDeveloperMode."
        )
        XCTAssertTrue(DeveloperModeSettings.isEnabled, "⌃D must turn Developer Mode on.")

        env.perform(.toggleDeveloperMode)
        XCTAssertFalse(DeveloperModeSettings.isEnabled, "⌃D must turn Developer Mode back off — it is a toggle, not a one-way switch.")
    }

    // MARK: - 2. F12 actually opens DevTools

    private func makeActiveTab(url: String = "https://example.com/") -> (TabID, MockWebContents) {
        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "DevMode Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: url)!, title: "")
        env.state.tabs[tab.id] = tab
        env.activeTabID = tab.id
        let contents = MockWebContents()
        env._test_attachWebContents(contents, for: tab.id)
        return (tab.id, contents)
    }

    func test_performOpenDeveloperTools_callsShowDeveloperToolsOnTheActiveTab() {
        let (tabID, contents) = makeActiveTab()
        defer { env._test_detachWebContents(for: tabID) }
        XCTAssertEqual(contents.showDeveloperToolsCallCount, 0, "test precondition: nothing invoked yet")

        XCTAssertTrue(env.perform(.openDeveloperTools))

        XCTAssertEqual(
            contents.showDeveloperToolsCallCount, 1,
            "F12 (.openDeveloperTools) must call showDeveloperTools on the active tab's web contents exactly once."
        )
    }

    func test_ctrlDAndF12ResolveToDistinctCommands() {
        guard let ctrlD = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0,
            context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
        ) else { return XCTFail("Could not synthesize ⌃D.") }
        guard let f12 = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 111
        ) else { return XCTFail("Could not synthesize F12.") }

        XCTAssertEqual(ShortcutRegistry.shared.command(matching: ctrlD), .toggleDeveloperMode)
        XCTAssertEqual(ShortcutRegistry.shared.command(matching: f12), .openDeveloperTools)
    }

    // MARK: - 3. The full-URL context menu row never claims an effect Developer Mode blocks

    func test_fullURLRowTitle_neverPromisesToHideWhatDeveloperModeIsForcingOn() {
        let toolbarSettings = ToolbarSettings(defaults: UserDefaults(suiteName: "OrbitAppTests-DevModeWiring-Toolbar-\(UUID().uuidString)")!)
        let tab = Orbit.Tab(spaceID: UUID(), section: .today, url: URL(string: "https://example.com/")!, title: "")

        func title(showsFullURL: Bool, developerMode: Bool) -> String {
            toolbarSettings.showsFullURL = showsFullURL
            DeveloperModeSettings.isEnabled = developerMode
            let menu = ToolbarContextMenu(tab: tab, settings: toolbarSettings, developerModeSettings: DeveloperModeSettings.shared)
            return menu.fullURLRowTitle
        }

        XCTAssertEqual(title(showsFullURL: false, developerMode: false), "Show Full URL")
        XCTAssertEqual(
            title(showsFullURL: true, developerMode: false), "Hide Full URL",
            "With Developer Mode off, hiding the full URL is a real, deliverable promise — unchanged from before this fix."
        )
        XCTAssertEqual(
            title(showsFullURL: false, developerMode: true), "Show Full URL",
            "Turning the preference on is still an accurate description of the action, even though Developer Mode already made the address bar show the full URL."
        )
        XCTAssertEqual(
            title(showsFullURL: true, developerMode: true), "Hide Full URL (Forced On by Developer Mode)",
            "This is the branch that used to lie: \"Hide Full URL\" while Developer Mode makes hiding it impossible. The row must say so rather than promise an effect it cannot deliver."
        )
    }

    // MARK: - 4. The header itself redraws when Developer Mode changes

    func test_theHeaderRedrawsWhenDeveloperModeChanges_withShowsFullURLHeldOff() {
        let toolbarSuiteName = "OrbitAppTests-DevModeWiring-Toolbar-\(UUID().uuidString)"
        let toolbarStore = UserDefaults(suiteName: toolbarSuiteName)!
        defer { toolbarStore.removePersistentDomain(forName: toolbarSuiteName) }
        let originalToolbarShared = ToolbarSettings.shared
        let toolbarSettings = ToolbarSettings(defaults: toolbarStore)
        toolbarSettings.showsFullURL = false
        ToolbarSettings.shared = toolbarSettings
        defer { ToolbarSettings.shared = originalToolbarShared }

        let spaceID = env.state.spaces.first?.id
            ?? env.createSpace(name: "DevMode Render Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded())
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://example.com/a-distinctly-long-path-segment")!, title: "")
        env.state.tabs[tab.id] = tab
        defer { env.state.tabs.removeValue(forKey: tab.id) }

        let size = CGSize(width: 460, height: OrbitToolbarMetrics.totalHeight)
        let addressBand = CGRect(
            x: OrbitToolbarMetrics.addressSideReserve + OrbitToolbarMetrics.leadingPadding,
            y: OrbitToolbarMetrics.topPadding,
            width: size.width - 2 * (OrbitToolbarMetrics.addressSideReserve + OrbitToolbarMetrics.leadingPadding),
            height: OrbitToolbarMetrics.height
        )

        DeveloperModeSettings.isEnabled = false
        let domainRender = render(ToolbarView(tab: tab).environment(env), size: size)

        DeveloperModeSettings.isEnabled = true
        let fullRender = render(ToolbarView(tab: tab).environment(env), size: size)

        let domainInk = domainRender.averageColor(in: addressBand)
        let fullInk = fullRender.averageColor(in: addressBand)

        XCTAssertFalse(
            domainInk.isApproximately(fullInk, tolerance: 0.005),
            "ToolbarView rendered identically with Developer Mode off (\(domainInk)) and on (\(fullInk)), with ToolbarSettings.showsFullURL held false throughout. A longer address string lays down more ink across the same band, so identical output means the header is not reading DeveloperModeSettings at all — the exact \"Developer mode does nothing\" defect this fix exists to close."
        )
    }

    func test_toolbarView_addressTextSourceReadsBothFlagsOred() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DeveloperModeShortcutAndToolbarWiringTests.swift -> OrbitAppTests
            .deletingLastPathComponent() // OrbitAppTests -> repo root
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Orbit/UI/Toolbar/ToolbarView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("toolbarSettings.showsFullURL || developerModeSettings.isEnabled"),
            "ToolbarView.addressText no longer ORs ToolbarSettings.showsFullURL with DeveloperModeSettings.isEnabled — Developer Mode would stop forcing the full URL on."
        )
    }
}
