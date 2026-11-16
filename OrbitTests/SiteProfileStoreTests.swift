import XCTest

@MainActor
final class SiteProfileStoreTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: BrowserStore!
    private var spaceID: SpaceID!

    private let githubURL = URL(string: "https://www.github.com/orbit/pulls")!
    private let otherURL = URL(string: "https://accounts.example.org/login")!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-SiteProfileStore-\(UUID().uuidString)", isDirectory: true)
        store = BrowserStore(
            stateStore: StateStore(rootDirectory: scratchDirectory, maxBackups: 0),
            autoArchiveInterval: nil
        )
        spaceID = store.activeSpace!.id
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        store = nil
        spaceID = nil
        scratchDirectory = nil
        super.tearDown()
    }

    private func openTab(_ url: URL) -> TabID {
        store.openTab(url: url, in: spaceID, activate: false)
    }

    private var githubKey: String { SiteProfile.siteKey(for: githubURL)! }

    // MARK: - Site key

    func testSiteKeyIsTheRegistrableDomainOfAWebPage() {
        XCTAssertEqual(SiteProfile.siteKey(for: githubURL), "github.com")
        XCTAssertEqual(SiteProfile.siteKey(for: URL(string: "http://shop.example.co.uk/cart")!), "example.co.uk")
    }

    func testSiteKeyIsNilForPagesThatCannotHaveALogin() {
        XCTAssertNil(SiteProfile.siteKey(for: URL(string: "orbit://new-tab")!))
        XCTAssertNil(SiteProfile.siteKey(for: URL(string: "file:///tmp/page.html")!))
        XCTAssertNil(SiteProfile.siteKey(for: URL(string: "about:blank")!))
    }

    // MARK: - Naming rules

    func testCreateTrimsTheNameAndRecordsTheSite() throws {
        let created = try XCTUnwrap(store.createSiteProfile(name: "  Work  ", siteKey: githubKey))

        XCTAssertEqual(created.name, "Work")
        XCTAssertEqual(created.siteKey, "github.com")
        XCTAssertEqual(store.siteProfile(created.id), created)
        XCTAssertEqual(store.siteProfiles(forSiteKey: "github.com"), [created])
    }

    func testEmptyAndWhitespaceNamesAreRejected() {
        XCTAssertNil(store.createSiteProfile(name: "", siteKey: githubKey))
        XCTAssertNil(store.createSiteProfile(name: "   \n", siteKey: githubKey))
        XCTAssertTrue(store.siteProfiles.isEmpty)
    }

    func testTheImplicitDefaultNameCannotBeTaken() {
        XCTAssertNil(store.createSiteProfile(name: "Default", siteKey: githubKey))
        XCTAssertNil(store.createSiteProfile(name: " default ", siteKey: githubKey))
        XCTAssertTrue(store.siteProfiles.isEmpty)
    }

    func testNamesAreUniquePerSiteIgnoringCase() throws {
        XCTAssertNotNil(store.createSiteProfile(name: "Work", siteKey: githubKey))

        XCTAssertNil(store.createSiteProfile(name: "work", siteKey: githubKey), "Same site, same name apart from case.")
        XCTAssertNotNil(store.createSiteProfile(name: "Work", siteKey: "gitlab.com"), "Another site may reuse the name.")
        XCTAssertEqual(store.siteProfiles.count, 2)
    }

    func testRenameAppliesTheSameRulesAndMayChangeOnlyCase() throws {
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))
        let personal = try XCTUnwrap(store.createSiteProfile(name: "Personal", siteKey: githubKey))

        XCTAssertFalse(store.renameSiteProfile(personal.id, to: "WORK"), "Taken by another profile of the same site.")
        XCTAssertFalse(store.renameSiteProfile(personal.id, to: "  "))
        XCTAssertFalse(store.renameSiteProfile(personal.id, to: "Default"))
        XCTAssertEqual(store.siteProfile(personal.id)?.name, "Personal")

        XCTAssertTrue(store.renameSiteProfile(work.id, to: "WORK"), "A profile may be renamed to a different casing of its own name.")
        XCTAssertEqual(store.siteProfile(work.id)?.name, "WORK")
        XCTAssertTrue(store.renameSiteProfile(personal.id, to: " Home "))
        XCTAssertEqual(store.siteProfile(personal.id)?.name, "Home")
        XCTAssertFalse(store.renameSiteProfile(UUID(), to: "Ghost"))
    }

    func testProfilesOfOneSiteAreListedOldestFirst() throws {
        let first = try XCTUnwrap(store.createSiteProfile(name: "B", siteKey: githubKey))
        let second = try XCTUnwrap(store.createSiteProfile(name: "A", siteKey: githubKey))
        store.state.siteProfiles[1].createdAt = first.createdAt.addingTimeInterval(10)

        XCTAssertEqual(store.siteProfiles(forSiteKey: githubKey).map(\.id), [first.id, second.id])
    }

    // MARK: - Binding a tab

    func testBindingAndUnbindingATab() throws {
        let tabID = openTab(githubURL)
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))

        XCTAssertTrue(store.setSiteProfile(work.id, forTab: tabID))
        XCTAssertEqual(store.tab(tabID)?.siteProfileID, work.id)
        XCTAssertEqual(store.boundSiteProfile(forTab: tabID), work)
        XCTAssertEqual(store.siteProfileForSession(of: tabID), work)

        XCTAssertFalse(store.setSiteProfile(work.id, forTab: tabID), "Binding to the profile it already uses changes nothing.")
        XCTAssertTrue(store.setSiteProfile(nil, forTab: tabID))
        XCTAssertNil(store.tab(tabID)?.siteProfileID)
        XCTAssertNil(store.siteProfileForSession(of: tabID))
    }

    func testBindingToAnUnknownProfileIsRefused() {
        let tabID = openTab(githubURL)

        XCTAssertFalse(store.setSiteProfile(UUID(), forTab: tabID))
        XCTAssertNil(store.tab(tabID)?.siteProfileID)
    }

    func testABindingWhoseProfileIsGoneFallsBackToDefault() throws {
        let tabID = openTab(githubURL)
        store.state.tabs[tabID]?.siteProfileID = UUID()

        XCTAssertNil(store.boundSiteProfile(forTab: tabID))
        XCTAssertNil(store.siteProfileForSession(of: tabID))
        XCTAssertNil(store.siteProfileDropdownSiteKey(forTab: tabID))
    }

    func testDeletingAProfileSendsItsTabsBackToDefaultAndLeavesOthersAlone() throws {
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))
        let personal = try XCTUnwrap(store.createSiteProfile(name: "Personal", siteKey: githubKey))
        let boundToWork = openTab(githubURL)
        let alsoBoundToWork = openTab(githubURL)
        let boundToPersonal = openTab(githubURL)
        let unbound = openTab(githubURL)
        store.setSiteProfile(work.id, forTab: boundToWork)
        store.setSiteProfile(work.id, forTab: alsoBoundToWork)
        store.setSiteProfile(personal.id, forTab: boundToPersonal)

        let reset = store.deleteSiteProfile(work.id)

        XCTAssertEqual(Set(reset), [boundToWork, alsoBoundToWork])
        XCTAssertNil(store.siteProfile(work.id))
        XCTAssertNil(store.tab(boundToWork)?.siteProfileID)
        XCTAssertNil(store.tab(alsoBoundToWork)?.siteProfileID)
        XCTAssertEqual(store.tab(boundToPersonal)?.siteProfileID, personal.id)
        XCTAssertNil(store.tab(unbound)?.siteProfileID)
        XCTAssertEqual(store.siteProfiles, [personal])
        XCTAssertEqual(store.deleteSiteProfile(work.id), [], "Deleting twice is a no-op.")
    }

    // MARK: - Where profiles are offered

    func testProfilesAreOfferedOnlyForWebPages() {
        XCTAssertTrue(store.canOfferSiteProfiles(forTab: openTab(githubURL)))
        XCTAssertFalse(store.canOfferSiteProfiles(forTab: openTab(URL(string: "orbit://new-tab")!)))
        XCTAssertFalse(store.canOfferSiteProfiles(forTab: UUID()))
    }

    func testNothingIsOfferedOrHonouredInAnIncognitoSpace() throws {
        let incognitoProfile = store.createProfile(name: "Incognito", isPersistent: false)
        let incognitoSpace = store.createSpace(name: "Incognito", profileID: incognitoProfile, activate: false)
        let tabID = store.openTab(url: githubURL, in: incognitoSpace, activate: false)
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))

        XCTAssertFalse(store.canOfferSiteProfiles(forTab: tabID))
        XCTAssertFalse(store.setSiteProfile(work.id, forTab: tabID))

        store.state.tabs[tabID]?.siteProfileID = work.id
        XCTAssertNil(store.siteProfileForSession(of: tabID), "A leftover binding must never put a private tab on a persistent store.")
        XCTAssertNil(store.siteProfileDropdownSiteKey(forTab: tabID))
    }

    func testAnEphemeralSpaceOnAPersistentProfileOffersNothingNewButKeepsAnExistingBinding() throws {
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))
        let tornOffSpace = store.createSpace(name: "Torn off", activate: false)
        store.mutateSpace(tornOffSpace) { $0.ephemeral = true }
        let tabID = store.openTab(url: githubURL, in: tornOffSpace, activate: false)
        store.setSiteProfile(work.id, forTab: tabID)

        XCTAssertFalse(store.canOfferSiteProfiles(forTab: tabID))
        XCTAssertEqual(store.siteProfileForSession(of: tabID), work, "A torn-off window keeps the identity its tab had.")
        XCTAssertEqual(store.siteProfileDropdownSiteKey(forTab: tabID), "github.com")
    }

    // MARK: - The address-field dropdown

    func testNoDropdownUntilTheSiteHasAProfile() throws {
        let tabID = openTab(githubURL)
        XCTAssertNil(store.siteProfileDropdownSiteKey(forTab: tabID))

        _ = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))

        XCTAssertEqual(store.siteProfileDropdownSiteKey(forTab: tabID), "github.com")
        XCTAssertNil(store.siteProfileDropdownSiteKey(forTab: openTab(otherURL)), "Another site has no profiles.")
        XCTAssertNil(store.siteProfileDropdownSiteKey(forTab: openTab(URL(string: "orbit://new-tab")!)))
    }

    func testABoundTabKeepsItsDropdownAcrossASignInRedirectToAnotherSite() throws {
        let tabID = openTab(githubURL)
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))
        store.setSiteProfile(work.id, forTab: tabID)

        store.state.tabs[tabID]?.url = otherURL

        XCTAssertEqual(store.siteProfileDropdownSiteKey(forTab: tabID), "github.com")
        XCTAssertEqual(store.siteProfileForSession(of: tabID), work, "The sign-in page loads in the same identity.")

        store.state.tabs[tabID]?.url = URL(string: "orbit://settings")!
        XCTAssertNil(store.siteProfileDropdownSiteKey(forTab: tabID), "Never on an internal page.")
    }

    // MARK: - Codable

    func testTabRoundTripsItsSiteProfileID() throws {
        let id = UUID()
        let tab = Tab(spaceID: UUID(), url: githubURL, siteProfileID: id)

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))

        XCTAssertEqual(decoded.siteProfileID, id)
        XCTAssertEqual(decoded, tab)
    }

    func testATabWrittenBeforeSiteProfilesExistedStillDecodes() throws {
        let tab = Tab(spaceID: UUID(), url: githubURL, siteProfileID: UUID())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        XCTAssertNotNil(object["siteProfileID"], "The fixture must contain the key it is about to strip.")
        object.removeValue(forKey: "siteProfileID")

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.siteProfileID)
        XCTAssertEqual(decoded.url, githubURL)
    }

    func testStateRoundTripsSiteProfilesThroughTheStateStore() throws {
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))
        let tabID = openTab(githubURL)
        store.setSiteProfile(work.id, forTab: tabID)

        try store.saveNow()
        let reloaded = try store.stateStore.load()

        XCTAssertEqual(reloaded.siteProfiles.map(\.id), [work.id])
        XCTAssertEqual(reloaded.siteProfiles.map(\.siteKey), [work.siteKey])
        XCTAssertEqual(reloaded.siteProfiles.map(\.name), [work.name])
        XCTAssertEqual(reloaded.tabs[tabID]?.siteProfileID, work.id)
    }

    func testAStateFileWithoutTheSiteProfilesKeyStillLoads() throws {
        try store.saveNow()
        let url = store.stateStore.stateFileURL
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(object["siteProfiles"], "A document that never used the feature must not grow a new key.")
        object.removeValue(forKey: "siteProfiles")
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let reloaded = try store.stateStore.load()

        XCTAssertTrue(reloaded.siteProfiles.isEmpty)
        XCTAssertEqual(reloaded.spaces.map(\.id), store.state.spaces.map(\.id))
    }

    func testTheSiteProfilesKeyIsWrittenOnceAProfileExists() throws {
        _ = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))
        try store.saveNow()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.stateStore.stateFileURL)) as? [String: Any]
        )

        XCTAssertEqual((object["siteProfiles"] as? [Any])?.count, 1)
    }

    // MARK: - Copies keep the identity

    func testDuplicatingATabKeepsItsSiteProfile() throws {
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))
        let tabID = openTab(githubURL)
        store.setSiteProfile(work.id, forTab: tabID)

        let copyID = try XCTUnwrap(store.duplicateTab(tabID))

        XCTAssertEqual(store.tab(copyID)?.siteProfileID, work.id)
    }

    func testSessionIdentifierIsDerivedFromTheProfileIDAndNeverCollidesWithAnOrbitProfile() throws {
        let work = try XCTUnwrap(store.createSiteProfile(name: "Work", siteKey: githubKey))

        XCTAssertEqual(work.sessionIdentifier, "site-\(work.id.uuidString)")
        XCTAssertNotEqual(work.sessionIdentifier, store.profiles.first?.sessionIdentifier)
    }
}
