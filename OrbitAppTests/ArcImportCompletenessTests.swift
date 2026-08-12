import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ArcImportCompletenessTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    // MARK: - Routing

    func testArcIsTheOnlySourceThatImportsItsOwnStructure() {
        XCTAssertTrue(
            ImportableBrowser.arc.importsNativeStructure,
            "Arc's data maps onto Orbit's own model, so it must not be flattened into one bookmarks folder."
        )
        for browser in ImportableBrowser.allCases where browser != .arc {
            XCTAssertFalse(
                browser.importsNativeStructure,
                "\(browser.displayName) has no Spaces to import; claiming otherwise would promise an import Orbit cannot perform."
            )
        }
    }

    func testTheMenuAndOnboardingAgreeOnWhatAnArcImportReports() {
        let summary = ArcImportSummary(
            spacesCreated: 3,
            foldersCreated: 2,
            pinnedTabsImported: 40,
            todayTabsImported: 5,
            historyEntriesImported: 100,
            keyBindingsImported: 4,
            cookies: .imported(count: 12)
        )

        let line = OnboardingView.arcSummaryLine(summary)
        XCTAssertTrue(line.contains("3 Spaces"), "Spaces must be reported: \(line)")
        XCTAssertTrue(line.contains("45 tabs"), "Every imported tab must be counted: \(line)")
        XCTAssertTrue(line.contains("4 keyboard shortcuts"), "Key binds must be reported: \(line)")
        XCTAssertTrue(line.contains("12 login sessions"), "Login sessions must be reported: \(line)")

        let message = ImportFlowRunner.nativeSummaryMessage(summary)
        XCTAssertTrue(message.hasPrefix(line), "The menu must report the same counts onboarding does: \(message)")
    }

    func testTheImportSubmenuListsExactlyWhatTheSharedRunnerOffers() {
        let menu = ImportSubmenuController.shared.menuItem().submenu
        XCTAssertNotNil(menu)
        guard let menu else { return }
        ImportSubmenuController.shared.menuNeedsUpdate(menu)

        let available = ImportFlowRunner.shared.availableBrowsers()
        if available.isEmpty {
            XCTAssertEqual(menu.items.map(\.title), ["No other browser's data found on this Mac"])
            XCTAssertFalse(menu.items[0].isEnabled)
        } else {
            XCTAssertEqual(menu.items.map(\.title), available.map(\.displayName))
        }
    }

    func testEverySourceOfferedALoginImportCanActuallyPerformOne() {
        for browser in ImportableBrowser.allCases where browser.importsLoginSessions {
            XCTAssertEqual(
                browser,
                .arc,
                "\(browser.displayName) is offered a login import but has no decryptor behind it, which would promise the user something that cannot happen."
            )
        }
    }

    // MARK: - Cookie fidelity

    func testEveryCookieFieldSurvivesTheTranslationIntoTheEngine() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let accessed = Date(timeIntervalSince1970: 1_750_000_000)

        let arcCookie = ArcCookie(
            hostKey: ".example.com",
            name: "session",
            value: "abc123",
            path: "/app",
            expiresAt: expiry,
            isSecure: true,
            isHTTPOnly: true,
            sameSitePolicy: .lax,
            sourcePort: 443,
            createdAt: created,
            lastAccessedAt: accessed
        )

        let engineCookie = ArcImportCoordinator.engineCookie(arcCookie)

        XCTAssertEqual(engineCookie.name, "session")
        XCTAssertEqual(engineCookie.value, "abc123")
        XCTAssertEqual(
            engineCookie.domain,
            ".example.com",
            "The leading dot makes this a domain cookie covering every subdomain; stripping it would make it host-only."
        )
        XCTAssertEqual(engineCookie.path, "/app")
        XCTAssertTrue(engineCookie.isSecure)
        XCTAssertTrue(
            engineCookie.isHTTPOnly,
            "A login cookie stripped of HttpOnly becomes readable by page JavaScript the server never exposed it to."
        )
        XCTAssertEqual(engineCookie.sameSite, .lax)
        XCTAssertEqual(engineCookie.expiresAt, expiry)
        XCTAssertEqual(
            engineCookie.createdAt,
            created,
            "Chromium orders same-name cookies by creation date, so stamping 'now' changes which one wins."
        )
        XCTAssertEqual(engineCookie.lastAccessedAt, accessed)
    }

    func testASessionCookieStaysASessionCookieRatherThanGainingAnExpiry() {
        let cookie = ArcCookie(
            hostKey: "example.com",
            name: "temp",
            value: "x",
            path: "/",
            expiresAt: nil,
            isSecure: false,
            isHTTPOnly: false,
            sameSitePolicy: .unspecified,
            sourcePort: 80,
            createdAt: Date(timeIntervalSince1970: 1),
            lastAccessedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertNil(
            ArcImportCoordinator.engineCookie(cookie).expiresAt,
            "A session cookie has no stored expiry — inventing one would change when it dies."
        )
    }

    func testEverySameSitePolicyMapsOntoItsOwnEngineValue() {
        let pairs: [(ArcCookieSameSite, EngineCookie.SameSite)] = [
            (.unspecified, .unspecified),
            (.none, .none),
            (.lax, .lax),
            (.strict, .strict),
        ]
        for (arc, engine) in pairs {
            XCTAssertEqual(ArcImportCoordinator.sameSite(arc), engine)
        }

        XCTAssertNotEqual(
            ArcImportCoordinator.sameSite(.unspecified),
            .lax,
            "Unspecified must stay distinct from Lax."
        )
    }

    // MARK: - Honest reporting

    func testTheCookieOutcomeDistinguishesNowhereToPutThemFromAllRefused() {
        XCTAssertNotEqual(
            ArcCookieImportOutcome.imported(count: 0),
            .decryptedButEngineCannotInstall(count: 40),
            "\"the engine stored none\" and \"there was no session\" call for different things to be said to the user."
        )
        XCTAssertNotEqual(
            ArcCookieImportOutcome.partiallyImported(stored: 30, decrypted: 40),
            .imported(count: 30)
        )
        XCTAssertNotEqual(ArcCookieImportOutcome.keychainDenied, .notAttempted)
    }

    func testAPartialCookieImportIsReportedAsAShortfallAndNotAsSuccess() {
        let summary = ArcImportSummary(cookies: .partiallyImported(stored: 30, decrypted: 40))
        let caveats = OnboardingView.arcCaveats(summary)

        let text = caveats.joined(separator: " ")
        XCTAssertTrue(text.contains("30"), "The number that actually landed must be stated: \(text)")
        XCTAssertTrue(text.contains("10"), "The shortfall must be stated: \(text)")
        XCTAssertTrue(
            text.lowercased().contains("sign in"),
            "The user must be told they may need to sign in again: \(text)"
        )
    }

    func testAFullCookieImportRaisesNoCaveat() {
        XCTAssertEqual(
            OnboardingView.arcCaveats(ArcImportSummary(cookies: .imported(count: 40))),
            [],
            "Every login landed; there is nothing to warn about."
        )
    }

    func testShortcutsThatCouldNotBeCarriedAcrossAreNamedSoTheUserCanRebindThem() {
        let summary = ArcImportSummary(keyBindingsNeedingManualRebind: ["editBoost", "joinNextMeeting"])
        let text = OnboardingView.arcCaveats(summary).joined(separator: " ")

        XCTAssertTrue(text.contains("editBoost"), "Named, not counted — a number the user cannot act on is useless: \(text)")
        XCTAssertTrue(text.contains("joinNextMeeting"), text)
        XCTAssertTrue(text.contains("Shortcuts"), "The user must be told where to set them again: \(text)")
    }

    // MARK: - Key bindings, applied

    func testArcsRemapsLandOnOrbitsCommandsWithoutTouchingTheRunningApp() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        let payload = ArcImportPayload(
            sidebar: ArcSidebarDocument(spaces: []),
            keyBindings: ArcKeyBindingImport(bindings: [
                ArcKeyBinding(action: "newTab", key: "k", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue),
                ArcKeyBinding(action: "toggleSidebar", key: "b", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue),
                ArcKeyBinding(action: "editBoost", key: "e", modifiers: NSEvent.ModifierFlags.command.rawValue),
            ])
        )

        let summary = ArcImportCoordinator.apply(
            payload,
            env: env,
            shortcutRegistry: registry
        )

        XCTAssertEqual(summary.keyBindingsImported, 2)
        XCTAssertEqual(summary.keyBindingsNeedingManualRebind, ["editBoost"])
        XCTAssertEqual(registry.binding(for: .newTabCommandBar), KeyBinding(key: "k", modifiers: [.command, .option]))
        XCTAssertEqual(registry.binding(for: .toggleSidebar), KeyBinding(key: "b", modifiers: [.command, .option]))
    }

    func testARemapOntoAKeyOrbitAlreadyShipsIsReportedRatherThanKillingTheDefault() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        XCTAssertEqual(
            registry.binding(for: .toggleSidebar),
            KeyBinding(key: "s", modifiers: .command),
            "Fixture check: this test means nothing if ⌘S is not already claimed by another command."
        )

        let payload = ArcImportPayload(
            sidebar: ArcSidebarDocument(spaces: []),
            keyBindings: ArcKeyBindingImport(bindings: [
                ArcKeyBinding(action: "newTab", key: "s", modifiers: NSEvent.ModifierFlags.command.rawValue),
            ])
        )

        let summary = ArcImportCoordinator.apply(
            payload,
            env: env,
            shortcutRegistry: registry
        )

        XCTAssertEqual(summary.keyBindingsImported, 0)
        XCTAssertEqual(summary.keyBindingsNeedingManualRebind, ["newTab"])
        XCTAssertEqual(
            registry.binding(for: .toggleSidebar),
            KeyBinding(key: "s", modifiers: .command),
            "Orbit's own default must survive."
        )
        XCTAssertEqual(
            registry.binding(for: .newTabCommandBar),
            KeyBinding(key: "t", modifiers: .command),
            "The refused command must keep its own default rather than being left unbound."
        )
    }

    func testARemapOntoTheKeyTheCommandAlreadyHasIsAppliedRatherThanReportedAsAConflict() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        let payload = ArcImportPayload(
            sidebar: ArcSidebarDocument(spaces: []),
            keyBindings: ArcKeyBindingImport(bindings: [
                ArcKeyBinding(action: "toggleSidebar", key: "s", modifiers: NSEvent.ModifierFlags.command.rawValue),
            ])
        )

        let summary = ArcImportCoordinator.apply(
            payload,
            env: env,
            shortcutRegistry: registry
        )

        XCTAssertEqual(summary.keyBindingsImported, 1)
        XCTAssertEqual(summary.keyBindingsNeedingManualRebind, [])
        XCTAssertEqual(registry.binding(for: .toggleSidebar), KeyBinding(key: "s", modifiers: .command))
    }

    func testTwoArcRemapsClaimingTheSameKeyDoNotBothGetItSilently() {
        let registry = ShortcutRegistry(inMemoryForTesting: true)
        let payload = ArcImportPayload(
            sidebar: ArcSidebarDocument(spaces: []),
            keyBindings: ArcKeyBindingImport(bindings: [
                ArcKeyBinding(action: "newTab", key: "k", modifiers: NSEvent.ModifierFlags.command.rawValue),
                ArcKeyBinding(action: "goBack", key: "k", modifiers: NSEvent.ModifierFlags.command.rawValue),
            ])
        )

        let summary = ArcImportCoordinator.apply(
            payload,
            env: env,
            shortcutRegistry: registry
        )

        XCTAssertEqual(summary.keyBindingsImported, 1)
        XCTAssertEqual(summary.keyBindingsNeedingManualRebind, ["goBack"])
        XCTAssertEqual(registry.binding(for: .newTabCommandBar), KeyBinding(key: "k", modifiers: .command))
        XCTAssertNotEqual(
            registry.binding(for: .goBack),
            KeyBinding(key: "k", modifiers: .command),
            "The losing command must keep its own binding rather than gaining a dead one."
        )
    }
}
