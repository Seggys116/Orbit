import Security
import XCTest

/// A clock that moves forward one second each time it is read, so saved and used times are distinct and predictable.
nonisolated final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.withLock {
            defer { current = current.addingTimeInterval(1) }
            return current
        }
    }
}

nonisolated private func pageURL(_ string: String) -> URL { URL(string: string)! }

// MARK: - In-memory vault

final class PasswordVaultTests: XCTestCase {

    private var clock: StepClock!
    private var vault: InMemoryPasswordVault!

    override func setUp() {
        super.setUp()
        let clock = StepClock()
        self.clock = clock
        vault = InMemoryPasswordVault(now: { clock.now() })
    }

    override func tearDown() {
        vault = nil
        clock = nil
        super.tearDown()
    }

    @discardableResult
    private func save(_ origin: String, _ username: String, _ password: String = "pw") -> SavedLogin {
        switch vault.save(origin: pageURL(origin), username: username, password: password) {
        case .added(let login), .updated(let login), .unchanged(let login): return login
        case nil:
            XCTFail("save returned nil for \(origin) \(username)")
            return SavedLogin(origin: origin, siteKey: "", username: username, password: password)
        }
    }

    /// `origin username` pairs in the order the vault returns them.
    private func matches(_ page: String) -> [String] {
        vault.logins(matching: pageURL(page)).map { "\($0.origin) \($0.username)" }
    }

    // MARK: - save

    func testSaveAddsALoginAndNormalisesTheOrigin() {
        let outcome = vault.save(origin: pageURL("https://WWW.Example.com/login?next=/a#top"), username: "  alice  ", password: "s3cret")
        guard case .added(let login) = outcome else { return XCTFail("expected added, got \(String(describing: outcome))") }
        XCTAssertEqual(login.origin, "https://www.example.com")
        XCTAssertEqual(login.siteKey, "example.com")
        XCTAssertEqual(login.username, "alice")
        XCTAssertEqual(login.password, "s3cret")
        XCTAssertNil(login.lastUsedAt)
        XCTAssertEqual(login.createdAt, login.updatedAt)
        XCTAssertEqual(vault.allLogins(), [login])
        XCTAssertEqual(vault.login(id: login.id), login)
    }

    func testSaveKeepsThePasswordExactlyAsGiven() {
        let login = save("https://example.com", "alice", "  spaced \n")
        XCTAssertEqual(login.password, "  spaced \n")
    }

    func testSaveDropsCredentialsPathAndTheDefaultPortFromTheOrigin() {
        let login = save("https://bob:hunter2@example.com:443/a/b?c=d", "alice")
        XCTAssertEqual(login.origin, "https://example.com")
        XCTAssertEqual(save("http://example.com:80/", "alice").origin, "http://example.com")
    }

    func testSaveRefusesEmptyUsernameEmptyPasswordAndNonHTTPPages() {
        XCTAssertNil(vault.save(origin: pageURL("https://example.com"), username: "", password: "pw"))
        XCTAssertNil(vault.save(origin: pageURL("https://example.com"), username: " \t\n", password: "pw"))
        XCTAssertNil(vault.save(origin: pageURL("https://example.com"), username: "alice", password: ""))
        for page in ["about:blank", "file:///Users/a/index.html", "ftp://example.com", "chrome://settings", "data:text/html,hi", "mailto:a@example.com"] {
            XCTAssertNil(vault.save(origin: pageURL(page), username: "alice", password: "pw"), page)
        }
        XCTAssertTrue(vault.allLogins().isEmpty)
    }

    func testSaveForTheSameOriginAndUsernameReplacesThePassword() {
        let first = save("https://example.com", "alice", "old")
        let outcome = vault.save(origin: pageURL("https://example.com/other"), username: "alice", password: "new")
        guard case .updated(let second) = outcome else { return XCTFail("expected updated, got \(String(describing: outcome))") }
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertGreaterThan(second.updatedAt, first.updatedAt)
        XCTAssertEqual(second.password, "new")
        XCTAssertEqual(vault.allLogins(), [second])
    }

