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

    // MARK: - Onboarding's login-session toggle vs the Settings import
    //
    // The reported bug: "import sign ins from Arc doesn't work" in onboarding
    // but does in Settings. Root cause — onboarding runs before any browser
    // window exists, so AppEnvironment.engine is nil (OrbitWindowController is
    // the only startEngineIfNeeded() caller), so a decrypted cookie has no
    // session to be stored into (see ArcCookieImportOutcome.decryptedButEngineCannotInstall's
    // doc comment). Settings never hits this because the app is already running.

    private func sampleArcCookie(name: String = "session") -> ArcCookie {
        ArcCookie(
            hostKey: ".example.com",
            name: name,
            value: "abc123",
            path: "/",
            expiresAt: nil,
            isSecure: true,
            isHTTPOnly: true,
            sameSitePolicy: .lax,
            sourcePort: 443,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testCookiesDecryptedWithNoEngineSessionAreReportedRatherThanSilentlyDropped() async {
        let outcome = await ArcImportCoordinator.installOutcome([sampleArcCookie()], session: nil)

        XCTAssertEqual(
            outcome, .decryptedButEngineCannotInstall(count: 1),
            "This is exactly the state onboarding used to land in: the cookie decrypted fine but there was nowhere to store it."
        )
    }

    func testCookiesInstallWhenALiveSessionIsAvailable() async {
        let session = RecordingEngineSession()

        let outcome = await ArcImportCoordinator.installOutcome([sampleArcCookie()], session: session)

        XCTAssertEqual(outcome, .imported(count: 1))
        XCTAssertEqual(session.storedCookies.map(\.name), ["session"], "the decrypted cookie must actually reach the session, not just be counted")
    }

    func testResolvedImportCookiesIsTrueOnlyWhenToggledOnForABrowserThatSupportsIt() {
        XCTAssertTrue(OnboardingImportRunner.resolvedImportCookies(toggleOn: true, browser: .arc))
        XCTAssertFalse(
            OnboardingImportRunner.resolvedImportCookies(toggleOn: false, browser: .arc),
            "Declining the toggle must be honoured, not defaulted through the way an ignored NSAlert would be."
        )
        XCTAssertFalse(
            OnboardingImportRunner.resolvedImportCookies(toggleOn: true, browser: .chrome),
            "A browser with no login-session support must never report cookies as requested, regardless of the toggle."
        )
    }

    func testEnsureEngineReadyStartsTheEngineOnlyWhenNoneIsRunningYet() {
        var started = false

        OnboardingImportRunner.ensureEngineReady(env: env) { _ in started = true }

        XCTAssertTrue(
            started,
            "Onboarding's import step runs before any window exists, so env.engine is nil here — this is the exact gap that left Arc's cookies undeliverable."
        )
    }

    func testEnsureEngineReadyLeavesAnAlreadyRunningEngineAlone() {
        env._test_engineOverride = StubEngineForOnboardingImportTests()
        var started = false

        OnboardingImportRunner.ensureEngineReady(env: env) { _ in started = true }

        XCTAssertFalse(started, "Settings' import runs with the engine already up; a second onboarding import must not restart it either.")
    }

    func testTurningTheToggleOnReachesTheActualPerformImportCall() async {
        var capturedImportCookies: Bool?
        let summary = ArcImportSummary(cookies: .imported(count: 3))

        let state = await OnboardingImportRunner.runArcImport(
            env: env,
            importLoginSessions: true,
            engineStarter: { _ in },
            performImport: { _, importCookies in
                capturedImportCookies = importCookies
                return summary
            }
        )

        XCTAssertEqual(capturedImportCookies, true, "Turning the toggle on must reach the real performImport(importCookies:) call — this is the exact value that used to get lost.")
        XCTAssertEqual(state, .finishedArc(summary))
    }

    func testDecliningTheToggleIsHonouredJustAsFaithfully() async {
        var capturedImportCookies: Bool?

        _ = await OnboardingImportRunner.runArcImport(
            env: env,
            importLoginSessions: false,
            engineStarter: { _ in },
            performImport: { _, importCookies in
                capturedImportCookies = importCookies
                return ArcImportSummary()
            }
        )

        XCTAssertEqual(capturedImportCookies, false, "Leaving the toggle off must reach performImport as false, not be silently upgraded to true.")
    }

    func testAFailedArcImportIsSurfacedRatherThanDropped() async {
        struct ImportBoom: LocalizedError {
            var errorDescription: String? { "boom" }
        }

        let state = await OnboardingImportRunner.runArcImport(
            env: env,
            importLoginSessions: true,
            engineStarter: { _ in },
            performImport: { _, _ in throw ImportBoom() }
        )

        XCTAssertEqual(state, .failed("boom"), "A thrown import error must reach onboarding's UI as a failure state, not vanish.")
    }

    func testOnboardingDoesNotHideACompletedArcImportBehindAnAutomaticAdvance() {
        let cookieShortfall = ArcImportSummary(cookies: .decryptedButEngineCannotInstall(count: 2))

        XCTAssertFalse(OnboardingView.isImportComplete(.importing(.arc)), "still running — nothing to show yet")
        XCTAssertTrue(
            OnboardingView.isImportComplete(.finishedArc(cookieShortfall)),
            "A landed result, including one carrying a cookie caveat, must count as complete so the flow waits on the user instead of auto-advancing over it."
        )

        XCTAssertEqual(
            OnboardingView.continueButtonTitle(step: .importBrowser, selectedImportSource: .arc, importState: .idle),
            "Import From Arc"
        )
        XCTAssertEqual(
            OnboardingView.continueButtonTitle(step: .importBrowser, selectedImportSource: .arc, importState: .finishedArc(cookieShortfall)),
            "Continue",
            "Once the import — and any caveat in its summary — has landed, the button must hand control back to the user rather than relabelling itself mid-read and stepping away."
        )
    }

    func testTheMissingEngineSessionCaveatIsWordedForTheUser() {
        let summary = ArcImportSummary(cookies: .decryptedButEngineCannotInstall(count: 5))
        let text = OnboardingView.arcCaveats(summary).joined(separator: " ")

        XCTAssertTrue(text.contains("5"), text)
        XCTAssertTrue(text.lowercased().contains("sign in"), text)
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

// MARK: - Test doubles

@MainActor
private final class RecordingEngineSession: EngineSession {
    let identifier = "recording"
    let isPersistent = true
    var storageURL: URL? { nil }
    private(set) var storedCookies: [EngineCookie] = []

    func setUserAgent(_ userAgent: String) {}
    func cookies(for url: URL) async -> [HTTPCookie] { [] }
    func deleteCookies(for url: URL) async {}
    func setCookies(_ cookies: [EngineCookie]) async -> Int {
        storedCookies.append(contentsOf: cookies)
        return cookies.count
    }
    func contentSetting(_ kind: PermissionKind, for url: URL) -> ContentSetting { .unsupported }
    func setContentSetting(_ setting: ContentSetting, for kind: PermissionKind, url: URL) {}
}

/// Stands in for a started engine purely so AppEnvironment.engine is non-nil — none of the
/// process a real one needs.
@MainActor
private final class StubEngineForOnboardingImportTests: BrowserEngine {
    static let kind: EngineKind = .chromium
    let capabilities: EngineCapabilities = []
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation = .immediate
    let versionDescription = "Stub (ArcImportCompletenessTests — no real engine is running)"

    private lazy var stubSession = RecordingEngineSession()

    func start() throws {}
    func shutdown() -> Bool { true }
    func tick() {}

    func session(identifier: String, persistent: Bool) throws -> EngineSession { stubSession }
    var defaultSession: EngineSession { stubSession }

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        throw EngineError(code: .engineUnavailable)
    }

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
    func addUserScript(_ script: UserScript, session: EngineSession) {}
    func removeUserScript(id: UUID, session: EngineSession) {}
    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}

    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
        throw EngineError(code: .engineUnavailable)
    }
    func unloadExtension(id: String, session: EngineSession) {}
    func loadedExtensions(session: EngineSession) -> [LoadedExtension] { [] }
}
