//  The app side of password autofill with no web view and no password helper: which entries the list under a field and the right-click
//  submenu carry, when they are withheld (private tabs, plain http, Passwords not usable), and what the save prompt asks and does. The
//  system password manager is a recorder, and the panels are replaced by recorders, so no window is shown and nothing reaches Passwords.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
private final class RecordingSystemPasswords: SystemPasswordsProviding {
    var state: SystemPasswordsState = .paired
    var canFillOneTimeCodes = true
    var loginsByHost: [String: [SystemPasswordLogin]] = [:]
    var cached: [String: [SystemPasswordLogin]] = [:]
    var passwordsByUsername: [String: String] = [:]
    var codes: [SystemPasswordOneTimeCode] = []
    var revealedCodes: [String: String] = [:]
    private(set) var revealRequests: [String] = []

    private(set) var listedHosts: [String] = []
    private(set) var passwordRequests: [String] = []
    private(set) var saves: [String] = []
    private(set) var codeRequests = 0
    private(set) var pairingRequests = 0
    private(set) var passwordsAppOpened = 0

    func cachedLogins(forHost host: String) -> [SystemPasswordLogin]? { cached[host] }

    func logins(forHost host: String) async throws -> [SystemPasswordLogin] {
        listedHosts.append(host)
        return loginsByHost[host] ?? []
    }

    func password(forUsername username: String, host: String) async throws -> String {
        passwordRequests.append("\(username)@\(host)")
        guard let password = passwordsByUsername[username] else { throw SystemPasswordsError.notFound }
        return password
    }

    func save(username: String, password: String, host: String) async throws -> SystemPasswordsSaveOutcome {
        saves.append("\(username):\(password)@\(host)")
        return .saved
    }

    func oneTimeCodes(pageURL: URL, username: String?) async throws -> [SystemPasswordOneTimeCode] {
        codeRequests += 1
        return codes
    }

    func revealOneTimeCode(pageURL: URL, username: String?) async throws -> String {
        revealRequests.append(username ?? "")
        guard let code = revealedCodes[username ?? ""] else { throw SystemPasswordsError.notFound }
        return code
    }
    func didFillOneTimeCode(pageURL: URL, username: String) async {}

    func requestPairing(over window: NSWindow?) { pairingRequests += 1 }

    func openPasswordsApp() { passwordsAppOpened += 1 }
}