    func testSaveOfTheSamePasswordIsUnchangedAndLeavesUpdatedAtAlone() {
        let first = save("https://example.com", "alice", "pw")
        let outcome = vault.save(origin: pageURL("https://example.com"), username: "alice", password: "pw")
        XCTAssertEqual(outcome, .unchanged(first))
        XCTAssertEqual(vault.login(id: first.id)?.updatedAt, first.updatedAt)
    }

    func testTheSameUsernameOnAnotherOriginIsAnotherEntry() {
        let a = save("https://example.com", "alice")
        let b = save("https://app.example.com", "alice")
        let c = save("https://example.com:8443", "alice")
        XCTAssertEqual(Set([a.id, b.id, c.id]).count, 3)
        XCTAssertEqual(vault.allLogins().count, 3)
    }

    func testTheSameOriginWithAnotherUsernameIsAnotherEntry() {
        save("https://example.com", "alice")
        save("https://example.com", "bob")
        XCTAssertEqual(vault.allLogins().count, 2)
    }

    // MARK: - update

    func testUpdateReplacesOriginUsernameAndPasswordAndKeepsIdentity() {
        let original = save("https://example.com", "alice", "old")
        vault.markUsed(id: original.id)
        let used = vault.login(id: original.id)!
        var edit = used
        edit.origin = "https://www.example.org/path"
        edit.username = " alicia "
        edit.password = "new"
        edit.siteKey = "wrong"
        XCTAssertTrue(vault.update(edit))

        let stored = vault.login(id: original.id)!
        XCTAssertEqual(stored.origin, "https://www.example.org")
        XCTAssertEqual(stored.siteKey, "example.org")
        XCTAssertEqual(stored.username, "alicia")
        XCTAssertEqual(stored.password, "new")
        XCTAssertEqual(stored.createdAt, original.createdAt)
        XCTAssertEqual(stored.lastUsedAt, used.lastUsedAt)
        XCTAssertGreaterThan(stored.updatedAt, used.updatedAt)
        XCTAssertEqual(vault.allLogins().count, 1)
    }

    func testUpdateOfAnUnknownIdIsFalse() {
        let ghost = SavedLogin(origin: "https://example.com", siteKey: "example.com", username: "alice", password: "pw")
        XCTAssertFalse(vault.update(ghost))
        XCTAssertTrue(vault.allLogins().isEmpty)
    }

    func testUpdateRefusesAnUnusableReplacementAndLeavesTheEntryAlone() {
        let original = save("https://example.com", "alice", "pw")
        var edit = original
        edit.password = ""
        XCTAssertFalse(vault.update(edit))
        edit = original
        edit.username = "   "
        XCTAssertFalse(vault.update(edit))
        edit = original
        edit.origin = "ftp://example.com"
        XCTAssertFalse(vault.update(edit))
        XCTAssertEqual(vault.login(id: original.id), original)
    }

    func testUpdateWithNothingChangedKeepsUpdatedAt() {
        let original = save("https://example.com", "alice", "pw")
        XCTAssertTrue(vault.update(original))
        XCTAssertEqual(vault.login(id: original.id), original)
    }

    func testUpdateOntoAnExistingOriginAndUsernameKeepsThePairUnique() {
        let kept = save("https://example.com", "alice", "one")
        let moved = save("https://example.org", "alice", "two")
        var edit = moved
        edit.origin = "https://example.com"
        XCTAssertTrue(vault.update(edit))
        XCTAssertNil(vault.login(id: kept.id))
        XCTAssertEqual(vault.allLogins().map(\.id), [moved.id])
        XCTAssertEqual(vault.allLogins().first?.password, "two")
    }

    // MARK: - delete and use

