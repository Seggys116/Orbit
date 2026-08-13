//  SyncRecordMapping once ignored Profile.isPersistent, so an Incognito Profile
//  could be pushed to iCloud. No real CloudKit; drives CloudSyncEngine against RecordingSyncTransport.

import CloudKit
import XCTest

@testable import Orbit

@MainActor
final class CloudSyncEngineTests: XCTestCase {

    private var scratch: URL!
    private var defaultsSuiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-CloudSync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        defaultsSuiteName = "OrbitAppTests-Sync-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: defaultsSuiteName)
        SyncPreferences.defaults = scratchDefaults
    }

    override func tearDown() {
        SyncPreferences.defaults = OrbitDefaults.standard
        scratchDefaults.removePersistentDomain(forName: defaultsSuiteName)
        scratchDefaults = nil
        defaultsSuiteName = nil
        scratch = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct Fixture {
        var state: OrbitState
        var realProfile: Profile
        var realSpace: Space
        var realTab: Tab
        var incognitoProfile: Profile
        var incognitoSpace: Space
        var incognitoTab: Tab
    }

    private func makeFixture(includeIncognito: Bool = true, includePersistentProfile: Bool = true) -> Fixture {
        let realProfile = Profile(name: "Personal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        var realSpace = Space(name: "Work", profileID: realProfile.id, createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let realTab = Tab(
            spaceID: realSpace.id, section: .pinned,
            url: URL(string: "https://swift.org")!, title: "Swift.org",
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_200),
            createdAt: Date(timeIntervalSince1970: 1_700_000_150)
        )
        realSpace.pinned = [.tab(realTab.id)]

        let incognitoProfile = Profile(
            name: "Incognito", isPersistent: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        var incognitoSpace = Space(
            name: "Incognito", icon: "eyeglasses", iconIsEmoji: false,
            profileID: incognitoProfile.id, createdAt: Date(timeIntervalSince1970: 1_700_000_310),
            isEphemeral: true
        )
        let incognitoTab = Tab(
            spaceID: incognitoSpace.id, section: .today,
            url: URL(string: "https://example.com/very-private-page")!, title: "Private",
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_400),
            createdAt: Date(timeIntervalSince1970: 1_700_000_350)
        )
        incognitoSpace.today = [incognitoTab.id]

        var state = OrbitState()
        state.profiles = includePersistentProfile ? [realProfile] : []
        state.spaces = includePersistentProfile ? [realSpace] : []
        state.tabs = includePersistentProfile ? [realTab.id: realTab] : [:]
        if includeIncognito {
            state.profiles.append(incognitoProfile)
            state.spaces.append(incognitoSpace)
            state.tabs[incognitoTab.id] = incognitoTab
        }

        return Fixture(
            state: state, realProfile: realProfile, realSpace: realSpace, realTab: realTab,
            incognitoProfile: incognitoProfile, incognitoSpace: incognitoSpace, incognitoTab: incognitoTab
        )
    }

    private func makeEngine(
        store: any SyncableStore,
        transport: RecordingSyncTransport
    ) -> CloudSyncEngine {
        CloudSyncEngine(
            store: store,
            transport: transport,
            rootDirectory: scratch,
            pushDebounce: .milliseconds(20)
        )
    }

    // MARK: - THE PRIVACY GUARANTEE

    func testIncognitoEntitiesAreNeverQueuedForPushWhileRealOnesAre() {
        let fixture = makeFixture()
        let store = StubSyncableStore(state: fixture.state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        engine.reconcile()

        let queued = transport.savedRecordNames
        XCTAssertFalse(queued.isEmpty, "Reconcile queued nothing at all — this test would pass vacuously.")

        XCTAssertTrue(
            queued.contains(fixture.realProfile.id.uuidString),
            "The ordinary Profile was not queued, so this test proves nothing about what is being excluded. Queued: \(queued.sorted())"
        )
        XCTAssertTrue(queued.contains(fixture.realSpace.id.uuidString), "The ordinary Space was not queued.")
        XCTAssertTrue(queued.contains(fixture.realTab.id.uuidString), "The ordinary pinned Tab was not queued.")

        XCTAssertFalse(
            queued.contains(fixture.incognitoProfile.id.uuidString),
            "PRIVACY LEAK: the Incognito Profile was queued for a push to iCloud."
        )
        XCTAssertFalse(
            queued.contains(fixture.incognitoSpace.id.uuidString),
            "PRIVACY LEAK: the Incognito Space was queued for a push to iCloud."
        )
        XCTAssertFalse(
            queued.contains(fixture.incognitoTab.id.uuidString),
            "PRIVACY LEAK: a tab browsed in an Incognito window was queued for a push to iCloud."
        )
        XCTAssertFalse(
            queued.contains(TodayEntryRecordName.make(spaceID: fixture.incognitoSpace.id, tabID: fixture.incognitoTab.id)),
            "PRIVACY LEAK: an Incognito Space's Today membership row was queued for a push to iCloud."
        )
    }

    func testIncognitoIsStillExcludedWhenThereIsNoPersistentProfileToFallBackOn() {
        let fixture = makeFixture(includeIncognito: true, includePersistentProfile: false)

        let persisted = fixture.state.strippingEphemeralEntities()
        XCTAssertTrue(
            persisted.profiles.contains(where: { $0.id == fixture.incognitoProfile.id }),
            "The premise of this test is gone: strippingEphemeralEntities() no longer keeps an Incognito Profile when there is no persistent Profile to reassign to."
        )

        let names = CloudSyncEngine.syncableRecordNames(in: fixture.state)
        XCTAssertFalse(
            names.contains(fixture.incognitoProfile.id.uuidString),
            "PRIVACY LEAK: with no persistent Profile in the document, the Incognito Profile became syncable."
        )
        XCTAssertFalse(names.contains(fixture.incognitoSpace.id.uuidString), "PRIVACY LEAK: Incognito Space became syncable.")
        XCTAssertFalse(names.contains(fixture.incognitoTab.id.uuidString), "PRIVACY LEAK: Incognito tab became syncable.")
        XCTAssertTrue(names.isEmpty, "Nothing in this document may sync, but \(names.sorted()) would.")
    }

    func testRoutingRulesNamingAnIncognitoEntityAreNotSyncable() {
        var fixture = makeFixture()
        let leaky = RoutingRule(pattern: "private.example", destination: .profile(fixture.incognitoProfile.id), isEnabled: true)
        let ordinary = RoutingRule(pattern: "figma.com", destination: .space(fixture.realSpace.id), isEnabled: true)
        fixture.state.routingRules = [leaky, ordinary]

        let names = CloudSyncEngine.syncableRecordNames(in: fixture.state)
        XCTAssertTrue(names.contains(ordinary.id.uuidString), "An ordinary routing rule stopped syncing.")
        XCTAssertFalse(
            names.contains(leaky.id.uuidString),
            "PRIVACY LEAK: a routing rule naming the Incognito Profile was queued for a push."
        )
    }

    func testANonPersistentProfileArrivingFromCloudKitIsRefused() {
        let store = StubSyncableStore(state: OrbitState())
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        let hostile = Profile(name: "Incognito", isPersistent: false, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let record = SyncRecordMapping.profileRecord(from: hostile, clientModifiedAt: Date(), existing: nil)

        engine.absorbIncoming(modifications: [record], deletions: [])

        XCTAssertFalse(
            store.state.profiles.contains(where: { $0.id == hostile.id }),
            "A non-persistent Profile pulled from iCloud was written into the local document."
        )
    }

    // MARK: - Pull applies real changes

    func testPullingASpaceRecordCreatesItInTheDocument() {
        let store = StubSyncableStore(state: OrbitState())
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        let space = Space(name: "Design", icon: "paintbrush", profileID: UUID(), order: 3)
        let record = SyncRecordMapping.spaceRecord(
            from: SpaceScalarFields(from: space), clientModifiedAt: Date(), existing: nil
        )
        XCTAssertNotNil(record)

        engine.absorbIncoming(modifications: [record!], deletions: [])

        let landed = store.state.spaces.first(where: { $0.id == space.id })
        XCTAssertEqual(landed?.name, "Design", "The pulled Space did not reach the document.")
        XCTAssertEqual(landed?.order, 3)
        XCTAssertFalse(landed?.isEphemeral ?? true, "A Space created from a pulled record must never be ephemeral.")
    }

    func testPullingADeletionRemovesTheEntityAndTombstonesIt() {
        let fixture = makeFixture(includeIncognito: false)
        let store = StubSyncableStore(state: fixture.state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        let id = CKRecord.ID(recordName: fixture.realSpace.id.uuidString, zoneID: CloudSyncEngine.zoneID)
        engine.absorbIncoming(modifications: [], deletions: [(id: id, type: SyncRecordType.space)])

        XCTAssertFalse(
            store.state.spaces.contains(where: { $0.id == fixture.realSpace.id }),
            "A deletion pulled from iCloud did not remove the Space locally."
        )
        XCTAssertTrue(
            engine._test_isTombstoned(fixture.realSpace.id.uuidString),
            "The deletion was applied but never tombstoned, so a stale copy could resurrect it."
        )
    }

    // MARK: - Fields the record schema does not carry are preserved, never clobbered

    func testPullingAProfileDoesNotResetItsSearchEngine() {
        var local = Profile(name: "Personal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        local.searchEngine = .duckDuckGo
        local.includesSearchSuggestions = false

        var state = OrbitState()
        state.profiles = [local]
        let store = StubSyncableStore(state: state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        var renamedRemotely = local
        renamedRemotely.name = "Work"
        let record = SyncRecordMapping.profileRecord(from: renamedRemotely, clientModifiedAt: Date(), existing: nil)

        engine.absorbIncoming(modifications: [record], deletions: [])

        let merged = store.state.profiles.first(where: { $0.id == local.id })
        XCTAssertEqual(merged?.name, "Work", "The synced field did not update, so this test proves nothing.")
        XCTAssertEqual(
            merged?.searchEngine, .duckDuckGo,
            "Pulling a Profile reset the user's chosen search engine — a field the record schema does not carry."
        )
        XCTAssertEqual(
            merged?.includesSearchSuggestions, false,
            "Pulling a Profile reset the search-suggestions preference."
        )
    }

    func testPullingATabDoesNotWipeItsPinnedOrigin() {
        let spaceID = UUID()
        var local = Tab(
            spaceID: spaceID, section: .pinned,
            url: URL(string: "https://www.nytimes.com/section/world")!, title: "World News",
            pinnedURL: URL(string: "https://www.nytimes.com/2024/02/22/an-article")!,
            pinnedTitle: "The Article I Pinned"
        )
        local.tidiedTitle = "NYT World"

        var state = OrbitState()
        state.tabs = [local.id: local]
        let store = StubSyncableStore(state: state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        var navigatedRemotely = local
        navigatedRemotely.url = URL(string: "https://www.nytimes.com/section/technology")!
        navigatedRemotely.title = "Technology"
        let record = SyncRecordMapping.tabRecord(from: navigatedRemotely, clientModifiedAt: Date(), existing: nil)

        engine.absorbIncoming(modifications: [record], deletions: [])

        let merged = store.state.tabs[local.id]
        XCTAssertEqual(merged?.title, "Technology", "The synced field did not update, so this test proves nothing.")
        XCTAssertEqual(
            merged?.pinnedURL, local.pinnedURL,
            "Pulling a Tab wiped its pinned origin — the URL clicking the favicon reverts to."
        )
        XCTAssertEqual(merged?.pinnedTitle, local.pinnedTitle, "Pulling a Tab wiped its pinned-origin title.")
        XCTAssertEqual(merged?.tidiedTitle, "NYT World", "Pulling a Tab wiped its shortened sidebar title.")
    }

    // MARK: - Conflict resolution, both directions

    func testAConflictThisDeviceWinsResubmitsItsFieldsOnTheServersRecord() {
        let store = StubSyncableStore(state: OrbitState())
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        let spaceID = UUID()
        let recordID = CKRecord.ID(recordName: spaceID.uuidString, zoneID: CloudSyncEngine.zoneID)

        let client = CKRecord(recordType: SyncRecordType.space, recordID: recordID)
        client["name"] = "Renamed Here" as CKRecordValue
        client["clientModifiedAt"] = Date(timeIntervalSince1970: 2_000) as CKRecordValue

        let server = CKRecord(recordType: SyncRecordType.space, recordID: recordID)
        server["name"] = "Renamed Elsewhere" as CKRecordValue
        server["clientModifiedAt"] = Date(timeIntervalSince1970: 1_000) as CKRecordValue

        engine.resolveConflict(clientRecord: client, serverRecord: server)

        XCTAssertEqual(
            server["name"] as? String, "Renamed Here",
            "The newer local edit was not copied onto the server's record, so the resubmitted save would carry the losing value."
        )
        XCTAssertTrue(
            transport.savedRecordNames.contains(spaceID.uuidString),
            "The winning edit was never re-queued for a save, so it would silently never reach iCloud."
        )
    }

    func testAConflictTheServerWinsAcceptsTheServersValueAndDropsTheLocalAttempt() {
        var space = Space(name: "Before", profileID: UUID())
        space.order = 0
        var state = OrbitState()
        state.spaces = [space]
        let store = StubSyncableStore(state: state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        let recordID = CKRecord.ID(recordName: space.id.uuidString, zoneID: CloudSyncEngine.zoneID)

        let client = CKRecord(recordType: SyncRecordType.space, recordID: recordID)
        client["name"] = "Loser" as CKRecordValue
        client["clientModifiedAt"] = Date(timeIntervalSince1970: 1_000) as CKRecordValue

        var winner = space
        winner.name = "Winner From Another Mac"
        let server = SyncRecordMapping.spaceRecord(
            from: SpaceScalarFields(from: winner),
            clientModifiedAt: Date(timeIntervalSince1970: 2_000),
            existing: nil
        )
        XCTAssertNotNil(server)

        engine.resolveConflict(clientRecord: client, serverRecord: server!)

        XCTAssertEqual(
            store.state.spaces.first(where: { $0.id == space.id })?.name,
            "Winner From Another Mac",
            "The newer server record was not applied to the local document."
        )
        XCTAssertTrue(
            transport.removedRecordNames.contains(space.id.uuidString),
            "The losing local save was left queued, so it would be retried and clobber the winner."
        )
    }

    // MARK: - Deletion, tombstoning and the push diff

    func testRemovingAnEntityLocallyQueuesARecordDeletionAndTombstonesIt() {
        let fixture = makeFixture(includeIncognito: false)
        let store = StubSyncableStore(state: fixture.state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        engine.reconcile()
        XCTAssertTrue(
            transport.savedRecordNames.contains(fixture.realSpace.id.uuidString),
            "The Space was never queued in the first place, so its deletion below proves nothing."
        )

        acceptQueuedSaves(engine: engine, transport: transport)
        transport.reset()

        var without = fixture.state
        without.spaces.removeAll { $0.id == fixture.realSpace.id }
        store.state = without

        engine.reconcile()

        XCTAssertTrue(
            transport.deletedRecordNames.contains(fixture.realSpace.id.uuidString),
            "Deleting a Space locally did not queue its record for deletion from iCloud. Queued deletions: \(transport.deletedRecordNames.sorted())"
        )
        XCTAssertTrue(
            engine._test_isTombstoned(fixture.realSpace.id.uuidString),
            "The deletion was queued but never tombstoned, so another device's stale copy could resurrect it."
        )
    }

    func testAnUnchangedDocumentQueuesNothingOnASecondReconcile() {
        let fixture = makeFixture(includeIncognito: false)
        let store = StubSyncableStore(state: fixture.state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        engine.reconcile()
        let first = transport.savedRecordNames
        XCTAssertFalse(first.isEmpty)

        let accepted = acceptQueuedSaves(engine: engine, transport: transport)
        XCTAssertEqual(
            Set(accepted.map(\.recordID.recordName)), first,
            "Some queued record could not be built, so it was never cached and the second reconcile below would re-queue it for a reason that has nothing to do with the diff."
        )
        transport.reset()

        engine.reconcile()

        let cached = engine._test_cachedContentHashes
        let desired = CloudSyncEngine._test_desiredContentHashes(for: store.state)
        let mismatched = desired.filter { cached[$0.key] != $0.value }
            .map { "\($0.key): the diff now computes \($0.value) but the successful push cached \(cached[$0.key] ?? "<nothing>")" }
            .sorted()
        XCTAssertEqual(mismatched, [], "A record's cached content hash disagrees with the one the next diff computes.")

        XCTAssertTrue(
            transport.savedRecordNames.isEmpty,
            "An unchanged document re-queued \(transport.savedRecordNames.count) records, so every launch would push the whole document again. Names: \(transport.savedRecordNames.sorted())"
        )
        XCTAssertTrue(transport.deletedRecordNames.isEmpty, "An unchanged document queued deletions.")
    }

    // Regression guard: JSONEncoder's non-deterministic key ordering for a synthesized
    // Codable type made the themeData hash input vary between calls, so the diff saw
    // the Space as changed on every reconcile. 50 iterations because it was probabilistic.
    func testTheHashInputForAThemedSpaceIsIdenticalOnEveryCall() {
        let fixture = makeFixture(includeIncognito: false)
        let baseline = CloudSyncEngine._test_desiredHashInputs(for: fixture.state)
        XCTAssertFalse(baseline.isEmpty, "No hash inputs at all — this test would pass vacuously.")
        XCTAssertTrue(
            baseline.values.contains { $0.contains("theme=") },
            "No Space hash input was produced, and the Space's theme blob is the serialisation this test is about."
        )

        for iteration in 0..<50 {
            let again = CloudSyncEngine._test_desiredHashInputs(for: fixture.state)
            let drifted = again.filter { baseline[$0.key] != $0.value }
            XCTAssertEqual(
                drifted.keys.sorted(), [],
                "The hash input changed on iteration \(iteration) for an unchanged document. Before: \(drifted.keys.compactMap { baseline[$0] }); after: \(drifted.values)"
            )
        }
    }

    func testAPulledRecordIsNotImmediatelyPushedStraightBack() {
        let profile = Profile(name: "Personal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let space = Space(name: "From Another Mac", profileID: profile.id, createdAt: Date(timeIntervalSince1970: 1_700_000_100))

        var state = OrbitState()
        state.profiles = [profile]
        let store = StubSyncableStore(state: state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        engine.reconcile()
        acceptQueuedSaves(engine: engine, transport: transport)
        transport.reset()

        let pulled = SyncRecordMapping.spaceRecord(
            from: SpaceScalarFields(from: space), clientModifiedAt: Date(), existing: nil
        )
        XCTAssertNotNil(pulled)
        engine.absorbIncoming(modifications: [pulled!], deletions: [])
        XCTAssertTrue(
            store.state.spaces.contains(where: { $0.id == space.id }),
            "The pulled Space never landed, so this test proves nothing."
        )
        transport.reset()

        engine.reconcile()

        XCTAssertFalse(
            transport.savedRecordNames.contains(space.id.uuidString),
            "A Space pulled from iCloud was immediately queued to be pushed back, which is an endless round trip between devices."
        )
    }

    // MARK: - Driven by real document changes

    func testARealBrowserStoreMutationSchedulesAPushWithNobodyAskingItTo() async throws {
        let stateStore = StateStore(rootDirectory: scratch.appendingPathComponent("State", isDirectory: true), maxBackups: 1)
        let browserStore = BrowserStore(stateStore: stateStore, autoArchiveInterval: nil)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: browserStore, transport: transport)

        engine.start()
        await engine.refreshAccountStatus()
        XCTAssertTrue(transport.isActivated, "The engine never activated its transport, so nothing below could be observed.")

        // start() reconciles asynchronously; drain it before resetting the recorder so a
        // launch-time reconcile can't be mistaken for the observation wiring under test.
        try await settle(milliseconds: 300)
        transport.reset()
        XCTAssertTrue(
            transport.savedRecordNames.isEmpty,
            "Launch-time pushes are still arriving, so anything recorded after the rename below cannot be attributed to it."
        )

        let spaceID = try XCTUnwrap(browserStore.state.spaces.first?.id)
        browserStore.renameSpace(spaceID, to: "Renamed By The User")

        await waitUntil(timeout: 3, "the renamed Space to be queued for a push") {
            transport.savedRecordNames.contains(spaceID.uuidString)
        }

        XCTAssertTrue(
            transport.savedRecordNames.contains(spaceID.uuidString),
            "Renaming a Space through BrowserStore never reached the sync engine. Queued: \(transport.savedRecordNames.sorted())"
        )
    }

    // MARK: - Honest behaviour when iCloud cannot be used

    func testAnUnentitledBuildReportsItAndNeverConstructsACloudKitContainer() {
        let probed = expectation(description: "availability probe consulted")
        let transport = CloudKitSyncTransport(
            containerIdentifier: CloudSyncEngine.containerIdentifier,
            subscriptionID: CloudSyncEngine.subscriptionID,
            availabilityProbe: { identifier in
                probed.fulfill()
                return .containerNotEntitled(containerIdentifier: identifier)
            }
        )
        let store = StubSyncableStore(state: OrbitState())
        let engine = CloudSyncEngine(store: store, transport: transport, rootDirectory: scratch)

        engine.start()

        wait(for: [probed], timeout: 1)
        XCTAssertEqual(
            engine.status, .unavailable(reason: .containerNotConfigured),
            "An unentitled build must say so rather than pretending sync is running."
        )
        XCTAssertFalse(
            transport.isActivated,
            "The transport activated without the entitlement, which is what would make CKContainer(identifier:) raise."
        )
        XCTAssertFalse(engine.status.isSynced, "An unentitled build must never report itself as synced.")
    }

    func testTurningSyncOffReportsOffAndDoesNotActivateTheTransport() {
        SyncPreferences.isEnabled = false
        let store = StubSyncableStore(state: makeFixture().state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        engine.start()

        XCTAssertEqual(engine.status, .off)
        XCTAssertFalse(transport.isActivated, "Sync is off, but the transport was activated anyway.")
        XCTAssertFalse(engine.status.isSynced)
    }

    func testTurningSyncBackOnActivatesTheTransportAndStopsSayingOff() async {
        SyncPreferences.isEnabled = false
        let store = StubSyncableStore(state: makeFixture().state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)
        engine.start()
        XCTAssertEqual(engine.status, .off)

        engine.setEnabled(true)

        XCTAssertTrue(transport.isActivated, "Re-enabling sync did not bring the transport up.")
        XCTAssertNotEqual(engine.status, .off, "Sync was re-enabled but the status still says it is off.")
        XCTAssertTrue(SyncPreferences.isEnabled, "The preference was not persisted, so the choice would not survive a relaunch.")
    }

    func testNoICloudAccountIsReportedHonestlyAndNothingClaimsToBeSynced() async {
        let store = StubSyncableStore(state: makeFixture().state)
        let transport = RecordingSyncTransport()
        transport.accountStatusResult = .success(.noAccount)
        let engine = makeEngine(store: store, transport: transport)

        engine.start()
        await engine.refreshAccountStatus()

        XCTAssertEqual(engine.status, .unavailable(reason: .noAccount))
        XCTAssertFalse(engine.status.isSynced, "Orbit claimed to be synced with no iCloud account signed in.")
        XCTAssertFalse(
            engine.status.userFacingMessage.isEmpty,
            "The status has no sentence to show the user, so the Settings pane would render a blank explanation."
        )
    }

    func testAFailingAccountCheckSurfacesAsAnErrorRatherThanSilence() async {
        struct Boom: Error {}
        let store = StubSyncableStore(state: OrbitState())
        let transport = RecordingSyncTransport()
        transport.accountStatusResult = .failure(Boom())
        let engine = makeEngine(store: store, transport: transport)

        engine.start()
        await engine.refreshAccountStatus()

        guard case .error = engine.status else {
            return XCTFail("A failed iCloud account check was swallowed; status is \(engine.status).")
        }
        XCTAssertFalse(engine.status.isSynced)
    }

    func testAFullICloudAccountIsReportedAsAnErrorNotAsSynced() {
        let store = StubSyncableStore(state: OrbitState())
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        engine.handleTopLevelError(CKError(.quotaExceeded))

        guard case .error(let message) = engine.status else {
            return XCTFail("A quota failure did not become an error status; status is \(engine.status).")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(engine.status.isSynced, "Orbit claimed to be synced while iCloud was rejecting its writes.")
    }

    func testLosingAuthenticationMidFlightStopsClaimingSynced() {
        let store = StubSyncableStore(state: OrbitState())
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        engine.notePushSucceeded(savedRecords: [], deletedRecordIDs: [])
        XCTAssertTrue(engine.status.isSynced, "The premise is gone: a completed push no longer reports as synced.")

        engine.handleTopLevelError(CKError(.notAuthenticated))

        XCTAssertEqual(engine.status, .unavailable(reason: .noAccount))
        XCTAssertFalse(engine.status.isSynced, "Orbit kept claiming to be synced after losing the iCloud account.")
    }

    func testSwitchingICloudAccountsClearsWhatThisDeviceThoughtItHadAlreadyPushed() {
        let fixture = makeFixture(includeIncognito: false)
        let store = StubSyncableStore(state: fixture.state)
        let transport = RecordingSyncTransport()
        let engine = makeEngine(store: store, transport: transport)

        engine.reconcile()
        acceptQueuedSaves(engine: engine, transport: transport)
        XCTAssertFalse(engine._test_cachedRecordNames.isEmpty, "Nothing was cached, so clearing it below proves nothing.")

        engine.resetForAccountSwitch()

        XCTAssertTrue(
            engine._test_cachedRecordNames.isEmpty,
            "Switching accounts left \(engine._test_cachedRecordNames.count) records cached, so the new account would never receive them."
        )

        transport.reset()
        engine.reconcile()
        XCTAssertTrue(
            transport.savedRecordNames.contains(fixture.realSpace.id.uuidString),
            "After an account switch the document was not re-pushed to the new account."
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func acceptQueuedSaves(engine: CloudSyncEngine, transport: RecordingSyncTransport) -> [CKRecord] {
        let accepted = transport.savedRecordNames.compactMap { name in
            engine.buildRecordForSave(recordID: CKRecord.ID(recordName: name, zoneID: CloudSyncEngine.zoneID))
        }
        engine.notePushSucceeded(savedRecords: accepted, deletedRecordIDs: [])
        return accepted
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out after \(timeout)s waiting for \(what).", file: file, line: line)
    }

    private func settle(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

// MARK: - Test doubles

@MainActor
final class StubSyncableStore: SyncableStore {
    var state: OrbitState

    init(state: OrbitState) {
        self.state = state
    }

    var syncSnapshot: OrbitState { state }

    func applySyncEngineUpdate(_ mutate: (inout OrbitState) -> Void) {
        var newState = state
        mutate(&newState)
        state = newState
    }
}

@MainActor
final class RecordingSyncTransport: SyncTransport {

    private(set) var isActivated = false
    private(set) var activateCount = 0
    private(set) var fetchCount = 0
    private(set) var sendCount = 0

    var accountStatusResult: Result<CKAccountStatus, Error> = .success(.available)

    var activateError: Error?

    private(set) var addedRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
    private(set) var removedRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
    private(set) var addedDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] = []

    func activate(delegate: any CKSyncEngineDelegate, stateSerialization: CKSyncEngine.State.Serialization?) throws {
        activateCount += 1
        if let activateError { throw activateError }
        isActivated = true
    }

    func accountStatus() async throws -> CKAccountStatus {
        try accountStatusResult.get()
    }

    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
        let removedNames = Set(removedRecordZoneChanges.map(Self.recordName(of:)))
        return addedRecordZoneChanges.filter { !removedNames.contains(Self.recordName(of: $0)) }
    }

    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { addedDatabaseChanges }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        addedRecordZoneChanges.append(contentsOf: changes)
    }

    func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        removedRecordZoneChanges.append(contentsOf: changes)
    }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        addedDatabaseChanges.append(contentsOf: changes)
    }

    func fetchChanges() async throws { fetchCount += 1 }
    func sendChanges() async throws { sendCount += 1 }

    // MARK: Assertions

    var savedRecordNames: Set<String> {
        Set(addedRecordZoneChanges.compactMap { change in
            if case .saveRecord(let id) = change { return id.recordName }
            return nil
        })
    }

    var deletedRecordNames: Set<String> {
        Set(addedRecordZoneChanges.compactMap { change in
            if case .deleteRecord(let id) = change { return id.recordName }
            return nil
        })
    }

    var removedRecordNames: Set<String> {
        Set(removedRecordZoneChanges.map(Self.recordName(of:)))
    }

    func reset() {
        addedRecordZoneChanges.removeAll()
        removedRecordZoneChanges.removeAll()
        addedDatabaseChanges.removeAll()
        fetchCount = 0
        sendCount = 0
    }

    private static func recordName(of change: CKSyncEngine.PendingRecordZoneChange) -> String {
        switch change {
        case .saveRecord(let id): return id.recordName
        case .deleteRecord(let id): return id.recordName
        @unknown default: return ""
        }
    }
}
