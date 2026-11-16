//  The app side of password autofill with no web view: which entries the list under a field and the right-click submenu carry, when they are
//  withheld (private tabs, plain http, switches off), and what the save prompt asks and does. The panels are replaced by recorders, so no window
//  is shown.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class PasswordAutofillUITests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo
    private var vault: InMemoryPasswordVault!
    private var window: NSWindow!
    private var ui: PasswordAutofillUI { PasswordAutofillUI.shared }

    private var listed: [(entries: [OrbitContextMenuEntry], rect: CGRect)] = []
    private var prompts: [(model: PasswordSavePromptModel, save: () -> Void, never: () -> Void)] = []
    private var managePasswordsOpened = 0

    private let alicePassword = "alice-secret-pw"
    private let bobPassword = "bob-secret-pw"

    override func setUp() {
        super.setUp()
        vault = InMemoryPasswordVault()
        PasswordVaults.shared = vault
        PasswordSettings.offersToAutofill = true
        PasswordSettings.offersToSave = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        listed = []
        prompts = []
        managePasswordsOpened = 0
        ui.suggestions.presentForTesting = { [unowned self] entries, rect in self.listed.append((entries, rect)) }
        ui.savePrompt.presentForTesting = { [unowned self] model, save, never in self.prompts.append((model, save, never)) }
        ui.openManagePasswords = { [unowned self] in self.managePasswordsOpened += 1 }
    }

    override func tearDown() {
        ui.suggestions.presentForTesting = nil
        ui.suggestions.dismiss()
        ui.savePrompt.presentForTesting = nil
        ui.savePrompt.dismiss()
        ui.openManagePasswords = { SettingsWindowController.show(pane: .passwords) }
        PasswordSettings.offersToAutofill = true
        PasswordSettings.offersToSave = true
        PasswordVaults.resetShared()
        window.orderOut(nil)
        window = nil
        vault = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func seedLogins() {
        vault.save(origin: URL(string: "https://example.com")!, username: "alice", password: alicePassword)
        vault.save(origin: URL(string: "https://example.com")!, username: "bob", password: bobPassword)
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

    private func sectionTitles(_ entries: [OrbitContextMenuEntry]) -> [String] {
        entries.compactMap { entry in
            if case .section(_, let title, _) = entry { return title }
            return nil
        }
    }

    private func assertNoPassword(in entries: [OrbitContextMenuEntry], file: StaticString = #filePath, line: UInt = #line) {
        for title in titles(entries) {
            XCTAssertFalse(title.contains(alicePassword) || title.contains(bobPassword), "a password reached a menu title: \(title)", file: file, line: line)
        }
    }

    // MARK: - The right-click submenu

    func testASignInFieldGetsASubmenuOfUsernamesAndManagePasswords() throws {
        seedLogins()
        let contents = attachedContents()
        let entries = menuEntries(for: contents, field: field(.currentPassword))

        let children = try XCTUnwrap(submenu(entries), "no AutoFill Password submenu: \(titles(entries))")
        XCTAssertEqual(titles(children).sorted(), ["Manage Passwords…", "alice", "bob"].sorted())
        XCTAssertEqual(titles(children).last, "Manage Passwords…", "Manage Passwords comes after the logins")
        XCTAssertNil(entries.first(titled: "Use Strong Password"), "a sign-in field is not offered a new password")
        assertNoPassword(in: entries)
        XCTAssertNotNil(entries.first(titled: "Inspect Element"), "the rest of the menu is unchanged")
        XCTAssertNotNil(entries.first(titled: "Paste"))
    }

    func testANewPasswordFieldGetsUseStrongPasswordInsteadOfUsernames() throws {
        seedLogins()
        let contents = attachedContents()
        let children = try XCTUnwrap(submenu(menuEntries(for: contents, field: field(.newPassword))))
        XCTAssertEqual(titles(children), ["Use Strong Password", "Manage Passwords…"])
    }

    func testAFieldWithNoSavedLoginsSaysSo() throws {
        let contents = attachedContents()
        let children = try XCTUnwrap(submenu(menuEntries(for: contents, field: field(.username))))
        let none = try XCTUnwrap(children.first(titled: "No Saved Passwords"))
        XCTAssertFalse(none.isEnabled)
        XCTAssertNotNil(children.first(titled: "Manage Passwords…"))
    }

    func testRightClickOnAnythingElseIsUnchanged() {
        seedLogins()
        let contents = attachedContents()
        XCTAssertNil(menuEntries(for: contents, field: nil).first(titled: "AutoFill Password"))
        XCTAssertNil(menuEntries(for: contents, field: nil, editable: false).first(titled: "AutoFill Password"))
        let plain = env.buildContextMenuEntries(
            for: contents, context: ContextMenuContext(pageURL: URL(string: "https://example.com")), capabilities: [.developerTools]
        )
        XCTAssertNil(plain.first(titled: "AutoFill Password"))
    }

    func testPrivatePagesAndSwitchedOffAutofillGetNoSubmenu() {
        seedLogins()
        XCTAssertNil(submenu(menuEntries(for: attachedContents(incognito: true), field: field(.currentPassword))), "an Incognito Space")
        XCTAssertNil(submenu(menuEntries(for: attachedContents(persistentSession: false), field: field(.currentPassword))), "a non-persistent session")
        XCTAssertNil(submenu(menuEntries(for: MockWebContents(session: MockEngineSession(isPersistent: true)), field: field(.currentPassword))), "contents that are no tab of this window")
        PasswordSettings.offersToAutofill = false
        XCTAssertNil(submenu(menuEntries(for: attachedContents(), field: field(.currentPassword))), "Offer to AutoFill passwords is off")
    }

    func testAPlainHTTPPageShowsItsLoginsUnderAWarning() throws {
        vault.save(origin: URL(string: "http://example.com")!, username: "carol", password: "carol-pw")
        let contents = attachedContents()
        let children = try XCTUnwrap(submenu(menuEntries(for: contents, field: field(.currentPassword, origin: "http://example.com"))))
        XCTAssertEqual(sectionTitles(children), [PasswordAutofillUI.insecureWarning])
        XCTAssertTrue(titles(children).contains("carol"))
    }

    func testAnHTTPSLoginIsNotOfferedInTheSubmenuOfAnHTTPPage() throws {
        vault.save(origin: URL(string: "https://example.com")!, username: "alice", password: alicePassword)
        let contents = attachedContents()
        let children = try XCTUnwrap(submenu(menuEntries(for: contents, field: field(.currentPassword, origin: "http://example.com"))))
        XCTAssertFalse(titles(children).contains("alice"))
        XCTAssertNotNil(children.first(titled: "No Saved Passwords"))

        vault.save(origin: URL(string: "http://example.com")!, username: "carol", password: "carol-pw")
        let both = try XCTUnwrap(submenu(menuEntries(for: contents, field: field(.currentPassword, origin: "http://example.com"))))
        XCTAssertEqual(titles(both).filter { $0 == "alice" || $0 == "carol" }, ["carol"])
        XCTAssertEqual(sectionTitles(both), [PasswordAutofillUI.insecureWarning])
    }

    func testManagePasswordsOpensTheSettingsPane() throws {
        let contents = attachedContents()
        let children = try XCTUnwrap(submenu(menuEntries(for: contents, field: field(.username))))
        let manage = try XCTUnwrap(children.first(titled: "Manage Passwords…"))
        manage.action?()
        XCTAssertEqual(managePasswordsOpened, 1)
    }

    func testThePasswordsPaneIsRegisteredWithItsOwnTitleAndSymbol() {
        XCTAssertTrue(SettingsPane.allCases.contains(.passwords))
        XCTAssertEqual(SettingsPane.passwords.title, "Passwords")
        let others = SettingsPane.allCases.filter { $0 != .passwords }
        XCTAssertFalse(others.map(\.symbolName).contains(SettingsPane.passwords.symbolName))
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsPane.passwords.symbolName, accessibilityDescription: nil))
    }

    // MARK: - The list under a field

    func testFocusingASignInFieldListsUsernamesUnderItWithoutPasswords() throws {
        seedLogins()
        let contents = attachedContents()
        let focused = field(.currentPassword)
        ui.fieldFocused(focused, contents: contents)

        let shown = try XCTUnwrap(listed.first, "nothing was listed")
        XCTAssertEqual(titles(shown.entries).sorted(), ["Manage Passwords…", "alice", "bob"].sorted())
        XCTAssertEqual(titles(shown.entries).last, "Manage Passwords…")
        XCTAssertEqual(shown.rect, focused.screenRect)
        assertNoPassword(in: shown.entries)
    }

    func testThePreviousStepsLoginIsListedFirst() throws {
        seedLogins()
        let contents = attachedContents()
        ui.fieldFocused(field(.currentPassword, preferredUsername: "bob"), contents: contents)
        let shown = titles(try XCTUnwrap(listed.first).entries)
        XCTAssertEqual(shown.first, "bob")
        XCTAssertEqual(shown.last, "Manage Passwords…")
        XCTAssertEqual(shown.count, 3)
    }

    func testAFieldWithoutLoginsListsNothingUnlessItIsANewPassword() throws {
        let contents = attachedContents()
        ui.fieldFocused(field(.currentPassword), contents: contents)
        ui.fieldFocused(field(.username), contents: contents)
        XCTAssertTrue(listed.isEmpty)

        ui.fieldFocused(field(.newPassword), contents: contents)
        XCTAssertEqual(titles(try XCTUnwrap(listed.first).entries), ["Use Strong Password", "Manage Passwords…"])
    }

    func testSwitchedOffAutofillListsNothing() {
        seedLogins()
        PasswordSettings.offersToAutofill = false
        ui.fieldFocused(field(.currentPassword), contents: attachedContents())
        ui.fieldFocused(field(.newPassword), contents: attachedContents())
        XCTAssertTrue(listed.isEmpty)
    }

    func testAPlainHTTPFieldListsOnlyTheWarningSection() throws {
        vault.save(origin: URL(string: "http://example.com")!, username: "carol", password: "carol-pw")
        ui.fieldFocused(field(.currentPassword, origin: "http://example.com"), contents: attachedContents())
        let shown = try XCTUnwrap(listed.first)
        XCTAssertEqual(sectionTitles(shown.entries), [PasswordAutofillUI.insecureWarning])
        XCTAssertNil(shown.entries.first(titled: "Use Strong Password"))
    }

    func testAnHTTPSLoginIsNeverListedUnderAFieldOnAnHTTPPage() {
        vault.save(origin: URL(string: "https://example.com")!, username: "alice", password: alicePassword)
        ui.fieldFocused(field(.currentPassword, origin: "http://example.com"), contents: attachedContents())
        XCTAssertTrue(listed.isEmpty, "an https login must not be offered, not even under the warning")

        ui.fieldFocused(field(.currentPassword, origin: "http://localhost:3000"), contents: attachedContents())
        XCTAssertTrue(listed.isEmpty, "nor on a local http page")
    }

    func testALocalHTTPPageListsItsHTTPLoginsWithoutAWarning() throws {
        vault.save(origin: URL(string: "http://localhost:3000")!, username: "dev", password: "dev-pw")
        ui.fieldFocused(field(.currentPassword, origin: "http://localhost:3000"), contents: attachedContents())
        let shown = try XCTUnwrap(listed.first)
        XCTAssertTrue(sectionTitles(shown.entries).isEmpty)
        XCTAssertTrue(titles(shown.entries).contains("dev"))
    }

    func testEscapeSilencesTheFieldUntilItIsClickedAgain() {
        seedLogins()
        let contents = attachedContents()
        ui.fieldFocused(field(.currentPassword, token: "ftokenesc1"), contents: contents)
        XCTAssertEqual(listed.count, 1)

        ui.suggestions.onEscape?("ftokenesc1")
        ui.fieldFocused(field(.currentPassword, token: "ftokenesc1", trigger: .focus), contents: contents)
        XCTAssertEqual(listed.count, 1, "focus alone must not reopen a list the person closed")

        ui.fieldFocused(field(.currentPassword, token: "ftokenesc1", trigger: .click), contents: contents)
        XCTAssertEqual(listed.count, 2, "a click on the field opens it again")
    }

    func testNoKeyIsClaimedWhileNothingIsShowing() {
        // Arrow keys, Return and Escape belong to the page unless a list is up.
        let presenter = PasswordSuggestionPresenter()
        for code: UInt16 in [125, 126, 36, 76, 53] {
            XCTAssertFalse(presenter.handleKey(code: code), "key \(code) was claimed with no list showing")
        }
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

    // MARK: - The save and update prompt

    private func submission(_ username: String, _ password: String, origin: String = "https://example.com", isNew: Bool = false) -> PasswordSubmission {
        PasswordSubmission(origin: URL(string: origin)!, username: username, password: password, isNewPassword: isNew)
    }

    func testANewLoginIsOfferedForSavingAndSavedWhenAccepted() throws {
        let contents = attachedContents()
        env.webContents(contents, didCapturePasswordSubmission: submission("alice", "pw-new"))

        let prompt = try XCTUnwrap(prompts.first, "no prompt")
        XCTAssertEqual(prompt.model.kind, .save)
        XCTAssertEqual(prompt.model.title, "Save password for example.com?")
        XCTAssertEqual(prompt.model.username, "alice")
        XCTAssertFalse(prompt.model.detail.contains("pw-new"), "the prompt never shows the password")
        XCTAssertTrue(vault.allLogins().isEmpty, "nothing is saved until the person says so")

        prompt.save()
        let saved = try XCTUnwrap(vault.allLogins().first)
        XCTAssertEqual(saved.username, "alice")
        XCTAssertEqual(saved.password, "pw-new")
        XCTAssertEqual(saved.origin, "https://example.com")
    }

    func testNeverForThisSiteStopsFurtherPrompts() throws {
        let contents = attachedContents()
        env.webContents(contents, didCapturePasswordSubmission: submission("alice", "pw"))
        try XCTUnwrap(prompts.first).never()
        XCTAssertTrue(vault.isNeverSave(siteKey: "example.com"))
        XCTAssertTrue(vault.allLogins().isEmpty)

        env.webContents(contents, didCapturePasswordSubmission: submission("bob", "pw-2"))
        XCTAssertEqual(prompts.count, 1, "a never-save site is not asked again")
    }

    func testADifferentPasswordForAKnownUsernameIsOfferedAsAnUpdate() throws {
        seedLogins()
        let contents = attachedContents()
        env.webContents(contents, didCapturePasswordSubmission: submission("alice", "pw-changed"))

        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.model.kind, .update)
        XCTAssertEqual(prompt.model.title, "Update password for example.com?")
        XCTAssertEqual(prompt.model.detail, "alice on example.com")
        prompt.save()
        let alice = try XCTUnwrap(vault.allLogins().first { $0.username == "alice" })
        XCTAssertEqual(alice.password, "pw-changed")
        XCTAssertEqual(vault.allLogins().count, 2, "an update replaces, it does not add")
    }

    func testAUsernameKnownOnlyOnAnotherOriginOfTheSiteIsOfferedAsANewEntryNotAnUpdate() throws {
        vault.save(origin: URL(string: "https://accounts.example.com")!, username: "alice", password: "old-pw")
        let contents = attachedContents()
        env.webContents(contents, didCapturePasswordSubmission: submission("alice", "pw-new"))

        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.model.kind, .save)
        XCTAssertEqual(prompt.model.title, "Save password for example.com?")
        prompt.save()

        let all = vault.allLogins()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first { $0.origin == "https://accounts.example.com" }?.password, "old-pw", "the other origin's login is untouched")
        XCTAssertEqual(all.first { $0.origin == "https://example.com" }?.password, "pw-new")
    }

    func testTheUpdatePromptNamesTheOriginWhenItIsNotTheBareDomain() throws {
        vault.save(origin: URL(string: "https://accounts.example.com:8443")!, username: "alice", password: "old-pw")
        env.webContents(
            attachedContents(),
            didCapturePasswordSubmission: submission("alice", "pw-new", origin: "https://accounts.example.com:8443")
        )
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.model.kind, .update)
        XCTAssertEqual(prompt.model.title, "Update password for accounts.example.com:8443?")
        XCTAssertEqual(prompt.model.detail, "alice on accounts.example.com:8443")
    }

    func testAnIdenticalLoginAsksNothing() {
        seedLogins()
        env.webContents(attachedContents(), didCapturePasswordSubmission: submission("alice", alicePassword))
        XCTAssertTrue(prompts.isEmpty)
    }

    func testNothingIsAskedWhenSavingIsOffOrThePageIsPrivateOrInsecureOrNotShowing() {
        PasswordSettings.offersToSave = false
        env.webContents(attachedContents(), didCapturePasswordSubmission: submission("alice", "pw"))
        XCTAssertTrue(prompts.isEmpty, "Offer to save passwords is off")
        PasswordSettings.offersToSave = true

        env.webContents(attachedContents(incognito: true), didCapturePasswordSubmission: submission("alice", "pw"))
        XCTAssertTrue(prompts.isEmpty, "an Incognito Space is never offered a save")
        env.webContents(attachedContents(persistentSession: false), didCapturePasswordSubmission: submission("alice", "pw"))
        XCTAssertTrue(prompts.isEmpty, "a non-persistent session is never offered a save")

        env.webContents(attachedContents(), didCapturePasswordSubmission: submission("alice", "pw", origin: "http://example.com"))
        XCTAssertTrue(prompts.isEmpty, "a login typed over plain http is not saved")

        env.webContents(attachedContents(inWindow: false), didCapturePasswordSubmission: submission("alice", "pw"))
        XCTAssertTrue(prompts.isEmpty, "a tab that is not on screen has nowhere to show the prompt")
    }

    func testAPageOutsideAnyWindowGetsNoPromptPanel() {
        let real = PasswordSavePromptPresenter()
        let contents = attachedContents()
        // The panel anchors to the page view: a view that is not in a window has nowhere to show it.
        contents.view.removeFromSuperview()
        real.present(
            PasswordSavePromptModel(kind: .save, site: "example.com", username: "alice"),
            anchorView: contents.view, onPrimary: {}, onNever: {}
        )
        XCTAssertFalse(real.isPresented, "a page that is not in a window gets no panel")
    }
}