    func testDeleteRemovesOnlyThatLogin() {
        let a = save("https://example.com", "alice")
        let b = save("https://example.com", "bob")
        vault.delete(id: a.id)
        XCTAssertNil(vault.login(id: a.id))
        XCTAssertEqual(vault.allLogins(), [b])
        vault.delete(id: a.id)
        XCTAssertEqual(vault.allLogins(), [b])
    }

    func testDeleteAllRemovesEveryLogin() {
        save("https://example.com", "alice")
        save("https://example.org", "bob")
        vault.deleteAll()
        XCTAssertTrue(vault.allLogins().isEmpty)
        XCTAssertTrue(matches("https://example.com").isEmpty)
    }

    func testMarkUsedSetsLastUsedAtAndIgnoresUnknownIds() {
        let login = save("https://example.com", "alice")
        vault.markUsed(id: UUID())
        XCTAssertNil(vault.login(id: login.id)?.lastUsedAt)
        vault.markUsed(id: login.id)
        let used = vault.login(id: login.id)
        XCTAssertNotNil(used?.lastUsedAt)
        XCTAssertGreaterThan(used!.lastUsedAt!, login.createdAt)
        XCTAssertEqual(used?.password, "pw")
    }

    func testAllLoginsIsOrderedBySiteThenOriginThenUsername() {
        save("https://www.zeta.com", "bob")
        save("https://www.alpha.com", "carol")
        save("https://alpha.com", "Dave")
        save("https://alpha.com", "alice")
        XCTAssertEqual(
            vault.allLogins().map { "\($0.origin) \($0.username)" },
            ["https://alpha.com alice", "https://alpha.com Dave", "https://www.alpha.com carol", "https://www.zeta.com bob"]
        )
    }

    // MARK: - never save

    func testNeverSaveListIsNormalisedSortedAndReversible() {
        XCTAssertTrue(vault.neverSaveSiteKeys().isEmpty)
        vault.setNeverSave(true, forSiteKey: " Example.COM ")
        vault.setNeverSave(true, forSiteKey: "bank.org")
        vault.setNeverSave(true, forSiteKey: "example.com")
        vault.setNeverSave(true, forSiteKey: "   ")
        XCTAssertEqual(vault.neverSaveSiteKeys(), ["bank.org", "example.com"])
        XCTAssertTrue(vault.isNeverSave(siteKey: "example.com"))
        XCTAssertTrue(vault.isNeverSave(siteKey: "EXAMPLE.com"))
        XCTAssertFalse(vault.isNeverSave(siteKey: "example.org"))
        vault.setNeverSave(false, forSiteKey: "example.com")
        XCTAssertEqual(vault.neverSaveSiteKeys(), ["bank.org"])
    }

    func testNeverSaveDoesNotStopTheVaultSavingWhenAskedDirectly() {
        vault.setNeverSave(true, forSiteKey: "example.com")
        XCTAssertNotNil(vault.save(origin: pageURL("https://example.com"), username: "alice", password: "pw"))
    }

    func testDeleteAllLeavesTheNeverSaveList() {
        vault.setNeverSave(true, forSiteKey: "example.com")
        save("https://example.com", "alice")
        vault.deleteAll()
        XCTAssertTrue(vault.isNeverSave(siteKey: "example.com"))
    }

    // MARK: - Matching: origin and site

    func testSameOriginComesBeforeSameSiteWhateverTheSaveOrder() {
        save("https://login.example.com", "site-login")
        save("https://www.example.com", "origin-login")
        XCTAssertEqual(
            matches("https://www.example.com/account"),
            ["https://www.example.com origin-login", "https://login.example.com site-login"]
        )
    }

    func testASubdomainOfTheSameSiteMatches() {
        save("https://example.com", "alice")
        XCTAssertEqual(matches("https://shop.example.com/cart"), ["https://example.com alice"])
        XCTAssertEqual(matches("https://a.b.c.example.com"), ["https://example.com alice"])
    }

