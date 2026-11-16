//  The Passwords settings pane's model: what is gated behind the device owner's authentication (and fails closed), the clipboard rule,
//  editing, and CSV import. Authentication and confirmations are replaced, so no prompt or dialog is shown.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class PasswordsSettingsModelTests: XCTestCase {

    private var vault: InMemoryPasswordVault!
    private var model: PasswordsSettingsModel!
    private var authenticationReasons: [String] = []

    override func setUp() {
        super.setUp()
        vault = InMemoryPasswordVault()
        model = PasswordsSettingsModel(vault: vault)
        authenticationReasons = []
        model.authenticate = { [unowned self] reason in
            self.authenticationReasons.append(reason)
            return false
        }
        model.confirmExport = { false }
        model.confirmDelete = { false }
    }

    override func tearDown() {
        model = nil
        vault = nil
        super.tearDown()
    }

    @discardableResult
    private func seed(_ origin: String, _ username: String, _ password: String) throws -> SavedLogin {
        let outcome = try XCTUnwrap(vault.save(origin: URL(string: origin)!, username: username, password: password))
        model.reload()
        switch outcome {
        case .added(let login), .updated(let login), .unchanged(let login): return login
        }
    }

    // MARK: - Showing and copying fail closed

    func testShowingAPasswordNeedsAuthenticationAndFailsClosed() async throws {
        let login = try seed("https://example.com", "alice", "show-me-secret")
        model.select(login.id)

        await model.revealPassword()
        XCTAssertNil(model.revealedPassword, "a refused authentication must not reveal the password")
        XCTAssertEqual(authenticationReasons.count, 1)
        XCTAssertTrue(authenticationReasons[0].contains("example.com"))

        model.authenticate = { _ in true }
        await model.revealPassword()
        XCTAssertEqual(model.revealedPassword, "show-me-secret")

        model.hidePassword()
        XCTAssertNil(model.revealedPassword)
    }

    func testChangingTheSelectionHidesARevealedPassword() async throws {
        let first = try seed("https://example.com", "alice", "pw-a")
        let second = try seed("https://example.org", "bob", "pw-b")
        model.authenticate = { _ in true }
        model.select(first.id)
        await model.revealPassword()
        XCTAssertNotNil(model.revealedPassword)

        model.select(second.id)
        XCTAssertNil(model.revealedPassword)
    }

    func testCopyingNeedsAuthenticationAndLeavesTheClipboardAloneWhenRefused() async throws {
        let login = try seed("https://example.com", "alice", "copy-me-secret")
        model.select(login.id)
        let before = NSPasteboard.general.string(forType: .string)

        await model.copyPassword()

        XCTAssertEqual(authenticationReasons.count, 1)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), before, "a refused authentication must not touch the clipboard")
        XCTAssertNotEqual(NSPasteboard.general.string(forType: .string), "copy-me-secret")
    }

    func testExportNeedsAuthenticationThenAConfirmationOfThePlaintextWarning() async throws {
        try seed("https://example.com", "alice", "export-secret-1")

        let refused = await model.exportText()
        XCTAssertNil(refused, "no authentication, no export")
        XCTAssertNotNil(model.statusMessage)

        model.authenticate = { _ in true }
        let unconfirmed = await model.exportText()
        XCTAssertNil(unconfirmed, "declining the plaintext warning ends the export")

        model.confirmExport = { true }
        let exported = await model.exportText()
        let text = try XCTUnwrap(exported)
        XCTAssertTrue(text.hasPrefix("name,url,username,password,note"))
        XCTAssertTrue(text.contains("alice") && text.contains("export-secret-1"))
    }

    // MARK: - Clipboard

    func testTheClipboardIsClearedAfterTheDelayOnlyWhileItStillHoldsTheCopiedValue() async throws {
        let first = NSPasteboard(name: NSPasteboard.Name("orbit.passwords.test.\(UUID().uuidString)"))
        let second = NSPasteboard(name: NSPasteboard.Name("orbit.passwords.test.\(UUID().uuidString)"))
        defer {
            first.releaseGlobally()
            second.releaseGlobally()
        }

        PasswordClipboard.copy("still-mine", to: first, clearAfter: 0.1)
        XCTAssertEqual(first.string(forType: .string), "still-mine")

        PasswordClipboard.copy("overwritten-secret", to: second, clearAfter: 0.1)
        second.clearContents()
        second.setString("something the person copied since", forType: .string)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(first.string(forType: .string), "the password is gone from the clipboard")
        XCTAssertEqual(second.string(forType: .string), "something the person copied since", "a later copy is never cleared")
    }

    func testTheClearDecisionNeedsBothAnUnchangedPasteboardAndTheSameValue() {
        XCTAssertTrue(PasswordClipboard.shouldClear(changeCount: 7, recorded: 7, current: "pw", copied: "pw"))
        XCTAssertFalse(PasswordClipboard.shouldClear(changeCount: 8, recorded: 7, current: "pw", copied: "pw"))
        XCTAssertFalse(PasswordClipboard.shouldClear(changeCount: 7, recorded: 7, current: "other", copied: "pw"))
        XCTAssertFalse(PasswordClipboard.shouldClear(changeCount: 7, recorded: 7, current: nil, copied: "pw"))
        XCTAssertEqual(PasswordClipboard.clearDelay, 30)
    }

    // MARK: - List, edit, delete

    func testTheListFiltersBySiteAndUsername() throws {
        try seed("https://example.com", "alice", "pw")
        try seed("https://example.org", "bob", "pw")
        model.query = "exam bob"
        XCTAssertEqual(model.filtered.map(\.username), ["bob"])
        model.query = ""
        XCTAssertEqual(model.filtered.count, 2)
    }

    func testAddingValidatesEachField() async throws {
        var draft = model.newDraft()
        let noWebsite = await model.save(draft)
        XCTAssertEqual(noWebsite, "Enter a website such as example.com.")
        draft.website = "example.com"
        let noUsername = await model.save(draft)
        XCTAssertEqual(noUsername, "Enter a username.")
        draft.username = "alice"
        let noPassword = await model.save(draft)
        XCTAssertEqual(noPassword, "Enter a password.")
        draft.password = "typed-pw"
        let saved = await model.save(draft)
        XCTAssertNil(saved)
        XCTAssertTrue(authenticationReasons.isEmpty, "adding a login reveals nothing, so it asks for no authentication")

        let login = try XCTUnwrap(model.logins.first)
        XCTAssertEqual(login.origin, "https://example.com")
        XCTAssertEqual(login.username, "alice")
        XCTAssertEqual(login.password, "typed-pw")
        XCTAssertEqual(model.selected?.id, login.id)
    }

    func testEditingWithABlankPasswordKeepsTheSavedOneAndMovesTheSiteAfterAuthentication() async throws {
        let login = try seed("https://example.com", "alice", "keep-me")
        model.select(login.id)
        model.authenticate = { [unowned self] reason in
            self.authenticationReasons.append(reason)
            return true
        }
        var draft = try XCTUnwrap(model.draftForSelection())
        XCTAssertEqual(draft.password, "", "the saved password is never copied into the editor")
        draft.website = "accounts.example.org"
        draft.username = "alice2"
        let result = await model.save(draft)
        XCTAssertNil(result)
        XCTAssertEqual(authenticationReasons.count, 1)
        XCTAssertTrue(authenticationReasons[0].contains("example.com"), "the prompt names the login being changed")

        let edited = try XCTUnwrap(vault.login(id: login.id))
        XCTAssertEqual(edited.origin, "https://accounts.example.org")
        XCTAssertEqual(edited.siteKey, "example.org")
        XCTAssertEqual(edited.username, "alice2")
        XCTAssertEqual(edited.password, "keep-me")
    }

    func testChangingTheWebsiteFailsClosedWithoutAuthentication() async throws {
        let login = try seed("https://example.com", "alice", "stay-secret")
        model.select(login.id)
        var draft = try XCTUnwrap(model.draftForSelection())
        draft.website = "evil.test"

        let blank = await model.save(draft)
        XCTAssertNotNil(blank, "a refused authentication must refuse the edit")
        XCTAssertEqual(authenticationReasons.count, 1)

        // Typing a password does not get around it: the website is what lets a saved password be filled into a page the person controls.
        draft.password = "typed-instead"
        let typed = await model.save(draft)
        XCTAssertNotNil(typed)
        XCTAssertEqual(authenticationReasons.count, 2)

        let unchanged = try XCTUnwrap(vault.login(id: login.id))
        XCTAssertEqual(unchanged.origin, "https://example.com")
        XCTAssertEqual(unchanged.password, "stay-secret")
    }

    func testChangingOnlyTheSchemeOrPortCountsAsChangingTheWebsite() async throws {
        let login = try seed("https://example.com", "alice", "pw")
        model.select(login.id)
        for website in ["http://example.com", "https://example.com:8443", "https://www.example.com"] {
            var draft = try XCTUnwrap(model.draftForSelection())
            draft.website = website
            let result = await model.save(draft)
            XCTAssertNotNil(result, website)
        }
        XCTAssertEqual(authenticationReasons.count, 3)
        XCTAssertEqual(vault.login(id: login.id)?.origin, "https://example.com")
    }

    func testEditingTheUsernameOrPasswordAloneNeedsNoAuthentication() async throws {
        let login = try seed("https://example.com", "alice", "old-pw")
        model.select(login.id)
        var draft = try XCTUnwrap(model.draftForSelection())
        draft.username = "alice2"
        let renamed = await model.save(draft)
        XCTAssertNil(renamed)
        XCTAssertEqual(vault.login(id: login.id)?.username, "alice2")
        XCTAssertEqual(vault.login(id: login.id)?.password, "old-pw", "a blank password keeps the saved one while the website is unchanged")

        draft.password = "new-pw"
        let changed = await model.save(draft)
        XCTAssertNil(changed)
        XCTAssertEqual(vault.login(id: login.id)?.password, "new-pw")
        XCTAssertTrue(authenticationReasons.isEmpty)
    }

    func testTheSameWebsiteTypedAnotherWayIsNotAChange() async throws {
        let login = try seed("https://example.com", "alice", "old-pw")
        model.select(login.id)
        var draft = try XCTUnwrap(model.draftForSelection())
        draft.website = "  Example.COM/login?next=1 "
        let result = await model.save(draft)
        XCTAssertNil(result)
        XCTAssertTrue(authenticationReasons.isEmpty)
    }

    func testEditingWithANewPasswordReplacesIt() async throws {
        let login = try seed("https://example.com", "alice", "old-pw")
        model.select(login.id)
        var draft = try XCTUnwrap(model.draftForSelection())
        draft.password = "new-pw"
        let result = await model.save(draft)
        XCTAssertNil(result)
        XCTAssertEqual(vault.login(id: login.id)?.password, "new-pw")
    }

    func testDeletingNeedsConfirmation() throws {
        let login = try seed("https://example.com", "alice", "pw")
        model.select(login.id)

        model.deleteSelected()
        XCTAssertEqual(vault.allLogins().count, 1, "declining the confirmation keeps the login")

        model.confirmDelete = { true }
        model.deleteSelected()
        XCTAssertTrue(vault.allLogins().isEmpty)
        XCTAssertNil(model.selected)
    }

    func testRemovingANeverSaveSiteMakesItAskAgain() {
        vault.setNeverSave(true, forSiteKey: "example.com")
        model.reload()
        XCTAssertEqual(model.neverSaveSites, ["example.com"])
        model.removeNeverSave("example.com")
        XCTAssertTrue(model.neverSaveSites.isEmpty)
        XCTAssertFalse(vault.isNeverSave(siteKey: "example.com"))
    }

    // MARK: - Import

    private func withTemporaryFile(_ contents: String, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-passwords-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("passwords.csv")
        try Data(contents.utf8).write(to: file)
        try body(file)
    }

    func testImportingACSVMergesItAndReportsTheCounts() throws {
        try seed("https://example.com", "alice", "same-pw")
        try seed("https://example.com", "bob", "old-pw")
        let csv = """
        name,url,username,password,note
        example,https://example.com,alice,same-pw,
        example,https://example.com,bob,new-pw,
        other,https://other.test/login,carol,carol-pw,
        broken,https://broken.test,,no-username,
        """
        try withTemporaryFile(csv) { file in
            XCTAssertTrue(model.importFile(at: file))
        }
        let summary = try XCTUnwrap(model.statusMessage)
        XCTAssertEqual(summary, "Imported 3 passwords: 1 added, 1 updated, 1 unchanged. 1 skipped.")
        XCTAssertEqual(model.logins.count, 3)
        XCTAssertEqual(vault.allLogins().first { $0.username == "bob" }?.password, "new-pw")
    }

    func testImportingAFileThatIsNotAPasswordCSVSaysSoAndChangesNothing() throws {
        try withTemporaryFile("just some notes\nnothing here\n") { file in
            XCTAssertFalse(model.importFile(at: file))
        }
        XCTAssertEqual(model.statusMessage, "That file has no website and password columns, so Orbit cannot import it.")
        XCTAssertTrue(vault.allLogins().isEmpty)

        XCTAssertFalse(model.importFile(at: URL(fileURLWithPath: "/nonexistent/orbit-passwords-test.csv")))
        XCTAssertEqual(model.statusMessage, "That file could not be read.")
    }

    func testTheImportSummaryUsesTheRightNoun() {
        XCTAssertEqual(
            PasswordsSettingsModel.summaryText(for: PasswordCSV.MergeSummary(added: 1, updated: 0, unchanged: 0, skipped: 0)),
            "Imported 1 password: 1 added, 0 updated, 0 unchanged. 0 skipped."
        )
    }
}