@MainActor
final class PasswordAutofillUITests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var passwords: RecordingSystemPasswords!
    private var window: NSWindow!
    private var ui: PasswordAutofillUI { PasswordAutofillUI.shared }

    private var listed: [(entries: [OrbitContextMenuEntry], rect: CGRect)] = []
    private var prompts: [(model: PasswordSavePromptModel, save: () -> Void)] = []

    private let alicePassword = "alice-secret-pw"

    override func setUp() {
        super.setUp()
        passwords = RecordingSystemPasswords()
        ui.passwords = passwords
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        listed = []
        prompts = []
        ui.suggestions.presentForTesting = { [unowned self] entries, rect in self.listed.append((entries, rect)) }
        ui.savePrompt.presentForTesting = { [unowned self] model, save in self.prompts.append((model, save)) }
    }

    override func tearDown() {
        ui.suggestions.presentForTesting = nil
        ui.suggestions.dismiss()
        ui.savePrompt.presentForTesting = nil
        ui.savePrompt.dismiss()
        ui.fieldDismissed()
        ui.passwords = SystemPasswords.shared
        window.orderOut(nil)
        window = nil
        passwords = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private let logins = [SystemPasswordLogin(username: "alice"), SystemPasswordLogin(username: "bob")]

    private func seedLogins() {
        passwords.loginsByHost["example.com"] = logins
        passwords.passwordsByUsername = ["alice": alicePassword, "bob": "bob-secret-pw"]
    }

    private func attachedContents(persistentSession: Bool = true, incognito: Bool = false, inWindow: Bool = true) -> MockWebContents {
        let profileID = incognito
            ? env.store.createProfile(name: "Incognito", isPersistent: false)
            : env.createDefaultProfileIfNeeded()
        let spaceID = env.createSpace(
            name: "Password Test Space", icon: "circle", iconIsEmoji: false, theme: SpaceTheme(), profileID: profileID
        )
        let tab = Orbit.Tab(spaceID: spaceID, section: .today, url: URL(string: "https://example.com")!, title: "")
        env.state.tabs[tab.id] = tab
        let contents = MockWebContents(session: MockEngineSession(isPersistent: persistentSession))
        env._test_attachWebContents(contents, for: tab.id)
        if inWindow { window.contentView?.addSubview(contents.view) }
        return contents
    }

    private func field(
        _ kind: PasswordFieldKind,
        origin: String = "https://example.com",
        token: String = "ftoken0001",
        trigger: PasswordFieldTrigger = .focus,
        preferredUsername: String? = nil
    ) -> PasswordFieldFocus {
        let url = URL(string: origin)!
        return PasswordFieldFocus(
            token: token, kind: kind, trigger: trigger, frameOrigin: url, pageURL: url, isMainFrame: true,
            screenRect: CGRect(x: 120, y: 340, width: 220, height: 28),
            isSecure: PasswordAutofillPolicy.isSecureForFill(origin: url),
            preferredUsername: preferredUsername
        )
    }

    private func menuEntries(for contents: MockWebContents, field: PasswordFieldFocus?, editable: Bool = true) -> [OrbitContextMenuEntry] {
        env.buildContextMenuEntries(
            for: contents,
            context: ContextMenuContext(pageURL: URL(string: "https://example.com"), isEditable: editable, passwordField: field),
            capabilities: [.developerTools]
        )
    }

    private func submenu(_ entries: [OrbitContextMenuEntry]) -> [OrbitContextMenuEntry]? {
        entries.first(titled: "AutoFill Password")?.submenu
    }

    private func titles(_ entries: [OrbitContextMenuEntry]) -> [String] {
        entries.flattenedItems.map(\.title)
    }

    private func assertNoPassword(in entries: [OrbitContextMenuEntry], file: StaticString = #filePath, line: UInt = #line) {
        for title in titles(entries) {
            XCTAssertFalse(title.contains(alicePassword), "a password reached a menu title: \(title)", file: file, line: line)
        }
    }

    /// Lets the tasks the UI started run until `condition` holds or two seconds pass.
    private func settle(file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out waiting", file: file, line: line)
    }

    /// Gives started tasks a moment, for checks that something did not happen.
    private func drain() async {
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - The list under a field

    func testFocusingASignInFieldListsUsernamesFromPasswordsWithoutPasswords() async throws {
        seedLogins()
        let focused = field(.currentPassword)
        ui.fieldFocused(focused, contents: attachedContents())
        await settle { !listed.isEmpty }

        let shown = try XCTUnwrap(listed.first)
        XCTAssertEqual(titles(shown.entries), ["alice", "bob", "Open Passwords"])
        XCTAssertEqual(shown.rect, focused.screenRect)
        XCTAssertEqual(passwords.listedHosts, ["example.com"], "Passwords is asked about the frame's own host")
        XCTAssertTrue(passwords.passwordRequests.isEmpty, "no password is fetched until a row is chosen")
        assertNoPassword(in: shown.entries)
    }

    func testLoginsListedAMomentAgoAreShownAtOnce() throws {
        passwords.cached["example.com"] = logins
        ui.fieldFocused(field(.username), contents: attachedContents())
        let shown = try XCTUnwrap(listed.first, "a cached list must not wait for Passwords")
        XCTAssertEqual(titles(shown.entries), ["alice", "bob", "Open Passwords"])
        XCTAssertTrue(passwords.listedHosts.isEmpty)
    }

    func testThePreviousStepsLoginIsListedFirst() throws {
        passwords.cached["example.com"] = logins
        ui.fieldFocused(field(.currentPassword, preferredUsername: "bob"), contents: attachedContents())
        XCTAssertEqual(titles(try XCTUnwrap(listed.first).entries), ["bob", "alice", "Open Passwords"])
    }

    func testNothingIsListedWithoutLoginsOrOnANewPasswordOrPlainHTTPField() async {
        let contents = attachedContents()
        ui.fieldFocused(field(.currentPassword), contents: contents)
        await settle { passwords.listedHosts.count == 1 }
        await drain()
        XCTAssertTrue(listed.isEmpty, "Passwords has nothing for this site")

        seedLogins()
        ui.fieldFocused(field(.newPassword, token: "ftoken0002"), contents: contents)
        ui.fieldFocused(field(.currentPassword, origin: "http://example.com", token: "ftoken0003"), contents: contents)
        await drain()
        XCTAssertTrue(listed.isEmpty)
        XCTAssertEqual(passwords.listedHosts.count, 1, "neither a new-password field nor a plain http page asks Passwords anything")
    }

    func testALocalHTTPPageIsAskedAbout() async {
        passwords.loginsByHost["localhost"] = [SystemPasswordLogin(username: "dev")]
        ui.fieldFocused(field(.currentPassword, origin: "http://localhost:3000"), contents: attachedContents())
        await settle { !listed.isEmpty }
        XCTAssertEqual(passwords.listedHosts, ["localhost"])
        XCTAssertEqual(listed.first.map { titles($0.entries) }, ["dev", "Open Passwords"])
    }

    func testAnAnswerForAFieldTheUserHasLeftIsDropped() async {
        seedLogins()
        ui.fieldFocused(field(.currentPassword), contents: attachedContents())
        ui.fieldDismissed()
        await settle { passwords.listedHosts.count == 1 }
        await drain()
        XCTAssertTrue(listed.isEmpty)
    }

    func testUnpairedOffersPairingOnlyOnAClick() throws {
        passwords.state = .notPaired
        let contents = attachedContents()
        ui.fieldFocused(field(.currentPassword, trigger: .focus), contents: contents)
        XCTAssertTrue(listed.isEmpty, "tabbing into a field must not raise a pairing offer")

        ui.fieldFocused(field(.currentPassword, trigger: .click), contents: contents)
        let shown = try XCTUnwrap(listed.first)
        XCTAssertEqual(titles(shown.entries), ["Use Passwords…", "Open Passwords"])
        XCTAssertTrue(passwords.listedHosts.isEmpty)

        // The list holds every action back for a moment after it opens; the submenu's entries are the same actions, unguarded.
        let children = try XCTUnwrap(submenu(menuEntries(for: contents, field: field(.currentPassword))))
        try XCTUnwrap(children.first(titled: "Use Passwords…")).action?()
        XCTAssertEqual(passwords.pairingRequests, 1)
    }

    func testNothingIsOfferedWhileMacOSDoesNotAllowOrbit() {
        for state in [SystemPasswordsState.waitingForMacOS, .helperMissing, .unentitledBuild, .notStarted, .awaitingPIN] {
            passwords.state = state
            ui.fieldFocused(field(.currentPassword, trigger: .click), contents: attachedContents())
            XCTAssertTrue(listed.isEmpty, "\(state)")
        }
        XCTAssertTrue(passwords.listedHosts.isEmpty)
    }

    func testEscapeSilencesTheFieldUntilItIsClickedAgain() {
        passwords.cached["example.com"] = logins
        let contents = attachedContents()
        ui.fieldFocused(field(.currentPassword, token: "ftokenesc1"), contents: contents)
        XCTAssertEqual(listed.count, 1)

        ui.suggestions.onEscape?("ftokenesc1")
        ui.fieldFocused(field(.currentPassword, token: "ftokenesc1", trigger: .focus), contents: contents)
        XCTAssertEqual(listed.count, 1, "focus alone must not reopen a list the person closed")

        ui.fieldFocused(field(.currentPassword, token: "ftokenesc1", trigger: .click), contents: contents)
        XCTAssertEqual(listed.count, 2, "a click on the field opens it again")
    }

    func testChoosingARowAsksPasswordsForThatLoginsPassword() async throws {
        seedLogins()
        passwords.cached["example.com"] = logins
        let children = try XCTUnwrap(submenu(menuEntries(for: attachedContents(), field: field(.username))))
        try XCTUnwrap(children.first(titled: "bob")).action?()
        await settle { !passwords.passwordRequests.isEmpty }
        XCTAssertEqual(passwords.passwordRequests, ["bob@example.com"])
    }

    func testOpenPasswordsOpensTheApp() throws {
        passwords.cached["example.com"] = logins
        let children = try XCTUnwrap(submenu(menuEntries(for: attachedContents(), field: field(.username))))
        try XCTUnwrap(children.first(titled: "Open Passwords")).action?()
        XCTAssertEqual(passwords.passwordsAppOpened, 1)
    }

    func testAOneTimeCodeFieldListsCodesFromPasswords() async throws {
        passwords.codes = [SystemPasswordOneTimeCode(code: "123456", username: "alice", domain: "example.com", source: "Messages")]
        ui.fieldFocused(field(.oneTimeCode), contents: attachedContents())
        await settle { !listed.isEmpty }
        XCTAssertEqual(titles(try XCTUnwrap(listed.first).entries), ["123456 from Messages"])

        listed = []
        passwords.canFillOneTimeCodes = false
        ui.fieldFocused(field(.oneTimeCode, token: "ftoken0002"), contents: attachedContents())
        await drain()
        XCTAssertTrue(listed.isEmpty, "a helper that cannot fill codes is not asked")
        XCTAssertEqual(passwords.codeRequests, 1)
    }

    func testACodePasswordsHasNotHandedOverIsListedByWhoseItIsAndFetchedWhenChosen() async throws {
        passwords.codes = [SystemPasswordOneTimeCode(code: SystemPasswordsMessages.passwordNotIncluded, username: "alice", domain: "example.com", source: "Passwords")]
        passwords.revealedCodes = ["alice": "482913"]
        let contents = attachedContents()
        ui.fieldFocused(field(.oneTimeCode), contents: contents)
        await settle { !listed.isEmpty }
        let entries = try XCTUnwrap(listed.first).entries
        XCTAssertEqual(titles(entries), ["alice from Passwords"], "the placeholder is never shown as a code")
        XCTAssertTrue(passwords.revealRequests.isEmpty, "nothing is fetched until the row is chosen")
        // A click in the first fraction of a second after a list appears is ignored.
        try await Task.sleep(for: .seconds(PasswordSuggestionPresenter.activationDelay + 0.1))
        try XCTUnwrap(entries.first(titled: "alice from Passwords")).action?()
        await settle { !self.passwords.revealRequests.isEmpty }
        XCTAssertEqual(passwords.revealRequests, ["alice"])
        withExtendedLifetime(contents) {}
    }

    func testNoKeyIsClaimedWhileNothingIsShowing() {
        // Arrow keys, Return and Escape belong to the page unless a list is up.
        let presenter = PasswordSuggestionPresenter()
        for code: UInt16 in [125, 126, 36, 76, 53] {
            XCTAssertFalse(presenter.handleKey(code: code), "key \(code) was claimed with no list showing")
        }
    }

    // MARK: - The right-click submenu

    func testASignInFieldGetsASubmenuOfUsernamesAndOpenPasswords() throws {
        passwords.cached["example.com"] = logins
        let entries = menuEntries(for: attachedContents(), field: field(.currentPassword))
        let children = try XCTUnwrap(submenu(entries), "no AutoFill Password submenu: \(titles(entries))")
        XCTAssertEqual(titles(children), ["alice", "bob", "Open Passwords"])
        assertNoPassword(in: entries)
        XCTAssertNotNil(entries.first(titled: "Inspect Element"), "the rest of the menu is unchanged")
        XCTAssertNotNil(entries.first(titled: "Paste"))
    }

    func testWithoutAFreshListTheSubmenuOffersToShowThem() async throws {
        seedLogins()
        let children = try XCTUnwrap(submenu(menuEntries(for: attachedContents(), field: field(.username))))
        XCTAssertEqual(titles(children), ["Show Saved Passwords", "Open Passwords"])
        try XCTUnwrap(children.first(titled: "Show Saved Passwords")).action?()
        await settle { !listed.isEmpty }
        XCTAssertEqual(titles(try XCTUnwrap(listed.first).entries), ["alice", "bob", "Open Passwords"])
    }

    func testAnEmptyFreshListSaysSo() throws {
        passwords.cached["example.com"] = []
        let children = try XCTUnwrap(submenu(menuEntries(for: attachedContents(), field: field(.username))))
        let none = try XCTUnwrap(children.first(titled: "No Saved Passwords"))
        XCTAssertFalse(none.isEnabled)
    }

    func testUnpairedTheSubmenuOffersPairing() throws {
        passwords.state = .notPaired
        let children = try XCTUnwrap(submenu(menuEntries(for: attachedContents(), field: field(.currentPassword))))
        XCTAssertEqual(titles(children), ["Use Passwords…", "Open Passwords"])
    }

    func testNoSubmenuWhenPasswordsCannotBeUsedOrTheFieldIsNotASignIn() {
        let contents = attachedContents()
        XCTAssertNil(submenu(menuEntries(for: contents, field: field(.newPassword))))
        XCTAssertNil(submenu(menuEntries(for: contents, field: field(.currentPassword, origin: "http://example.com"))))
        passwords.state = .waitingForMacOS
        XCTAssertNil(submenu(menuEntries(for: contents, field: field(.currentPassword))))
    }

    func testRightClickOnAnythingElseIsUnchanged() {
        passwords.cached["example.com"] = logins
        let contents = attachedContents()
        XCTAssertNil(menuEntries(for: contents, field: nil).first(titled: "AutoFill Password"))
        XCTAssertNil(menuEntries(for: contents, field: nil, editable: false).first(titled: "AutoFill Password"))
        let plain = env.buildContextMenuEntries(
            for: contents, context: ContextMenuContext(pageURL: URL(string: "https://example.com")), capabilities: [.developerTools]
        )
        XCTAssertNil(plain.first(titled: "AutoFill Password"))
    }

    func testPrivatePagesGetNoSubmenu() {
        passwords.cached["example.com"] = logins
        XCTAssertNil(submenu(menuEntries(for: attachedContents(incognito: true), field: field(.currentPassword))), "an Incognito Space")
        XCTAssertNil(submenu(menuEntries(for: attachedContents(persistentSession: false), field: field(.currentPassword))), "a non-persistent session")
        XCTAssertNil(
            submenu(menuEntries(for: MockWebContents(session: MockEngineSession(isPersistent: true)), field: field(.currentPassword))),
            "contents that are no tab of this window"
        )
    }

    func testThePasswordsPaneIsRegisteredWithItsOwnTitleAndSymbol() {
        XCTAssertTrue(SettingsPane.allCases.contains(.passwords))
        XCTAssertEqual(SettingsPane.passwords.title, "Passwords")
        let others = SettingsPane.allCases.filter { $0 != .passwords }
        XCTAssertFalse(others.map(\.symbolName).contains(SettingsPane.passwords.symbolName))
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsPane.passwords.symbolName, accessibilityDescription: nil))
    }

    // MARK: - The activation delay

    private func presenterWithClock(_ now: @escaping () -> TimeInterval) -> (presenter: PasswordSuggestionPresenter, chosen: () -> [String]) {
        var picked: [String] = []
        let presenter = PasswordSuggestionPresenter(clock: now)
        presenter.presentForTesting = { _, _ in }
        let entries: [OrbitContextMenuEntry] = ["alice", "bob"].map { name in
            .item(OrbitContextMenuItem(title: name) { picked.append(name) })
        }
        presenter.present(entries: entries, token: "ftokendelay1", fieldScreenRect: .zero, anchorView: NSView())
        return (presenter, { picked })
    }

    func testAClickOnARowInTheFirstFractionOfASecondDoesNothing() throws {
        var time: TimeInterval = 1000
        var shown: [OrbitContextMenuEntry] = []
        let presenter = PasswordSuggestionPresenter(clock: { time })
        var picked: [String] = []
        presenter.presentForTesting = { entries, _ in shown = entries }
        presenter.present(
            entries: [.item(OrbitContextMenuItem(title: "alice") { picked.append("alice") })],
            token: "ftokendelay1", fieldScreenRect: .zero, anchorView: NSView()
        )
        let row = try XCTUnwrap(shown.first(titled: "alice"))

        XCTAssertFalse(presenter.acceptsActivation)
        row.action?()
        time += PasswordSuggestionPresenter.activationDelay - 0.01
        row.action?()
        XCTAssertTrue(picked.isEmpty, "a click before the delay chose a row")

        time += 0.02
        XCTAssertTrue(presenter.acceptsActivation)
        row.action?()
        XCTAssertEqual(picked, ["alice"])
    }

    func testReturnOnAHighlightedRowIsIgnoredForTheFirstFractionOfASecond() {
        var time: TimeInterval = 50
        let (presenter, chosen) = presenterWithClock { time }

        XCTAssertTrue(presenter.handleKey(code: 125), "the arrow key moves the highlight at once")
        XCTAssertFalse(presenter.handleKey(code: 36), "Return before the delay is the page's")
        XCTAssertTrue(chosen().isEmpty)
        XCTAssertNotNil(presenter.presentedToken, "an ignored Return leaves the list up")

        time += PasswordSuggestionPresenter.activationDelay + 0.01
        XCTAssertTrue(presenter.handleKey(code: 36))
        XCTAssertEqual(chosen().count, 1)
        XCTAssertNil(presenter.presentedToken)
    }

    func testEachNewListStartsItsOwnDelay() {
        var time: TimeInterval = 10
        let presenter = PasswordSuggestionPresenter(clock: { time })
        presenter.presentForTesting = { _, _ in }
        XCTAssertFalse(presenter.acceptsActivation, "nothing is showing")
        presenter.present(entries: [], token: "ftokendelay1", fieldScreenRect: .zero, anchorView: NSView())
        time += 1
        XCTAssertTrue(presenter.acceptsActivation)
        presenter.present(entries: [], token: "ftokendelay2", fieldScreenRect: .zero, anchorView: NSView())
        XCTAssertFalse(presenter.acceptsActivation, "a list for another field is new")
        presenter.dismiss()
        XCTAssertFalse(presenter.acceptsActivation)
    }

    func testPanelFrameSitsUnderTheFieldAndFlipsAboveItWhenThereIsNoRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: OrbitMetrics.contextMenuWidth, height: 90)
        let pad = OrbitMetrics.contextMenuShadowPadding

        let roomy = CGRect(x: 100, y: 500, width: 200, height: 28)
        let below = PasswordSuggestionPresenter.panelFrame(contentSize: size, field: roomy, visibleFrame: visible).insetBy(dx: pad, dy: pad)
        XCTAssertEqual(below.maxY, roomy.minY - 2, accuracy: 0.5, "the list hangs from the field's bottom edge")
        XCTAssertEqual(below.minX, roomy.minX, accuracy: 0.5, "and lines up with its leading edge")

        let cramped = CGRect(x: 100, y: 20, width: 200, height: 28)
        let above = PasswordSuggestionPresenter.panelFrame(contentSize: size, field: cramped, visibleFrame: visible).insetBy(dx: pad, dy: pad)
        XCTAssertEqual(above.minY, cramped.maxY + 2, accuracy: 0.5, "with no room below it opens above the field")
    }

    // MARK: - Save to Passwords

    private func submission(_ username: String, _ password: String, origin: String = "https://example.com", isNew: Bool = false) -> PasswordSubmission {
        PasswordSubmission(origin: URL(string: origin)!, username: username, password: password, isNewPassword: isNew)
    }

    func testANewLoginIsOfferedForSavingToPasswordsAndSavedWhenAccepted() async throws {
        seedLogins()
        env.webContents(attachedContents(), didCapturePasswordSubmission: submission("carol", "pw-new"))
        await settle { !prompts.isEmpty }

        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.model.kind, .save)
        XCTAssertEqual(prompt.model.title, "Save password for example.com to Passwords?")
        XCTAssertEqual(prompt.model.primaryTitle, "Save to Passwords")
        XCTAssertEqual(prompt.model.username, "carol")
        XCTAssertFalse(prompt.model.detail.contains("pw-new"), "the prompt never shows the password")
        XCTAssertTrue(passwords.saves.isEmpty, "nothing is saved until the person says so")

        prompt.save()
        await settle { !passwords.saves.isEmpty }
        XCTAssertEqual(passwords.saves, ["carol:pw-new@example.com"])
    }

    func testANewPasswordForAKnownUsernameIsOfferedAsAnUpdate() async throws {
        seedLogins()
        env.webContents(attachedContents(), didCapturePasswordSubmission: submission("alice", "pw-changed", isNew: true))
        await settle { !prompts.isEmpty }
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.model.kind, .update)
        XCTAssertEqual(prompt.model.title, "Update password for example.com in Passwords?")
        XCTAssertEqual(prompt.model.detail, "alice on example.com")
        prompt.save()
        await settle { !passwords.saves.isEmpty }
        XCTAssertEqual(passwords.saves, ["alice:pw-changed@example.com"])
    }

    func testAPlainSignInWithAKnownUsernameAsksNothing() async {
        seedLogins()
        env.webContents(attachedContents(), didCapturePasswordSubmission: submission("alice", alicePassword))
        await settle { passwords.listedHosts == ["example.com"] }
        await drain()
        XCTAssertTrue(prompts.isEmpty)
    }

    func testTheUpdatePromptNamesTheOriginWhenItIsNotTheBareDomain() async throws {
        passwords.loginsByHost["accounts.example.com"] = [SystemPasswordLogin(username: "alice")]
        env.webContents(
            attachedContents(),
            didCapturePasswordSubmission: submission("alice", "pw-new", origin: "https://accounts.example.com:8443", isNew: true)
        )
        await settle { !prompts.isEmpty }
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.model.title, "Update password for accounts.example.com:8443 in Passwords?")
        XCTAssertEqual(passwords.listedHosts, ["accounts.example.com"])
    }

    func testNothingIsAskedWhenUnpairedOrThePageIsPrivateOrInsecureOrNotShowing() async {
        passwords.state = .notPaired
        env.webContents(attachedContents(), didCapturePasswordSubmission: submission("carol", "pw"))
        passwords.state = .paired

        env.webContents(attachedContents(incognito: true), didCapturePasswordSubmission: submission("carol", "pw"))
        env.webContents(attachedContents(persistentSession: false), didCapturePasswordSubmission: submission("carol", "pw"))
        env.webContents(attachedContents(), didCapturePasswordSubmission: submission("carol", "pw", origin: "http://example.com"))
        env.webContents(attachedContents(inWindow: false), didCapturePasswordSubmission: submission("carol", "pw"))
        await drain()
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(passwords.listedHosts.isEmpty, "none of these may even ask Passwords what it holds")
    }

    func testAPageOutsideAnyWindowGetsNoPromptPanel() {
        let real = PasswordSavePromptPresenter()
        let contents = attachedContents()
        // The panel anchors to the page view: a view that is not in a window has nowhere to show it.
        contents.view.removeFromSuperview()
        real.present(
            PasswordSavePromptModel(kind: .save, site: "example.com", username: "alice"),
            anchorView: contents.view, onPrimary: {}
        )
        XCTAssertFalse(real.isPresented, "a page that is not in a window gets no panel")
    }

    // MARK: - Pairing sheet

    func testThePairingCodeKeepsOnlySixASCIIDigits() {
        XCTAssertEqual(SystemPasswordsPairingView.digits(in: "12 34-56"), "123456")
        XCTAssertEqual(SystemPasswordsPairingView.digits(in: "1234567"), "123456")
        XCTAssertEqual(SystemPasswordsPairingView.digits(in: "abc"), "")
        XCTAssertEqual(SystemPasswordsPairingView.digits(in: "\u{0661}\u{0662}3"), "3")
    }

    func testEveryStateHasWordsForTheSettingsPane() {
        let states: [SystemPasswordsState] = [
            .notStarted, .starting, .helperMissing, .unentitledBuild, .waitingForMacOS, .notPaired, .pairing, .awaitingPIN,
            .verifyingPIN, .paired, .unavailable("reason"),
        ]
        for state in states {
            let summary = SystemPasswords.summary(of: state)
            XCTAssertFalse(summary.title.isEmpty, "\(state)")
            XCTAssertFalse(summary.detail.isEmpty, "\(state)")
        }
        XCTAssertEqual(SystemPasswords.summary(of: .waitingForMacOS).title, "Not allowed by macOS yet")
        XCTAssertNil(SystemPasswords.message(for: SystemPasswordsError.cancelled), "a cancelled pairing is not an error to show")
    }
}