    func testAParentDomainPageMatchesLoginsSavedOnSubdomains() {
        save("https://accounts.example.com", "alice")
        XCTAssertEqual(matches("https://example.com"), ["https://accounts.example.com alice"])
    }

    func testOtherSitesNeverMatch() {
        save("https://example.com", "alice")
        for page in [
            "https://example.org", "https://notexample.com", "https://example.com.evil.com",
            "https://evil-example.com", "https://evil.com/example.com", "https://example.co",
        ] {
            XCTAssertTrue(matches(page).isEmpty, page)
        }
    }

    func testTwoPartPublicSuffixesAreRespected() {
        save("https://www.bbc.co.uk", "alice")
        XCTAssertEqual(matches("https://news.bbc.co.uk"), ["https://www.bbc.co.uk alice"])
        XCTAssertTrue(matches("https://www.itv.co.uk").isEmpty)
        XCTAssertTrue(matches("https://co.uk").isEmpty)
    }

    func testHostCaseTrailingDotPathAndFragmentDoNotChangeTheOrigin() {
        save("https://Example.COM", "alice")
        XCTAssertEqual(matches("https://example.com./a/b?c#d"), ["https://example.com alice"])
        XCTAssertEqual(vault.allLogins().count, 1)
    }

    // MARK: - Matching: ports and schemes

    func testThePortIsPartOfTheOrigin() {
        save("http://localhost:3000", "dev-3000")
        save("http://localhost:8080", "dev-8080")
        XCTAssertEqual(matches("http://localhost:3000/login"), ["http://localhost:3000 dev-3000", "http://localhost:8080 dev-8080"])
        XCTAssertEqual(matches("http://localhost:8080/"), ["http://localhost:8080 dev-8080", "http://localhost:3000 dev-3000"])
    }

    func testAnotherPortOnTheSameHostIsOnlyASiteMatch() {
        save("https://example.com:8443", "alt")
        save("https://example.com", "main")
        XCTAssertEqual(matches("https://example.com"), ["https://example.com main", "https://example.com:8443 alt"])
        XCTAssertEqual(matches("https://example.com:8443"), ["https://example.com:8443 alt", "https://example.com main"])
    }

    func testTheDefaultPortMatchesTheOriginWithoutAPort() {
        save("https://example.com", "main")
        XCTAssertEqual(matches("https://example.com:443/x"), ["https://example.com main"])
        save("http://example.org", "plain")
        XCTAssertEqual(matches("http://example.org:80/x"), ["http://example.org plain"])
    }

    func testHTTPAndHTTPSOriginsOfTheSameHostAreDistinctEntries() {
        save("http://example.com", "plain")
        save("https://example.com", "secure")
        XCTAssertEqual(vault.allLogins().count, 2)
    }

    func testAnHTTPSLoginIsNeverMatchedForAnHTTPPage() {
        save("https://example.com", "secure")
        save("https://shop.example.com", "shop")
        save("https://example.com:8443", "alt")
        for page in ["http://example.com", "http://example.com:80/x", "http://www.example.com", "http://example.com:8443", "http://shop.example.com/cart"] {
            XCTAssertTrue(matches(page).isEmpty, "an https login reached \(page)")
        }
    }

    func testAnHTTPSLoginIsNeverMatchedForAnHTTPLocalPage() {
        save("https://localhost:8443", "dev")
        save("https://127.0.0.1:8443", "dev")
        save("https://[::1]:8443", "dev")
        XCTAssertTrue(matches("http://localhost:3000").isEmpty)
        XCTAssertTrue(matches("http://127.0.0.1:3000").isEmpty)
        XCTAssertTrue(matches("http://[::1]:3000").isEmpty)
    }

    func testAnHTTPPageOnlyGetsLoginsSavedOverHTTP() {
        save("http://example.com", "plain")
        save("http://shop.example.com", "plain-shop")
        save("https://example.com", "secure")
        XCTAssertEqual(matches("http://example.com"), ["http://example.com plain", "http://shop.example.com plain-shop"])
        XCTAssertEqual(matches("http://www.example.com"), ["http://shop.example.com plain-shop", "http://example.com plain"])
    }

