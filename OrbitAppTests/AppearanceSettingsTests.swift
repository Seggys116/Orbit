import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class AppearanceSettingsTests: XCTestCase {

    private var suiteName: String!
    private var writingStore: UserDefaults!
    private var settings: AppearanceSettings!
    private var originalShared: AppearanceSettings!
    private var previousProcessRoot: AppEnvironment!

    private lazy var env: AppEnvironment = AppEnvironment.demo

    override func setUp() {
        super.setUp()
        suiteName = "OrbitAppTests-Appearance-\(UUID().uuidString)"
        writingStore = UserDefaults(suiteName: suiteName)
        settings = AppearanceSettings(defaults: writingStore)
        originalShared = AppearanceSettings.shared
        AppearanceSettings.shared = settings

        previousProcessRoot = AppEnvironment.processRoot
        AppEnvironment.processRoot = env
    }

    override func tearDown() {
        AppEnvironment.processRoot = previousProcessRoot
        previousProcessRoot = nil
        AppearanceSettings.shared = originalShared
        writingStore?.removePersistentDomain(forName: suiteName)
        settings = nil
        writingStore = nil
        super.tearDown()
    }

    private func reloadedStore() -> UserDefaults {
        guard let store = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not construct a second UserDefaults over \(suiteName!).")
            return .standard
        }
        return store
    }

    // MARK: - 1. Automatic is the absence of an override, not a third value

    func test_automaticIsTheDefaultAndOverridesNothing() {
        XCTAssertEqual(
            settings.selection, .automatic,
            "With no stored preference the appearance must default to Automatic; anything else silently changes how every page renders on first launch."
        )
        XCTAssertNil(
            settings.engineColorScheme,
            "Automatic must send no prefers-color-scheme override at all. A value here would pin every page to whatever the appearance happened to be when Orbit launched."
        )
        for system in [ColorScheme.light, .dark] {
            XCTAssertEqual(
                settings.documentColorScheme(system: system), system,
                "Automatic must hand a Note or Easel back the window's own appearance unchanged."
            )
        }
    }

    // MARK: - 2. Light and Dark resolve on both surfaces

    func test_lightAndDarkResolveForBothTheEngineAndTheDocumentSurfaces() {
        settings.selection = .light
        XCTAssertEqual(settings.engineColorScheme, .light)
        XCTAssertEqual(settings.documentColorScheme(system: .dark), .light, "Light must win over a dark window, or the setting does nothing for the user who wants it most.")
        XCTAssertEqual(settings.documentColorScheme(system: .light), .light)

        settings.selection = .dark
        XCTAssertEqual(settings.engineColorScheme, .dark)
        XCTAssertEqual(settings.documentColorScheme(system: .light), .dark, "Dark must win over a light window.")
        XCTAssertEqual(settings.documentColorScheme(system: .dark), .dark)
    }

    func test_theDocumentResolverIsTheOneSharedByTheHeaderAndTheEditor() {
        settings.selection = .dark
        XCTAssertEqual(
            OrbitInternalPageChrome.documentColorScheme(system: .light), .dark,
            "OrbitInternalPageChrome.documentColorScheme(system:) must read the live preference — it is the single point the pane header and the Note editor agree through."
        )
        XCTAssertEqual(
            OrbitInternalPageChrome.surfaceColor(for: OrbitInternalPageChrome.documentColorScheme(system: .light)),
            OrbitInternalPageChrome.surfaceColor(for: .dark),
            "A Note in a light window with Dark chosen must paint the dark surface colour."
        )
    }

    // MARK: - 3. Persistence

    func test_theChoiceSurvivesARelaunch() {
        settings.selection = .dark

        XCTAssertEqual(
            reloadedStore().string(forKey: AppearanceSettings.defaultsKey), "dark",
            "The choice must be written under AppearanceSettings.defaultsKey — a preference the next launch cannot read is not a preference."
        )

        let relaunched = AppearanceSettings(defaults: reloadedStore())
        XCTAssertEqual(relaunched.selection, .dark, "A freshly constructed instance over the same suite must come up on the stored choice.")
        XCTAssertEqual(relaunched.engineColorScheme, .dark)
    }

    func test_anUnrecognisedStoredValueFallsBackToAutomatic() {
        writingStore.set("sepia", forKey: AppearanceSettings.defaultsKey)
        XCTAssertEqual(
            AppearanceSettings(defaults: reloadedStore()).selection, .automatic,
            "An unknown stored appearance must degrade to Automatic rather than trap."
        )
    }

    // MARK: - 4. The push onto tabs that are already open

    func test_choosingAnAppearancePushesItOntoEveryTabThatIsAlreadyOpen() throws {
        let spaceID = try XCTUnwrap(env.activeSpace?.id, "The demo environment has no Space.")
        let first = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://example.com")!)
        let second = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://example.org")!)
        env.state.tabs[first.id] = first
        env.state.tabs[second.id] = second
        let firstContents = MockWebContents()
        let secondContents = MockWebContents()
        env._test_attachWebContents(firstContents, for: first.id)
        env._test_attachWebContents(secondContents, for: second.id)
        defer {
            env._test_detachWebContents(for: first.id)
            env._test_detachWebContents(for: second.id)
            env.state.tabs.removeValue(forKey: first.id)
            env.state.tabs.removeValue(forKey: second.id)
        }

        settings.selection = .dark
        env.applyContentAppearanceToLiveTabs()

        XCTAssertEqual(
            firstContents.preferredColorSchemes, [.dark],
            "A tab that was already open when Dark was chosen never heard about it, so it would keep rendering the previous appearance until it was re-materialised."
        )
        XCTAssertEqual(secondContents.preferredColorSchemes, [.dark], "Every open tab, not just one of them.")

        settings.selection = .automatic
        env.applyContentAppearanceToLiveTabs()

        XCTAssertEqual(
            firstContents.preferredColorSchemes, [.dark, nil],
            "Going back to Automatic must actively clear the override; leaving it in place would strand every open page on the last explicit choice."
        )
    }

    // MARK: - 5. The menu rows

    func test_theViewMenuCarriesArcsAppearanceSubmenu() throws {
        let appearanceMenu = try XCTUnwrap(
            MainMenuBuilder.build().items
                .compactMap(\.submenu)
                .first { $0.title == "View" }?
                .items
                .first { $0.title == "Appearance" }?
                .submenu,
            "The View menu has no Appearance submenu. refs/reference/arc-mainmenu-nib-dump.txt:101 puts it first in Arc's View menu, and the user screenshotted it as missing."
        )

        XCTAssertEqual(
            appearanceMenu.items.map(\.title),
            [AppearanceSettings.captionTitle, "Automatic", "Light", "Dark"],
            "Arc's own rows, in Arc's own order, caption included (refs/reference/arc-mainmenu-nib-dump.txt:102-105)."
        )
        let caption = appearanceMenu.items[0]
        XCTAssertNil(caption.action, "The caption is a label, so it must carry no action — that is what makes AppKit draw it greyed without anything disabling it by hand.")
        XCTAssertNil(caption.submenu, "The caption is a leaf.")
        for row in appearanceMenu.items.dropFirst() {
            XCTAssertTrue(row is AppearanceMenuItem, "'\(row.title)' is not an AppearanceMenuItem, so it cannot carry a live checkmark.")
            XCTAssertEqual(row.keyEquivalent, "", "Arc gives none of the three a shortcut, and neither does Orbit — see AppearanceMenuItem's header.")
        }
    }

    func test_theCheckmarkFollowsTheLiveChoiceAtValidationTime() {
        let rows = AppearanceSettings.Appearance.allCases.map { AppearanceMenuItem($0, settings: settings) }

        func marks() -> [NSControl.StateValue] {
            for row in rows { _ = row.validateMenuItem(row) }
            return rows.map(\.state)
        }

        XCTAssertEqual(marks(), [.on, .off, .off], "With Automatic stored, Automatic is the marked row.")

        settings.selection = .light
        XCTAssertEqual(marks(), [.off, .on, .off], "The mark went stale after the choice changed elsewhere — validateMenuItem is the hook that has to reconcile them.")

        settings.selection = .dark
        XCTAssertEqual(marks(), [.off, .off, .on])
        XCTAssertEqual(marks().filter { $0 == .on }.count, 1, "Exactly one row is ever marked; three appearances are mutually exclusive.")
    }

    func test_choosingARowMovesTheRealSettingAndPersistsIt() throws {
        let dark = AppearanceMenuItem(.dark, settings: settings)
        let action = try XCTUnwrap(dark.action, "The row carries no action, so nothing would happen when it is chosen.")
        let target = try XCTUnwrap(dark.target, "The row carries no target, so nothing would happen when it is chosen.")

        _ = (target as AnyObject).perform(action, with: dark)

        XCTAssertEqual(settings.selection, .dark, "Choosing View ▸ Appearance ▸ Dark must flip the real setting.")
        XCTAssertEqual(
            reloadedStore().string(forKey: AppearanceSettings.defaultsKey), "dark",
            "Choosing the menu row must persist, the same as setting it any other way."
        )
    }
}
