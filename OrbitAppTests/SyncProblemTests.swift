//  Drives SyncProblem and CloudSyncEngine's recovery actions against RecordingSyncTransport. No real CloudKit.

import CloudKit
import XCTest

@testable import Orbit

@MainActor
final class SyncProblemTests: XCTestCase {

    private static let productionSchemaText =
        "Error saving record <CKRecordID: 0x600003d4c3a0; recordName=0FFEE4C3-1111-2222-3333-444455556666, zoneID=OrbitState:__defaultOwner__> to server: Cannot create new type Tab in production schema"

    private var scratch: URL!
    private var defaultsSuiteName: String!
    private var scratchDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-SyncProblem-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defaultsSuiteName = "OrbitAppTests-SyncProblem-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: defaultsSuiteName)
        SyncPreferences.defaults = scratchDefaults
    }

    override func tearDown() {
        SyncPreferences.defaults = OrbitDefaults.standard
        scratchDefaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: scratch)
        scratchDefaults = nil
        defaultsSuiteName = nil
        scratch = nil
        super.tearDown()
    }

    // MARK: - Classifier

    func testTheReportedProductionSchemaFailureIsClassifiedAsAMissingSchema() {
        let error = CKError(.serverRejectedRequest, userInfo: [NSLocalizedDescriptionKey: Self.productionSchemaText])

        let problem = SyncProblem.classify(error, recordType: "Tab")

        XCTAssertEqual(problem.kind, .schemaNotDeployed(recordType: "Tab"))
        XCTAssertTrue(problem.message.contains("no deployed schema"), problem.message)
        XCTAssertTrue(problem.message.contains("Production"), problem.message)
        XCTAssertTrue(problem.message.contains("CloudKit console"), problem.message)
        XCTAssertTrue(problem.message.contains("Tab"), problem.message)
        XCTAssertTrue(problem.message.contains("will not help"), "The message must say overwriting data cannot fix this. \(problem.message)")
        XCTAssertFalse(problem.suggestsForceOverwrite)
        XCTAssertTrue(problem.isPermanent)
        XCTAssertTrue(problem.isSchemaProblem)
        XCTAssertFalse(problem.isTransient)
    }

    func testTheSchemaFailureIsRecognisedWhateverCodeCarriesIt() {
        let error = CKError(.invalidArguments, userInfo: [NSLocalizedDescriptionKey: "Cannot create new field x in production schema"])

        let problem = SyncProblem.classify(error, recordType: "Space")

        XCTAssertEqual(problem.kind, .schemaNotDeployed(recordType: "Space"))
    }

    func testTheSchemaFailureIsFoundInsideAPartialFailure() {
        let recordID = CKRecord.ID(recordName: "0FFEE4C3", zoneID: CloudSyncEngine.zoneID)
        let schema = CKError(.serverRejectedRequest, userInfo: [NSLocalizedDescriptionKey: Self.productionSchemaText])
        let subErrors: [AnyHashable: Error] = [recordID: schema]
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: subErrors])

        let problem = SyncProblem.classify(partial)

        XCTAssertEqual(problem.kind, .schemaNotDeployed(recordType: "Tab"))
    }

    func testAPartialFailureReportsTheMostSevereSubErrorAndIgnoresBatchFillers() {
        let one = CKRecord.ID(recordName: "one", zoneID: CloudSyncEngine.zoneID)
        let two = CKRecord.ID(recordName: "two", zoneID: CloudSyncEngine.zoneID)
        let three = CKRecord.ID(recordName: "three", zoneID: CloudSyncEngine.zoneID)
        let subErrors: [AnyHashable: Error] = [
            one: CKError(.batchRequestFailed),
            two: CKError(.serverRecordChanged),
            three: CKError(.quotaExceeded),
        ]
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: subErrors])

        XCTAssertEqual(SyncProblem.classify(partial).kind, .quotaExceeded)
    }

    func testQuotaExceeded() {
        let problem = SyncProblem.classify(CKError(.quotaExceeded))
        XCTAssertEqual(problem.kind, .quotaExceeded)
        XCTAssertTrue(problem.message.contains("storage is full"))
        XCTAssertFalse(problem.suggestsForceOverwrite)
        XCTAssertFalse(problem.isPermanent)
    }

    func testNetworkFailuresAreTransient() {
        for code in [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable] {
            let problem = SyncProblem.classify(CKError(code))
            XCTAssertEqual(problem.kind, .network, "\(code)")
            XCTAssertTrue(problem.isTransient, "\(code)")
            XCTAssertFalse(problem.suggestsForceOverwrite, "\(code)")
        }
    }

    func testNotAuthenticated() {
        let problem = SyncProblem.classify(CKError(.notAuthenticated))
        XCTAssertEqual(problem.kind, .notAuthenticated)
        XCTAssertTrue(problem.message.contains("iCloud"))
    }

    func testAMissingOrUserDeletedZoneSuggestsReplacingICloud() {
        for code in [CKError.Code.zoneNotFound, .userDeletedZone] {
            let problem = SyncProblem.classify(CKError(code))
            XCTAssertEqual(problem.kind, .zoneMissing, "\(code)")
            XCTAssertTrue(problem.suggestsForceOverwrite, "\(code)")
            XCTAssertTrue(problem.recoveryHint.contains("Replace iCloud with This Mac"), "\(code)")
        }
    }

    func testLimitExceededIsABatchProblem() {
        let problem = SyncProblem.classify(CKError(.limitExceeded))
        XCTAssertEqual(problem.kind, .batchTooLarge)
        XCTAssertFalse(problem.isPermanent)
    }

    func testPermissionFailureIsPermanent() {
        let problem = SyncProblem.classify(CKError(.permissionFailure))
        XCTAssertEqual(problem.kind, .permissionDenied)
        XCTAssertTrue(problem.isPermanent)
    }

    func testAServerRecordConflictSuggestsReplacingOneSide() {
        let problem = SyncProblem.classify(CKError(.serverRecordChanged))
        XCTAssertEqual(problem.kind, .conflict)
        XCTAssertTrue(problem.suggestsForceOverwrite)
        XCTAssertFalse(problem.isPermanent)
    }

    func testRateLimitingCarriesTheServersRetryDelay() {
        let problem = SyncProblem.classify(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0]))
        XCTAssertEqual(problem.kind, .rateLimited(retryAfter: 7))
        XCTAssertTrue(problem.isTransient)
    }

    func testTheGenericFallbackKeepsTheCodeNameAndTheDescription() {
        let error = CKError(.internalError, userInfo: [NSLocalizedDescriptionKey: "Failed to send changes"])

        let problem = SyncProblem.classify(error)

        XCTAssertEqual(problem.kind, .unknown(codeName: "internalError"))
        XCTAssertTrue(problem.message.contains("internalError"), problem.message)
        XCTAssertTrue(problem.message.contains("Failed to send changes"), problem.message)
        XCTAssertNotEqual(problem.message, "Failed to send changes", "The vague CloudKit text must not be all the user sees.")
        XCTAssertTrue(problem.isPermanent)
        XCTAssertTrue(problem.suggestsForceOverwrite)
    }

    func testTheGenericFallbackNamesTheRecordTypeAndTheUnderlyingError() {
        let underlying = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk exploded"])
        let error = CKError(.internalError, userInfo: [
            NSLocalizedDescriptionKey: "Failed to send changes",
            NSUnderlyingErrorKey: underlying,
        ])

        let problem = SyncProblem.classify(error, recordType: "Tab")

        XCTAssertTrue(problem.message.contains("Tab record"), problem.message)
        XCTAssertTrue(problem.message.contains("disk exploded"), problem.message)
    }

    func testANonCloudKitErrorKeepsItsOwnDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "boom happened" } }

        let problem = SyncProblem.classify(Boom())

        XCTAssertEqual(problem.message, "boom happened")
        XCTAssertEqual(problem.kind, .unknown(codeName: nil))
    }

    // MARK: - Engine surface

    func testAProblemReachesTheStatusAndLastProblemAndClearsWhenSyncRecovers() {
        let engine = CloudSyncEngine(
            store: StubSyncableStore(state: OrbitState()), transport: RecordingSyncTransport(), rootDirectory: scratch
        )
        let error = CKError(.serverRejectedRequest, userInfo: [NSLocalizedDescriptionKey: Self.productionSchemaText])

        engine.handleTopLevelError(error)

        guard case .error(let message) = engine.status else { return XCTFail("Status is \(engine.status).") }
        XCTAssertEqual(engine.lastProblem?.message, message)
        XCTAssertEqual(engine.lastProblem?.kind, .schemaNotDeployed(recordType: "Tab"))

        engine.notePushSucceeded(savedRecords: [], deletedRecordIDs: [])

        XCTAssertNil(engine.lastProblem, "A stale problem outlived the error status that explained it.")
    }

    func testAZoneProblemRequeuesTheZoneAndSurfacesTheRecoveryHint() {
        let transport = RecordingSyncTransport()
        let engine = CloudSyncEngine(store: StubSyncableStore(state: OrbitState()), transport: transport, rootDirectory: scratch)

        engine.handleTopLevelError(CKError(.userDeletedZone))

        XCTAssertEqual(engine.lastProblem?.kind, .zoneMissing)
        XCTAssertTrue(transport.addedDatabaseChanges.contains { change in
            if case .saveZone(let zone) = change { return zone.zoneID == CloudSyncEngine.zoneID }
            return false
        })
    }

    func testATransientErrorDoesNotRaiseAProblem() {
        let engine = CloudSyncEngine(
            store: StubSyncableStore(state: OrbitState()), transport: RecordingSyncTransport(), rootDirectory: scratch
        )

        engine.handleTopLevelError(CKError(.networkUnavailable))

        XCTAssertNil(engine.lastProblem)
        XCTAssertEqual(engine.status, .disabled)
    }

    // MARK: - Replace iCloud with This Mac

    func testReplacingICloudDeletesTheZoneThenReuploadsEveryLocalRecord() async throws {
        let fixture = makeState()
        let (engine, store, transport) = try await makeRunningEngine(state: fixture.state)
        defer { withExtendedLifetime(store) {} }
        try populateCache(engine: engine, transport: transport)
        XCTAssertFalse(engine._test_cachedRecordNames.isEmpty, "Nothing was cached, so clearing it proves nothing.")
        let stateFile = scratch.appendingPathComponent("sync-engine-state.json")
        try Data("stale".utf8).write(to: stateFile)
        transport.reset()

        await engine.replaceICloudWithThisMac()

        let deleteBatch = transport.sentDatabaseChangeBatches.firstIndex { $0.contains(where: Self.isZoneDeletion) }
        let saveBatch = transport.sentDatabaseChangeBatches.firstIndex { $0.contains(where: Self.isZoneSave) }
        XCTAssertNotNil(deleteBatch, "The Orbit zone was never deleted from iCloud.")
        XCTAssertNotNil(saveBatch, "The zone was not recreated after it was deleted.")
        if let deleteBatch, let saveBatch {
            XCTAssertLessThan(deleteBatch, saveBatch, "The zone was recreated before it was deleted.")
        }

        let expected: Set<String> = [fixture.profile.id.uuidString, fixture.space.id.uuidString, fixture.tab.id.uuidString]
        XCTAssertTrue(
            expected.isSubset(of: transport.savedRecordNames),
            "Not every local record was queued for upload. Missing: \(expected.subtracting(transport.savedRecordNames))"
        )
        XCTAssertTrue(expected.isSubset(of: engine._test_pendingPushNames))
        XCTAssertEqual(transport.deactivateCount, 1)
        XCTAssertEqual(transport.activationsHadSerialization, [false], "The engine restarted with the old saved state.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path), "The persisted engine state survived.")
        XCTAssertTrue(engine.status.isSynced, "Status is \(engine.status).")
        XCTAssertFalse(engine.isRecovering)
        XCTAssertNil(engine.lastProblem)
    }

    func testReplacingICloudShowsSyncingWhileItRuns() async throws {
        let (engine, store, transport) = try await makeRunningEngine(state: makeState().state)
        defer { withExtendedLifetime(store) {} }
        transport.reset()
        var observed: [SyncStatus] = []
        var observedRecovering: [Bool] = []
        transport.onSend = {
            observed.append(engine.status)
            observedRecovering.append(engine.isRecovering)
        }

        await engine.replaceICloudWithThisMac()

        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { $0 == .syncing }, "Status during recovery was \(observed).")
        XCTAssertTrue(observedRecovering.allSatisfy { $0 })
        XCTAssertTrue(engine.status.isSynced)
    }

    func testReplacingICloudLeavesLocalStateAloneWhenTheZoneCannotBeDeleted() async throws {
        let (engine, store, transport) = try await makeRunningEngine(state: makeState().state)
        defer { withExtendedLifetime(store) {} }
        try populateCache(engine: engine, transport: transport)
        let cached = engine._test_cachedRecordNames
        transport.reset()
        transport.sendError = CKError(.networkFailure)

        await engine.replaceICloudWithThisMac()

        guard case .error = engine.status else { return XCTFail("A failed recovery left status \(engine.status).") }
        XCTAssertNotNil(engine.lastProblem)
        XCTAssertEqual(engine._test_cachedRecordNames, cached, "Local sync records were discarded although iCloud was never cleared.")
        XCTAssertEqual(transport.deactivateCount, 0)
        XCTAssertFalse(engine.isRecovering)
    }

    func testReplacingICloudStopsWhenTheZoneDeletionStaysQueued() async throws {
        let (engine, store, transport) = try await makeRunningEngine(state: makeState().state)
        defer { withExtendedLifetime(store) {} }
        try populateCache(engine: engine, transport: transport)
        let cached = engine._test_cachedRecordNames
        transport.reset()
        transport.keepsDatabaseChangesPendingOnSend = true

        await engine.replaceICloudWithThisMac()

        XCTAssertEqual(engine.lastProblem, SyncProblem.incompleteRecovery())
        XCTAssertEqual(engine._test_cachedRecordNames, cached)
        XCTAssertEqual(transport.deactivateCount, 0)
        XCTAssertFalse(transport.pendingDatabaseChanges.contains(where: Self.isZoneDeletion), "The abandoned zone deletion was left queued.")
    }

    func testReplacingICloudSurfacesAClassifiedErrorWhenTheUploadIsRefused() async throws {
        let (engine, store, transport) = try await makeRunningEngine(state: makeState().state)
        defer { withExtendedLifetime(store) {} }
        transport.reset()
        let refusal = CKError(.serverRejectedRequest, userInfo: [NSLocalizedDescriptionKey: Self.productionSchemaText])
        transport.sendErrorQueue = [nil, refusal]

        await engine.replaceICloudWithThisMac()

        XCTAssertEqual(engine.lastProblem?.kind, .schemaNotDeployed(recordType: "Tab"))
        XCTAssertFalse(engine.isRecovering)
    }

    func testReplacingICloudDoesNothingWhileAnotherRecoveryIsRunning() async throws {
        let (engine, store, transport) = try await makeRunningEngine(state: makeState().state)
        defer { withExtendedLifetime(store) {} }
        transport.reset()

        async let first: Void = engine.replaceICloudWithThisMac()
        async let second: Void = engine.replaceICloudWithThisMac()
        _ = await (first, second)

        XCTAssertEqual(transport.deactivateCount, 1, "Two recoveries ran at once.")
    }

    // MARK: - Replace This Mac with iCloud

    func testReplacingThisMacRefetchesFromScratchWithoutTouchingICloud() async throws {
        let fixture = makeState()
        let (engine, store, transport) = try await makeRunningEngine(state: fixture.state)
        defer { withExtendedLifetime(store) {} }
        try populateCache(engine: engine, transport: transport)
        XCTAssertFalse(engine._test_cachedRecordNames.isEmpty)
        let stateFile = scratch.appendingPathComponent("sync-engine-state.json")
        try Data("stale".utf8).write(to: stateFile)
        transport.reset()

        await engine.replaceThisMacWithICloud()

        XCTAssertGreaterThanOrEqual(transport.fetchCount, 1, "iCloud was never re-fetched.")
        XCTAssertEqual(transport.deactivateCount, 1)
        XCTAssertEqual(transport.activationsHadSerialization, [false], "The engine restarted with the old change token.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
        XCTAssertFalse(
            transport.sentDatabaseChangeBatches.joined().contains(where: Self.isZoneDeletion),
            "Replacing this Mac must never delete anything in iCloud."
        )
        XCTAssertTrue(engine.status.isSynced, "Status is \(engine.status).")
        XCTAssertFalse(engine.isRecovering)
        XCTAssertNil(engine.lastProblem)
    }

    func testReplacingThisMacTakesICloudsVersionKeepsLocalOnlyItemsAndAddsRemoteOnes() async throws {
        let fixture = makeState()
        let (engine, store, transport) = try await makeRunningEngine(state: fixture.state)
        try populateCache(engine: engine, transport: transport)
        transport.reset()

        var remoteSpace = fixture.space
        remoteSpace.name = "Renamed In iCloud"
        let remoteOnly = Space(name: "Only In iCloud", profileID: fixture.profile.id, order: 9)
        let records = [remoteSpace, remoteOnly].compactMap {
            SyncRecordMapping.spaceRecord(from: SpaceScalarFields(from: $0), clientModifiedAt: Date(), existing: nil)
        }
        XCTAssertEqual(records.count, 2)
        transport.onFetch = { engine.absorbIncoming(modifications: records, deletions: []) }

        await engine.replaceThisMacWithICloud()

        XCTAssertEqual(store.state.spaces.first(where: { $0.id == fixture.space.id })?.name, "Renamed In iCloud")
        XCTAssertNotNil(store.state.spaces.first(where: { $0.id == remoteOnly.id }), "A Space that exists only in iCloud was not downloaded.")
        XCTAssertNotNil(store.state.tabs[fixture.tab.id], "A tab that was never in iCloud was deleted locally.")
        XCTAssertTrue(
            transport.savedRecordNames.contains(fixture.tab.id.uuidString),
            "The local-only tab was kept but never queued for upload."
        )
    }

    func testReplacingThisMacSurfacesAFetchFailure() async throws {
        let (engine, store, transport) = try await makeRunningEngine(state: makeState().state)
        defer { withExtendedLifetime(store) {} }
        transport.reset()
        transport.fetchError = CKError(.networkFailure)

        await engine.replaceThisMacWithICloud()

        guard case .error = engine.status else { return XCTFail("Status is \(engine.status).") }
        XCTAssertEqual(engine.lastProblem?.kind, .network)
        XCTAssertFalse(engine.isRecovering)
    }

    func testRecoveryIsRefusedBeforeSyncHasStarted() async {
        let transport = RecordingSyncTransport()
        let engine = CloudSyncEngine(store: StubSyncableStore(state: OrbitState()), transport: transport, rootDirectory: scratch)

        await engine.replaceICloudWithThisMac()
        await engine.replaceThisMacWithICloud()

        XCTAssertEqual(transport.sendCount, 0)
        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertEqual(transport.deactivateCount, 0)
        XCTAssertFalse(engine.isRecovering)
    }

    // MARK: - Confirmation copy

    func testEveryRecoveryActionStatesWhatItDiscards() {
        let replaceICloud = SyncRecoveryAction.replaceICloudWithThisMac.confirmationMessage
        XCTAssertTrue(replaceICloud.contains("deletes everything Orbit has stored in iCloud"))
        XCTAssertTrue(replaceICloud.contains("cannot be undone"))

        let replaceMac = SyncRecoveryAction.replaceThisMacWithICloud.confirmationMessage
        XCTAssertTrue(replaceMac.contains("iCloud's version replaces this Mac's"))
        XCTAssertTrue(replaceMac.contains("only on this Mac are kept and uploaded"))
        XCTAssertTrue(replaceMac.contains("cannot be undone"))
    }

    // MARK: - Helpers

    private struct State {
        var state: OrbitState
        var profile: Profile
        var space: Space
        var tab: Tab
    }

    private func makeState() -> State {
        let profile = Profile(name: "Personal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        var space = Space(name: "Work", profileID: profile.id, createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let tab = Tab(
            spaceID: space.id, section: .pinned,
            url: URL(string: "https://swift.org")!, title: "Swift.org",
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_200),
            createdAt: Date(timeIntervalSince1970: 1_700_000_150)
        )
        space.pinned = [.tab(tab.id)]
        var state = OrbitState()
        state.profiles = [profile]
        state.spaces = [space]
        state.tabs = [tab.id: tab]
        return State(state: state, profile: profile, space: space, tab: tab)
    }

    private func makeRunningEngine(
        state: OrbitState
    ) async throws -> (CloudSyncEngine, StubSyncableStore, RecordingSyncTransport) {
        let store = StubSyncableStore(state: state)
        let transport = RecordingSyncTransport()
        let engine = CloudSyncEngine(store: store, transport: transport, rootDirectory: scratch, pushDebounce: .milliseconds(20))
        engine.start()
        await engine.refreshAccountStatus()
        try await Task.sleep(for: .milliseconds(300))
        return (engine, store, transport)
    }

    private func populateCache(engine: CloudSyncEngine, transport: RecordingSyncTransport) throws {
        engine.reconcile()
        let accepted = transport.savedRecordNames.compactMap { name in
            engine.buildRecordForSave(recordID: CKRecord.ID(recordName: name, zoneID: CloudSyncEngine.zoneID))
        }
        XCTAssertFalse(accepted.isEmpty, "Reconcile queued nothing to cache.")
        engine.notePushSucceeded(savedRecords: accepted, deletedRecordIDs: [])
    }

    private static func isZoneDeletion(_ change: CKSyncEngine.PendingDatabaseChange) -> Bool {
        if case .deleteZone(let id) = change { return id == CloudSyncEngine.zoneID }
        return false
    }

    private static func isZoneSave(_ change: CKSyncEngine.PendingDatabaseChange) -> Bool {
        if case .saveZone(let zone) = change { return zone.zoneID == CloudSyncEngine.zoneID }
        return false
    }
}
