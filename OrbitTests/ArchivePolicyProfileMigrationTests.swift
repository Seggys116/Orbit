import XCTest

@MainActor
final class ArchivePolicyProfileMigrationTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-ArchivePolicyMigration-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        scratchDirectory = nil
        super.tearDown()
    }

    private func makeStateStore() -> StateStore { StateStore(rootDirectory: scratchDirectory) }

    private func makeStore() -> BrowserStore {
        BrowserStore(stateStore: makeStateStore(), autoArchiveInterval: nil)
    }

    private func reload(_ document: OrbitState) throws -> BrowserStore {
        try makeStateStore().saveNow(document)
        return makeStore()
    }

    private func legacyDocument(
        policy: ArchivePolicy,
        spaceCount: Int = 2
    ) -> (document: OrbitState, profileID: ProfileID, spaceIDs: [SpaceID]) {
        let profile = Profile(name: "Personal")
        var spaces: [Space] = []
        for index in 0..<spaceCount {
            var space = Space(name: "Space \(index)", profileID: profile.id, order: index)
            space.legacyArchivePolicy = policy.rawValue
            spaces.append(space)
        }
        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = spaces
        document.activeSpaceID = spaces.first?.id
        return (document, profile.id, spaces.map(\.id))
    }

    // MARK: - The migration itself

    func test_persistedPerSpacePolicy_isLiftedOntoTheProfileOnLoad() throws {
        let fixture = legacyDocument(policy: .after30Days)

        let store = try reload(fixture.document)

        XCTAssertEqual(
            store.state.profiles.first { $0.id == fixture.profileID }?.archivePolicy, .after30Days,
            """
            A user who chose "After 30 Days" while the setting was stored per Space \
            must still have it after upgrading. Without this migration they are \
            silently dropped to 12 hours and start losing tabs.
            """
        )
        for spaceID in fixture.spaceIDs {
            XCTAssertEqual(store.archivePolicy(forSpace: spaceID), .after30Days,
                           "every Space on the Profile must resolve to the lifted cadence")
        }
    }

    func test_theLiftedPolicyIsPersisted_andTheCarrierIsCleared() throws {
        let fixture = legacyDocument(policy: .after7Days)

        let migrated = try reload(fixture.document)
        try migrated.saveNow()

        let relaunched = makeStore()

        XCTAssertEqual(relaunched.state.profiles.first { $0.id == fixture.profileID }?.archivePolicy, .after7Days,
                       "the migration must be written to disk, not recomputed from a carrier that is now gone")
        for spaceID in fixture.spaceIDs {
            XCTAssertNil(
                relaunched.space(spaceID)?.legacyArchivePolicy,
                "the retired per-Space carrier must be cleared, so exactly one place in the document holds the answer"
            )
        }
    }

    func test_aPolicyChangedAfterMigration_survivesTheNextLaunch() throws {
        let fixture = legacyDocument(policy: .after30Days)

        let migrated = try reload(fixture.document)
        migrated.setArchivePolicy(.after24Hours, forProfile: fixture.profileID)
        try migrated.saveNow()

        let relaunched = makeStore()

        XCTAssertEqual(
            relaunched.state.profiles.first { $0.id == fixture.profileID }?.archivePolicy, .after24Hours,
            "the migration must run once; re-running it would overwrite the user's newer choice with the stale per-Space value"
        )
    }

    func test_eachProfileAdoptsItsOwnSpacesPolicy() throws {
        let personal = Profile(name: "Personal")
        let work = Profile(name: "Work")
        var personalSpace = Space(name: "Personal Space", profileID: personal.id, order: 0)
        personalSpace.legacyArchivePolicy = ArchivePolicy.never.rawValue
        var workSpace = Space(name: "Work Space", profileID: work.id, order: 1)
        workSpace.legacyArchivePolicy = ArchivePolicy.after24Hours.rawValue

        var document = OrbitState()
        document.profiles = [personal, work]
        document.spaces = [personalSpace, workSpace]
        document.activeSpaceID = personalSpace.id

        let store = try reload(document)

        XCTAssertEqual(store.state.profiles.first { $0.id == personal.id }?.archivePolicy, .never)
        XCTAssertEqual(store.state.profiles.first { $0.id == work.id }?.archivePolicy, .after24Hours)
    }

    func test_whenSpacesDisagree_theValueThePaneWasShowingWins() throws {
        let profile = Profile(name: "Personal")
        var second = Space(name: "Second", profileID: profile.id, order: 5)
        second.legacyArchivePolicy = ArchivePolicy.after24Hours.rawValue
        var first = Space(name: "First", profileID: profile.id, order: 1)
        first.legacyArchivePolicy = ArchivePolicy.never.rawValue

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [second, first]
        document.activeSpaceID = first.id

        let store = try reload(document)

        XCTAssertEqual(
            store.state.profiles.first { $0.id == profile.id }?.archivePolicy, .never,
            "the lowest-`order` Space's value is the one the Profiles pane displayed, so it is the one the Profile must adopt"
        )
    }

    func test_anUnrecognisedCarrierLeavesTheProfilesOwnValueAlone() throws {
        var profile = Profile(name: "Personal")
        profile.archivePolicy = .after7Days
        var space = Space(name: "Space", profileID: profile.id, order: 0)
        space.legacyArchivePolicy = "afterOneFortnight"

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.activeSpaceID = space.id

        let store = try reload(document)

        XCTAssertEqual(store.state.profiles.first { $0.id == profile.id }?.archivePolicy, .after7Days)
        XCTAssertNil(store.space(space.id)?.legacyArchivePolicy, "the unusable carrier is still cleared — it can never become readable")
    }

    func test_aDocumentWithNoCarriers_isLeftAlone() throws {
        var profile = Profile(name: "Personal")
        profile.archivePolicy = .after30Days
        let space = Space(name: "Space", profileID: profile.id, order: 0)

        var document = OrbitState()
        document.profiles = [profile]
        document.spaces = [space]
        document.activeSpaceID = space.id

        let store = try reload(document)

        XCTAssertEqual(store.state.profiles.first { $0.id == profile.id }?.archivePolicy, .after30Days,
                       "a document already in the new shape must not be touched by the migration")
        XCTAssertNil(store.space(space.id)?.legacyArchivePolicy)
    }

    // MARK: - What the migrated value is actually for

    func test_theLiftedPolicyIsWhatTheSweepActuallyUses() throws {
        let fixture = legacyDocument(policy: .never, spaceCount: 1)
        let store = try reload(fixture.document)
        let spaceID = try XCTUnwrap(fixture.spaceIDs.first)

        let tabID = store.openTab(url: URL(string: "https://stale.example.com")!, in: spaceID, activate: false)
        store.state.tabs[tabID]?.lastAccessedAt = Date().addingTimeInterval(-365 * 24 * 3600)

        store.runArchiveSweep(now: Date())

        XCTAssertEqual(
            store.tab(tabID)?.section, .today,
            "the sweep must honour the cadence the migration lifted onto the Profile — a user who chose Never must keep their tabs"
        )
    }
}