    func testAnHTTPSPageStillGetsTheSameSitesHTTPLogins() {
        save("http://example.com", "plain")
        save("https://example.com", "secure")
        XCTAssertEqual(matches("https://example.com"), ["https://example.com secure", "http://example.com plain"])
    }

    // MARK: - Matching: addresses and local hosts

    func testIPv4AddressesMatchOnlyTheSameAddress() {
        save("http://192.168.1.5:8080", "router")
        XCTAssertEqual(matches("http://192.168.1.5:8080/admin"), ["http://192.168.1.5:8080 router"])
        XCTAssertEqual(matches("http://192.168.1.5/"), ["http://192.168.1.5:8080 router"])
        XCTAssertTrue(matches("http://192.168.1.6:8080").isEmpty)
        XCTAssertTrue(matches("http://192.168.5:8080").isEmpty)
        XCTAssertTrue(matches("http://10.0.0.5").isEmpty)
    }

    func testIPv6AddressesMatchOnlyTheSameAddress() {
        let login = save("http://[::1]:3000", "dev")
        XCTAssertEqual(login.origin, "http://[::1]:3000")
        XCTAssertEqual(matches("http://[::1]:3000/x"), ["http://[::1]:3000 dev"])
        XCTAssertEqual(matches("http://[::1]/x"), ["http://[::1]:3000 dev"])
        XCTAssertTrue(matches("http://[::2]:3000").isEmpty)
    }

    func testLocalhostIsItsOwnSiteAndNotASuffixOfAnother() {
        save("http://localhost:3000", "dev")
        XCTAssertEqual(matches("http://localhost:3000"), ["http://localhost:3000 dev"])
        XCTAssertTrue(matches("http://notlocalhost:3000").isEmpty)
        XCTAssertTrue(matches("http://localhost.example.com:3000").isEmpty)
        XCTAssertTrue(matches("http://127.0.0.1:3000").isEmpty)
    }

    func testAnIPAddressDoesNotMatchADomainEndingInThoseDigits() {
        save("http://1.2.3.4", "ip")
        XCTAssertTrue(matches("http://example.1.2.3.4").isEmpty)
        XCTAssertTrue(matches("http://3.4").isEmpty)
    }

    // MARK: - Matching: pages that are not http(s)

    func testNonHTTPPagesNeverMatch() {
        save("https://example.com", "alice")
        for page in [
            "about:blank", "file:///Users/a/example.com/index.html", "data:text/html,example.com",
            "ftp://example.com", "chrome-extension://abcdef/popup.html", "mailto:a@example.com", "javascript:void(0)",
            "orbit://settings",
        ] {
            XCTAssertTrue(matches(page).isEmpty, page)
        }
    }

    // MARK: - Matching: recency

    func testWithinAGroupTheMostRecentlyUsedComesFirst() {
        let first = save("https://example.com", "first")
        let second = save("https://example.com", "second")
        let third = save("https://example.com", "third")
        XCTAssertEqual(matches("https://example.com"), ["https://example.com third", "https://example.com second", "https://example.com first"])

        vault.markUsed(id: first.id)
        XCTAssertEqual(matches("https://example.com").map { $0.split(separator: " ").last! }, ["first", "third", "second"])
        vault.markUsed(id: second.id)
        XCTAssertEqual(matches("https://example.com").map { $0.split(separator: " ").last! }, ["second", "first", "third"])
        vault.markUsed(id: third.id)
        XCTAssertEqual(matches("https://example.com").map { $0.split(separator: " ").last! }, ["third", "second", "first"])
    }

    func testRecencyOrdersTheSiteGroupToo() {
        let older = save("https://a.example.com", "older")
        save("https://b.example.com", "newer")
        XCTAssertEqual(matches("https://www.example.com"), ["https://b.example.com newer", "https://a.example.com older"])
        vault.markUsed(id: older.id)
        XCTAssertEqual(matches("https://www.example.com"), ["https://a.example.com older", "https://b.example.com newer"])
    }

    func testARecentlyUsedSiteLoginNeverOutranksAnOriginLogin() {
        save("https://www.example.com", "origin")
        let site = save("https://login.example.com", "site")
        vault.markUsed(id: site.id)
        XCTAssertEqual(matches("https://www.example.com"), ["https://www.example.com origin", "https://login.example.com site"])
    }

    func testChangingAPasswordCountsAsRecentActivity() {
        save("https://example.com", "first", "a")
        save("https://example.com", "second", "b")
        save("https://example.com", "first", "changed")
        XCTAssertEqual(matches("https://example.com").map { $0.split(separator: " ").last! }, ["first", "second"])
    }

    // MARK: - Notifications and threads

    func testAChangeMadeOffTheMainThreadPostsTheNotificationOnTheMainThread() {
        let posted = expectation(description: "vault changed")
        posted.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(forName: .orbitPasswordVaultDidChange, object: vault, queue: nil) { _ in
            XCTAssertTrue(Thread.isMainThread)
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let target = vault!
        DispatchQueue.global().async {
            target.save(origin: pageURL("https://example.com"), username: "alice", password: "pw")
        }
        wait(for: [posted], timeout: 5)
    }

    private func expectNotification(_ description: String, during action: () -> Void) {
        let posted = XCTNSNotificationExpectation(name: .orbitPasswordVaultDidChange, object: vault)
        posted.expectationDescription = description
        action()
        wait(for: [posted], timeout: 5)
    }

    func testEveryKindOfChangePostsTheNotification() {
        var login: SavedLogin!
        expectNotification("add") { login = save("https://example.com", "alice", "a") }
        expectNotification("replace password") { save("https://example.com", "alice", "b") }
        expectNotification("mark used") { vault.markUsed(id: login.id) }
        expectNotification("update") {
            var edit = vault.login(id: login.id)!
            edit.password = "c"
            vault.update(edit)
        }
        expectNotification("never save on") { vault.setNeverSave(true, forSiteKey: "example.com") }
        expectNotification("never save off") { vault.setNeverSave(false, forSiteKey: "example.com") }
        expectNotification("delete") { vault.delete(id: login.id) }
        save("https://example.com", "bob", "pw")
        expectNotification("delete all") { vault.deleteAll() }
    }

    func testACallThatChangesNothingPostsNothing() {
        let login = save("https://example.com", "alice", "b")
        // The notification for the save above may still be queued; let it arrive first.
        expectNotification("setup") { vault.setNeverSave(true, forSiteKey: "example.com") }

        let silent = XCTNSNotificationExpectation(name: .orbitPasswordVaultDidChange, object: vault)
        silent.isInverted = true
        vault.delete(id: UUID())
        vault.markUsed(id: UUID())
        vault.setNeverSave(true, forSiteKey: "example.com")
        vault.setNeverSave(false, forSiteKey: "never-added.org")
        vault.save(origin: pageURL("https://example.com"), username: "alice", password: "b")
        vault.save(origin: pageURL("about:blank"), username: "alice", password: "b")
        vault.update(login)
        wait(for: [silent], timeout: 0.4)
    }

    func testConcurrentSavesAreAllKept() {
        let target = vault!
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            target.save(origin: pageURL("https://example.com"), username: "user\(index)", password: "pw")
            _ = target.logins(matching: pageURL("https://www.example.com"))
        }
        XCTAssertEqual(vault.allLogins().count, 200)
        XCTAssertEqual(Set(vault.allLogins().map(\.username)).count, 200)
    }

    // MARK: - Shared vault

    func testTheSharedVaultIsTheInMemoryOneUnderTest() {
        #if DEBUG
        PasswordVaults.resetShared()
        defer { PasswordVaults.resetShared() }
        XCTAssertTrue(PasswordVaults.shared is InMemoryPasswordVault)
        XCTAssertTrue(PasswordVaults.shared === PasswordVaults.shared)
        #endif
    }

    func testASharedVaultCanBeInjectedAndRemoved() {
        #if DEBUG
        PasswordVaults.resetShared()
        defer { PasswordVaults.resetShared() }
        let injected = InMemoryPasswordVault()
        PasswordVaults.shared = injected
        XCTAssertTrue(PasswordVaults.shared === injected)
        PasswordVaults.resetShared()
        XCTAssertFalse(PasswordVaults.shared === injected)
        #endif
    }

    func testTheKeychainServiceUnderTestIsNeverTheProductionOne() {
        XCTAssertNotEqual(KeychainPasswordVault.defaultService, KeychainPasswordVault.productionService)
        XCTAssertEqual(KeychainPasswordVault.defaultService, KeychainPasswordVault.productionService + ".test")
    }
}

// MARK: - Keychain vault

/// Runs against the real login keychain, but only under a service name made up for each test and removed afterwards, so no item of the app's own is read or written. Skipped when the keychain cannot be written.
final class KeychainPasswordVaultTests: XCTestCase {

    private var service: String!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var clock: StepClock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        service = "\(KeychainPasswordVault.productionService).xctest-\(UUID().uuidString)"
        suiteName = "OrbitTests.KeychainVault.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        clock = StepClock()

        let probe = makeVault()
        guard probe.save(origin: pageURL("https://probe.example.com"), username: "probe", password: "pw") != nil else {
            probe.deleteAll()
            throw XCTSkip("The login keychain cannot be written in this environment.")
        }
        probe.deleteAll()
    }

    override func tearDown() {
        if let service {
            // A fresh instance, in case a test left the cached one in an odd state.
            KeychainPasswordVault(service: service, defaults: defaults).deleteAll()
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        service = nil
        suiteName = nil
        clock = nil
        super.tearDown()
    }

    private func makeVault() -> KeychainPasswordVault {
        let clock = clock!
        return KeychainPasswordVault(service: service, defaults: defaults, now: { clock.now() })
    }

    private func pairs(_ logins: [SavedLogin]) -> [String] {
        logins.map { "\($0.origin) \($0.username)" }
    }

    func testASavedLoginComesBackExactlyFromANewVaultOverTheSameService() throws {
        let writer = makeVault()
        let outcome = writer.save(origin: pageURL("https://www.example.com/login"), username: "alice", password: "p@ss \"word\", \u{00E9}\u{1F512}\nline2")
        guard case .added(let saved) = outcome else { return XCTFail("expected added, got \(String(describing: outcome))") }

        let reader = makeVault()
        XCTAssertEqual(reader.allLogins(), [saved])
        XCTAssertEqual(reader.login(id: saved.id), saved)
        XCTAssertEqual(reader.login(id: saved.id)?.password, "p@ss \"word\", \u{00E9}\u{1F512}\nline2")
    }

    func testReplacementUseUpdateAndDeleteAreVisibleToANewVault() {
        let vault = makeVault()
        let alice = vault.save(origin: pageURL("https://example.com"), username: "alice", password: "one")
        guard case .added(let aliceLogin) = alice else { return XCTFail("expected added") }
        let replaced = vault.save(origin: pageURL("https://example.com"), username: "alice", password: "two")
        guard case .updated(let replacedLogin) = replaced else { return XCTFail("expected updated") }
        XCTAssertEqual(replacedLogin.id, aliceLogin.id)
        XCTAssertEqual(makeVault().allLogins().map(\.password), ["two"])

        vault.markUsed(id: aliceLogin.id)
        XCTAssertNotNil(makeVault().login(id: aliceLogin.id)?.lastUsedAt)

        var edit = vault.login(id: aliceLogin.id)!
        edit.username = "alicia"
        edit.origin = "https://example.org"
        XCTAssertTrue(vault.update(edit))
        let afterEdit = makeVault().allLogins()
        XCTAssertEqual(pairs(afterEdit), ["https://example.org alicia"])
        XCTAssertEqual(afterEdit.first?.siteKey, "example.org")

        vault.delete(id: aliceLogin.id)
        XCTAssertTrue(makeVault().allLogins().isEmpty)
    }

    func testDeleteAllRemovesEveryItemUnderTheService() {
        let vault = makeVault()
        for index in 0..<4 { vault.save(origin: pageURL("https://example.com"), username: "user\(index)", password: "pw") }
        XCTAssertEqual(makeVault().allLogins().count, 4)
        vault.deleteAll()
        XCTAssertTrue(vault.allLogins().isEmpty)
        XCTAssertTrue(makeVault().allLogins().isEmpty)
    }

    func testAnotherServiceDoesNotSeeTheItems() {
        makeVault().save(origin: pageURL("https://example.com"), username: "alice", password: "pw")
        let other = KeychainPasswordVault(service: service + ".other", defaults: defaults)
        XCTAssertTrue(other.allLogins().isEmpty)
        other.deleteAll()
        XCTAssertEqual(makeVault().allLogins().count, 1)
    }

    func testEachItemIsLabelledWithItsOriginAndUsername() throws {
        makeVault().save(origin: pageURL("https://example.com:8443/x"), username: "alice", password: "pw")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service!,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let rows = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?[kSecAttrLabel as String] as? String, "https://example.com:8443 (alice)")
        XCTAssertNotNil(UUID(uuidString: rows.first?[kSecAttrAccount as String] as? String ?? ""))
    }

    func testMatchingFollowsTheSameRulesAsTheInMemoryVault() {
        let vault = makeVault()
        vault.save(origin: pageURL("https://login.example.com"), username: "site", password: "pw")
        vault.save(origin: pageURL("https://www.example.com"), username: "origin", password: "pw")
        vault.save(origin: pageURL("https://www.example.org"), username: "other", password: "pw")
        XCTAssertEqual(
            pairs(vault.logins(matching: pageURL("https://www.example.com/a"))),
            ["https://www.example.com origin", "https://login.example.com site"]
        )
        XCTAssertTrue(vault.logins(matching: pageURL("about:blank")).isEmpty)
        XCTAssertEqual(
            pairs(makeVault().logins(matching: pageURL("https://www.example.com/a"))),
            ["https://www.example.com origin", "https://login.example.com site"]
        )
    }

    func testAnHTTPSLoginIsNeverMatchedForAnHTTPPage() {
        let vault = makeVault()
        vault.save(origin: pageURL("https://example.com"), username: "secure", password: "pw")
        vault.save(origin: pageURL("http://example.com"), username: "plain", password: "pw")
        XCTAssertEqual(pairs(vault.logins(matching: pageURL("http://example.com/login"))), ["http://example.com plain"])
        XCTAssertEqual(pairs(makeVault().logins(matching: pageURL("http://www.example.com"))), ["http://example.com plain"])
    }

    func testTheNeverSaveListLivesInTheSuppliedDefaults() {
        let vault = makeVault()
        vault.setNeverSave(true, forSiteKey: "Example.com")
        XCTAssertEqual(vault.neverSaveSiteKeys(), ["example.com"])
        XCTAssertEqual(defaults.stringArray(forKey: KeychainPasswordVault.neverSaveDefaultsKey), ["example.com"])
        XCTAssertTrue(makeVault().isNeverSave(siteKey: "example.com"))
        vault.setNeverSave(false, forSiteKey: "example.com")
        XCTAssertFalse(makeVault().isNeverSave(siteKey: "example.com"))
    }

    func testTheNeverSaveKeyIsNamespacedToTheApp() {
        XCTAssertTrue(KeychainPasswordVault.neverSaveDefaultsKey.hasPrefix("Orbit"))
    }
}
