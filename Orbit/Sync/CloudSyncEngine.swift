import CloudKit
import Foundation
import Observation

// MARK: - Integration seam

@MainActor
public protocol SyncableStore: AnyObject {
    var syncSnapshot: OrbitState { get }

    func applySyncEngineUpdate(_ mutate: (inout OrbitState) -> Void)
}

extension BrowserStore: SyncableStore {
    public var syncSnapshot: OrbitState { state }

    public func applySyncEngineUpdate(_ mutate: (inout OrbitState) -> Void) {
        var newState = state
        mutate(&newState)
        state = newState
    }
}

// MARK: - CloudSyncEngine

@MainActor
@Observable
public final class CloudSyncEngine {

    public static let containerIdentifier = "iCloud.com.zak-noble-clarke.Orbit"

    public static let zoneID = CKRecordZone.ID(zoneName: SyncRecordType.zoneName, ownerName: CKCurrentUserDefaultName)

    static let subscriptionID: CKSubscription.ID = "orbit-state-changes"

    public private(set) var status: SyncStatus = .disabled

    public private(set) var isRecovering = false

    private var storedProblem: SyncProblem?
    private var unreadableRemoteRecordCount = 0
    private var needsReconcileAfterRecovery = false

    public var lastProblem: SyncProblem? {
        guard case .error(let message) = status, let problem = storedProblem, problem.message == message else { return nil }
        return problem
    }

    public private(set) var isStarted = false

    public private(set) var isEnabled: Bool = SyncPreferences.isEnabled

    private weak var store: (any SyncableStore)?
    private let transport: any SyncTransport
    private let rootDirectory: URL
    private let cacheWriter = SyncCacheWriter()

    private var recordCache: [String: CachedRecord] = [:]
    private var tombstones = SyncTombstoneLog()

    private var pendingPush: [String: PendingPush] = [:]
    private var pendingLocalModifiedAt: [String: Date] = [:]
    private var pendingNoteAssetFiles: [URL] = []

    private let pushDebounce: Duration
    private let cacheWriteDelay: Duration
    private var cachePersistTask: Task<Void, Never>?

    nonisolated(unsafe) private var accountChangeObservationTask: Task<Void, Never>?
    nonisolated(unsafe) private var retryTask: Task<Void, Never>?
    nonisolated(unsafe) private var debounceTask: Task<Void, Never>?

    // MARK: Init

    public init(
        store: (any SyncableStore)? = nil,
        transport: (any SyncTransport)? = nil,
        rootDirectory: URL? = nil,
        pushDebounce: Duration = .milliseconds(750),
        cacheWriteDelay: Duration = .seconds(2)
    ) {
        self.cacheWriteDelay = cacheWriteDelay
        self.transport = transport ?? CloudKitSyncTransport(
            containerIdentifier: Self.containerIdentifier,
            subscriptionID: Self.subscriptionID
        )
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.pushDebounce = pushDebounce
        self.store = store
        self.isEnabled = SyncPreferences.isEnabled
        loadCaches()
    }

    deinit {
        accountChangeObservationTask?.cancel()
        retryTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: Public API

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        guard isEnabled else {
            status = .off
            return
        }

        do {
            try transport.activate(delegate: self, stateSerialization: loadStateSerialization())
        } catch SyncTransportError.containerNotEntitled {
            status = .unavailable(reason: .containerNotConfigured)
            return
        } catch {
            status = .error(message: "Orbit couldn't start iCloud sync: \(error.localizedDescription)")
            return
        }

        transport.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])

        accountChangeObservationTask = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(named: .CKAccountChanged)
            for await _ in changes {
                await self?.refreshAccountStatus()
            }
        }

        if let store { observeStoreChanges(store) }

        Task { [weak self] in
            await self?.refreshAccountStatus()
        }
    }

    public func attach(store: any SyncableStore) {
        self.store = store
        guard isStarted else { return }
        observeStoreChanges(store)
        reconcileAndPush()
    }

    public func setEnabled(_ enabled: Bool) {
        SyncPreferences.isEnabled = enabled
        isEnabled = enabled
        guard enabled else {
            debounceTask?.cancel()
            retryTask?.cancel()
            status = .off
            return
        }
        guard isStarted else {
            status = .disabled
            start()
            return
        }
        if transport.isActivated {
            status = .idle(lastSyncedAt: nil)
            Task { [weak self] in await self?.refreshNow() }
        } else {
            isStarted = false
            status = .disabled
            start()
        }
    }

    public func refreshNow() async {
        guard transport.isActivated, isEnabled, !isRecovering else { return }
        await refreshAccountStatus()
        guard isEligibleToSync else { return }
        reconcile()
        do {
            try await fetchChangesOutsideDelegateCallback()
            try await sendChangesOutsideDelegateCallback()
        } catch {
            handleTopLevelError(error)
        }
    }

    // MARK: Calling into CKSyncEngine

    // CKSyncEngine traps ("BUG IN CLIENT OF CLOUDKIT: Cannot await a call into CKSyncEngine from within a
    // delegate callback") when fetchChanges or sendChanges is awaited by a task it has marked as running
    // inside one of its callbacks. The mark is a task-local, and an unstructured Task copies its creator's
    // task-locals. So a push started from handleEvent carried it: .accountChange (delivered at startup) ->
    // refreshAccountStatus -> reconcileAndPush, a failed save -> scheduleRetry, or a store edit made while
    // absorbing a fetch -> debounceReconcile. Every call into the engine goes through here, in a detached
    // task that starts with no inherited task-locals.

    private func fetchChangesOutsideDelegateCallback() async throws {
        let transport = self.transport
        try await Self.runOutsideDelegateCallback { try await transport.fetchChanges() }
    }

    private func sendChangesOutsideDelegateCallback() async throws {
        let transport = self.transport
        try await Self.runOutsideDelegateCallback { try await transport.sendChanges() }
    }

    private static func runOutsideDelegateCallback(
        _ operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        let detached = Task.detached { @MainActor in try await operation() }
        try await withTaskCancellationHandler {
            try await detached.value
        } onCancel: {
            detached.cancel()
        }
    }

    private var isEligibleToSync: Bool {
        guard transport.isActivated else { return false }
        switch status {
        case .idle, .syncing: return true
        case .disabled, .off, .unavailable, .error: return false
        }
    }

    // MARK: Account status

    func refreshAccountStatus() async {
        guard transport.isActivated else { return }
        do {
            let accountStatus = try await transport.accountStatus()
            applyAccountStatus(accountStatus)
        } catch {
            status = .error(message: "Couldn't determine iCloud account status: \(error.localizedDescription)")
        }
    }

    private func applyAccountStatus(_ accountStatus: CKAccountStatus) {
        if let reason = SyncStatus.UnavailableReason(accountStatus: accountStatus) {
            status = .unavailable(reason: reason)
            return
        }
        switch status {
        case .unavailable, .disabled, .error: status = .idle(lastSyncedAt: nil)
        case .off, .idle, .syncing: break
        }
        reconcileAndPush()
    }

    // MARK: Observing local edits

    private func observeStoreChanges(_ store: any SyncableStore) {
        withObservationTracking {
            _ = store.syncSnapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.debounceReconcile()
                if let store = self.store {
                    self.observeStoreChanges(store)
                }
            }
        }
    }

    private func debounceReconcile() {
        debounceTask?.cancel()
        let debounce = pushDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            if self.isRecovering {
                self.needsReconcileAfterRecovery = true
                return
            }
            self.reconcileAndPush()
        }
    }

    // MARK: Reconcile (local -> desired CKRecord set -> diff -> push)

    private func reconcileAndPush() {
        guard isEligibleToSync, !isRecovering else { return }
        reconcile()
        guard !transport.pendingRecordZoneChanges.isEmpty || !transport.pendingDatabaseChanges.isEmpty else { return }
        status = .syncing
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendChangesOutsideDelegateCallback()
            } catch {
                self.handleTopLevelError(error)
            }
        }
    }

    func reconcile() {
        guard let store else { return }
        let desired = Self.desiredPushes(from: store.syncSnapshot)
        diffAndQueue(desired: desired)
    }

    private func diffAndQueue(desired: [String: PendingPush]) {
        var toSave: [CKSyncEngine.PendingRecordZoneChange] = []
        var toDelete: [CKSyncEngine.PendingRecordZoneChange] = []

        var forgotATombstone = false
        for (name, push) in desired {
            // A record that exists again is not deleted; leaving the tombstone would keep censoring its id out of every ordered merge for 90 days.
            if tombstones.contains(name) {
                tombstones.forget(name)
                forgotATombstone = true
            }
            let hash = Self.contentHash(for: push.payload)
            if let cached = recordCache[name], cached.contentHash == hash {
                continue
            }
            let clientModifiedAt = Date()
            var stamped = push
            stamped.clientModifiedAt = clientModifiedAt
            stamped.contentHash = hash
            pendingPush[name] = stamped
            pendingLocalModifiedAt[name] = clientModifiedAt
            toSave.append(.saveRecord(Self.recordID(push.recordType, name: name)))
        }

        for (name, cached) in recordCache where desired[name] == nil {
            toDelete.append(.deleteRecord(Self.recordID(cached.recordType, name: name)))
            tombstones.record(name)
        }
        for change in toDelete {
            if case .deleteRecord(let id) = change {
                recordCache.removeValue(forKey: id.recordName)
                pendingPush.removeValue(forKey: id.recordName)
                pendingLocalModifiedAt.removeValue(forKey: id.recordName)
            }
        }

        if !toSave.isEmpty { transport.add(pendingRecordZoneChanges: toSave) }
        if !toDelete.isEmpty { transport.add(pendingRecordZoneChanges: toDelete) }
        if !toSave.isEmpty || !toDelete.isEmpty || forgotATombstone { persistCaches() }
    }

    // MARK: Building CKRecords to save

    func buildRecordForSave(recordID: CKRecord.ID) -> CKRecord? {
        let name = recordID.recordName
        guard let push = pendingPush[name] else { return nil }
        let existing = recordCache[name].flatMap { decodeSystemFields($0.systemFieldsData) }

        switch push.payload {
        case .profile(let model):
            return SyncRecordMapping.profileRecord(from: model, clientModifiedAt: push.clientModifiedAt, existing: existing)
        case .space(let model):
            return SyncRecordMapping.spaceRecord(from: model, clientModifiedAt: push.clientModifiedAt, existing: existing)
        case .favorite(let model):
            return SyncRecordMapping.favoriteRecord(from: model, clientModifiedAt: push.clientModifiedAt, existing: existing)
        case .sidebarNode(let model):
            return SyncRecordMapping.sidebarNodeRecord(from: model, clientModifiedAt: push.clientModifiedAt, existing: existing)
        case .todayEntry(let model):
            return SyncRecordMapping.todayEntryRecord(from: model, clientModifiedAt: push.clientModifiedAt, existing: existing)
        case .tab(let model):
            return SyncRecordMapping.tabRecord(from: model, clientModifiedAt: push.clientModifiedAt, existing: existing)
        case .boost(let model):
            return SyncRecordMapping.boostRecord(from: model, existing: existing)
        case .easel(let model):
            return SyncRecordMapping.easelRecord(from: model, existing: existing)
        case .note(let model):
            guard let fileURL = try? SyncRecordMapping.writeNoteAssetFile(model.bodyData, noteID: model.id) else { return nil }
            pendingNoteAssetFiles.append(fileURL)
            return SyncRecordMapping.noteRecord(from: model, assetFileURL: fileURL, existing: existing)
        case .routingRule(let model):
            return SyncRecordMapping.routingRuleRecord(from: model, clientModifiedAt: push.clientModifiedAt, existing: existing)
        }
    }

    // MARK: Persistence (record cache, tombstones, CKSyncEngine state)

    private static func defaultRootDirectory() -> URL {
        let directory = OrbitDataRoot.processDefault.sync
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var recordCacheURL: URL { rootDirectory.appendingPathComponent("record-cache.json") }
    private var tombstoneLogURL: URL { rootDirectory.appendingPathComponent("tombstones.json") }
    private var stateSerializationURL: URL { rootDirectory.appendingPathComponent("sync-engine-state.json") }

    private func loadCaches() {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        cacheWriter.flush()
        if let data = try? Data(contentsOf: recordCacheURL),
           let decoded = try? JSONDecoder.orbitSync.decode([String: CachedRecord].self, from: data) {
            recordCache = decoded
        }
        if let data = try? Data(contentsOf: tombstoneLogURL),
           let decoded = try? JSONDecoder.orbitSync.decode(SyncTombstoneLog.self, from: data) {
            tombstones = decoded
        }
    }

    // both files hold every record: a burst is written once after the delay, and flush writes at once
    private func persistCaches() {
        tombstones.prune()
        guard cachePersistTask == nil else { return }
        let delay = cacheWriteDelay
        cachePersistTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.cachePersistTask = nil
            self.writeCaches()
        }
    }

    private func writeCaches() {
        let records = recordCache
        let log = tombstones
        cacheWriter.write(to: recordCacheURL) { SyncCacheWriter.encode(records) }
        cacheWriter.write(to: tombstoneLogURL) { SyncCacheWriter.encode(log) }
    }

    /// Blocks until every queued cache write and delete has reached disk.
    public func flushPendingCacheWrites() {
        if let task = cachePersistTask {
            task.cancel()
            cachePersistTask = nil
            writeCaches()
        }
        cacheWriter.flush()
    }

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        cacheWriter.flush()
        guard let data = try? Data(contentsOf: stateSerializationURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persistStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        cacheWriter.write(to: stateSerializationURL) { data }
    }

    // MARK: CKRecord <-> system-fields archive helpers

    private func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    private func extractClock(_ record: CKRecord) -> Date {
        if let updatedAt = record[secure: "updatedAt"] as? Date { return updatedAt }
        if let clientModifiedAt = record[secure: "clientModifiedAt"] as? Date { return clientModifiedAt }
        return record.modificationDate ?? .distantPast
    }

    private func groupingKey(for record: CKRecord) -> String? {
        record[secure: "spaceID"] as? String
    }

    static func recordID(_ recordType: String, name: String) -> CKRecord.ID {
        _ = recordType
        return CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    // MARK: Record identity

    private nonisolated struct CachedRecord: Codable, Sendable {
        var recordType: String
        var systemFieldsData: Data
        var contentHash: String
        var clientModifiedAt: Date
        var groupingKey: String?
    }

    enum PendingPayload {
        case profile(Profile)
        case space(SpaceScalarFields)
        case favorite(FlatFavorite)
        case sidebarNode(FlatSidebarNode)
        case todayEntry(FlatTodayEntry)
        case tab(Tab)
        case boost(Boost)
        case easel(Easel)
        case note(Note)
        case routingRule(RoutingRule)
    }

    struct PendingPush {
        var recordType: String
        var clientModifiedAt: Date
        var payload: PendingPayload
        var contentHash: String = ""
    }

    // MARK: Desired-state computation (pure)

    static func desiredPushes(from rawState: OrbitState) -> [String: PendingPush] {
        let state = SyncScope.syncable(rawState)
        var desired: [String: PendingPush] = [:]

        for profile in state.profiles {
            desired[profile.id.uuidString] = PendingPush(recordType: SyncRecordType.profile, clientModifiedAt: .distantPast, payload: .profile(profile))
        }

        for space in state.spaces {
            desired[space.id.uuidString] = PendingPush(
                recordType: SyncRecordType.space, clientModifiedAt: .distantPast,
                payload: .space(SpaceScalarFields(from: space))
            )
            for (index, favorite) in space.favorites.enumerated() {
                desired[favorite.id.uuidString] = PendingPush(
                    recordType: SyncRecordType.favorite, clientModifiedAt: .distantPast,
                    payload: .favorite(FlatFavorite(favorite: favorite, spaceID: space.id, order: index))
                )
            }
            for node in SidebarTreeFlattening.flatten(space.pinned, spaceID: space.id) {
                desired[node.id.uuidString] = PendingPush(
                    recordType: SyncRecordType.sidebarNode, clientModifiedAt: .distantPast,
                    payload: .sidebarNode(node)
                )
            }
            for (index, tabID) in space.today.enumerated() {
                let entry = FlatTodayEntry(spaceID: space.id, tabID: tabID, order: index)
                desired[TodayEntryRecordName.make(spaceID: space.id, tabID: tabID)] = PendingPush(
                    recordType: SyncRecordType.todayEntry, clientModifiedAt: .distantPast,
                    payload: .todayEntry(entry)
                )
            }
        }

        // Every tab of a live Space, not only the ones Today/Pinned reference: an archived tab that dropped out of here read as a deletion, which tombstoned its id and then censored it out of Today for good.
        let liveSpaceIDs = Set(state.spaces.map(\.id))
        for tab in state.tabs.values where liveSpaceIDs.contains(tab.spaceID) {
            desired[tab.id.uuidString] = PendingPush(recordType: SyncRecordType.tab, clientModifiedAt: .distantPast, payload: .tab(tab))
        }

        for boost in state.boosts {
            desired[boost.id.uuidString] = PendingPush(recordType: SyncRecordType.boost, clientModifiedAt: boost.updatedAt, payload: .boost(boost))
        }
        for easel in state.easels {
            desired[easel.id.uuidString] = PendingPush(recordType: SyncRecordType.easel, clientModifiedAt: easel.updatedAt, payload: .easel(easel))
        }
        for note in state.notes {
            desired[note.id.uuidString] = PendingPush(recordType: SyncRecordType.note, clientModifiedAt: note.updatedAt, payload: .note(note))
        }
        for rule in state.routingRules {
            desired[rule.id.uuidString] = PendingPush(recordType: SyncRecordType.routingRule, clientModifiedAt: .distantPast, payload: .routingRule(rule))
        }

        return desired
    }

    public static func syncableRecordNames(in state: OrbitState) -> Set<String> {
        Set(desiredPushes(from: state).keys)
    }

    private static func contentHash(for payload: PendingPayload) -> String {
        StableHash.hex(hashInput(for: payload))
    }

    static func hashInput(for payload: PendingPayload) -> String {
        let input: String
        switch payload {
        case .profile(let p):
            input = "name=\(p.name)|symbol=\(p.symbolName)|tint=\(p.tint.red),\(p.tint.green),\(p.tint.blue),\(p.tint.alpha)|persistent=\(p.isPersistent)|created=\(p.createdAt.timeIntervalSinceReferenceDate)|policy=\(p.archivePolicy.rawValue)"
        case .space(let s):
            let theme = (try? JSONEncoder.orbitSync.encode(s.theme))?.base64EncodedString() ?? ""
            input = "name=\(s.name)|icon=\(s.icon)|emoji=\(s.iconIsEmoji)|iconKind=\(s.iconKind?.rawValue ?? "")|iconImage=\(s.iconImageID?.uuidString ?? "")|theme=\(theme)|profile=\(s.profileID)|order=\(s.order)|created=\(s.createdAt.timeIntervalSinceReferenceDate)"
        case .favorite(let f):
            input = "space=\(f.spaceID)|order=\(f.order)|url=\(f.favorite.url.absoluteString)|title=\(f.favorite.title)|icon=\(f.favorite.customIcon ?? "")|emoji=\(f.favorite.customIconIsEmoji)|live=\(f.favorite.liveTabID?.uuidString ?? "")"
        case .sidebarNode(let n):
            input = "space=\(n.spaceID)|parent=\(n.parentID?.uuidString ?? "")|order=\(n.order)|kind=\(n.kind.rawValue)|name=\(n.name ?? "")|expanded=\(n.isExpanded.map(String.init) ?? "")|icon=\(n.icon ?? "")|emoji=\(n.iconIsEmoji.map(String.init) ?? "")"
        case .todayEntry(let e):
            input = "space=\(e.spaceID)|tab=\(e.tabID)|order=\(e.order)"
        case .tab(let t):
            input = "space=\(t.spaceID)|section=\(t.section.rawValue)|url=\(t.url.absoluteString)|title=\(t.title)|custom=\(t.customTitle ?? "")|favicon=\(t.faviconURL?.absoluteString ?? "")|lastAccessed=\(t.lastAccessedAt.timeIntervalSinceReferenceDate)|created=\(t.createdAt.timeIntervalSinceReferenceDate)|archived=\(t.archivedAt?.timeIntervalSinceReferenceDate ?? 0)|unloaded=\(t.isUnloaded)|muted=\(t.isMuted)|zoom=\(t.zoomFactor ?? -1)|splitGroup=\(t.splitGroupID?.uuidString ?? "")|splitIndex=\(t.splitIndex)"
        case .boost(let b):
            let bg = (try? JSONEncoder.orbitSync.encode(b.backgroundColor))?.base64EncodedString() ?? ""
            let tx = (try? JSONEncoder.orbitSync.encode(b.textColor))?.base64EncodedString() ?? ""
            let ac = (try? JSONEncoder.orbitSync.encode(b.accentColor))?.base64EncodedString() ?? ""
            input = "name=\(b.name)|host=\(b.host)|enabled=\(b.isEnabled)|selectors=\(b.zappedSelectors.joined(separator: ","))|css=\(b.customCSS)|js=\(b.customJavaScript)|bg=\(bg)|tx=\(tx)|ac=\(ac)|font=\(b.fontFamily ?? "")|created=\(b.createdAt.timeIntervalSinceReferenceDate)"
        case .easel(let e):
            let items = (try? JSONEncoder.orbitSync.encode(e.items))?.base64EncodedString() ?? ""
            input = "title=\(e.title)|items=\(items)|created=\(e.createdAt.timeIntervalSinceReferenceDate)|originX=\(e.viewportOrigin.x)|originY=\(e.viewportOrigin.y)|zoom=\(e.viewportZoom)"
        case .note(let n):
            input = "title=\(n.title)|body=\(n.bodyData.base64EncodedString())|created=\(n.createdAt.timeIntervalSinceReferenceDate)"
        case .routingRule(let r):
            input = "pattern=\(r.pattern)|enabled=\(r.isEnabled)|dest=\(destinationDescription(r.destination))"
        }
        return input
    }

    static func cacheContentHash(for record: CKRecord) -> String {
        guard let payload = payload(from: record) else { return "" }
        return contentHash(for: payload)
    }

    private static func payload(from record: CKRecord) -> PendingPayload? {
        switch record.recordType {
        case SyncRecordType.profile:
            return SyncRecordMapping.profile(from: record).map(PendingPayload.profile)
        case SyncRecordType.space:
            return SyncRecordMapping.spaceScalarFields(from: record).map(PendingPayload.space)
        case SyncRecordType.favorite:
            return SyncRecordMapping.favorite(from: record).map(PendingPayload.favorite)
        case SyncRecordType.sidebarNode:
            return SyncRecordMapping.sidebarNode(from: record).map(PendingPayload.sidebarNode)
        case SyncRecordType.todayEntry:
            return SyncRecordMapping.todayEntry(from: record).map(PendingPayload.todayEntry)
        case SyncRecordType.tab:
            return SyncRecordMapping.tab(from: record).map(PendingPayload.tab)
        case SyncRecordType.boost:
            return SyncRecordMapping.boost(from: record).map(PendingPayload.boost)
        case SyncRecordType.easel:
            return SyncRecordMapping.easel(from: record).map(PendingPayload.easel)
        case SyncRecordType.note:
            return SyncRecordMapping.note(from: record).map(PendingPayload.note)
        case SyncRecordType.routingRule:
            return SyncRecordMapping.routingRule(from: record).map(PendingPayload.routingRule)
        default:
            return nil
        }
    }

    private static func destinationDescription(_ destination: RoutingRule.Destination) -> String {
        switch destination {
        case .space(let id): return "space:\(id)"
        case .profile(let id): return "profile:\(id)"
        case .application(let bundleID): return "application:\(bundleID)"
        case .littleOrbit: return "littleOrbit"
        case .mostRecentSpace: return "mostRecentSpace"
        }
    }

    // MARK: Absorbing incoming changes (pull, and the "server wins" half of conflict resolution)

    private static func reorderedList<ID: Hashable>(existing: [ID], pulledOrder: [(id: ID, order: Int)], deleted: Set<ID>) -> [ID] {
        var seen = Set<ID>()
        let filtered = existing.filter { !deleted.contains($0) && seen.insert($0).inserted }
        let arrived = pulledOrder.map(\.id).filter { !deleted.contains($0) && seen.insert($0).inserted }
        let pulledByID = Dictionary(pulledOrder, uniquingKeysWith: { _, new in new })
        let indexed = (filtered + arrived).enumerated().map { (index: $0.offset, id: $0.element) }
        return indexed.sorted { lhs, rhs in
            let lhsKey = pulledByID[lhs.id].map(Double.init) ?? Double(lhs.index) + 1_000_000
            let rhsKey = pulledByID[rhs.id].map(Double.init) ?? Double(rhs.index) + 1_000_000
            return lhsKey < rhsKey
        }.map(\.id)
    }

    static func mergeFavorites(into space: inout Space, pulled: [FlatFavorite], deletedIDs: Set<UUID>, tombstoned: Set<UUID>) {
        guard !pulled.isEmpty || !deletedIDs.isEmpty else { return }
        var byID = Dictionary(space.favorites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let originalOrder = space.favorites.map(\.id).filter { seen.insert($0).inserted }
        for flat in pulled { byID[flat.favorite.id] = flat.favorite }
        for id in deletedIDs { byID.removeValue(forKey: id) }
        let patched = reorderedList(existing: originalOrder, pulledOrder: pulled.map { ($0.favorite.id, $0.order) }, deleted: deletedIDs)
        let merged = SyncMerge.mergeOrderedIDs(remoteOrder: patched, localOrder: originalOrder, tombstoned: tombstoned)
        space.favorites = merged.compactMap { byID[$0] }
    }

    private static func mergeToday(into space: inout Space, pulled: [FlatTodayEntry], deletedTabIDs: Set<TabID>, tombstoned: Set<TabID>) {
        guard !pulled.isEmpty || !deletedTabIDs.isEmpty else { return }
        let patched = reorderedList(existing: space.today, pulledOrder: pulled.map { ($0.tabID, $0.order) }, deleted: deletedTabIDs)
        space.today = SyncMerge.mergeOrderedIDs(remoteOrder: patched, localOrder: space.today, tombstoned: tombstoned)
    }

    static func mergePinnedTree(into space: inout Space, pulledNodes: [FlatSidebarNode], deletedIDs: Set<UUID>, tombstoned: Set<UUID>) {
        guard !pulledNodes.isEmpty || !deletedIDs.isEmpty else { return }

        let originalFlat = SidebarTreeFlattening.flatten(space.pinned, spaceID: space.id)
        var originalByID = Dictionary(originalFlat.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var patchedByID = originalByID
        for node in pulledNodes { patchedByID[node.id] = node }
        for id in deletedIDs {
            patchedByID.removeValue(forKey: id)
            originalByID.removeValue(forKey: id)
        }

        let parents = Set(patchedByID.values.map(\.parentID))
        for parent in parents {
            let memberIDs = patchedByID.values.filter { $0.parentID == parent }.map(\.id)
            let localOrder = memberIDs.sorted {
                (originalByID[$0]?.order ?? patchedByID[$0]!.order) < (originalByID[$1]?.order ?? patchedByID[$1]!.order)
            }
            let remoteOrder = memberIDs.sorted { patchedByID[$0]!.order < patchedByID[$1]!.order }
            let merged = SyncMerge.mergeOrderedIDs(remoteOrder: remoteOrder, localOrder: localOrder, tombstoned: tombstoned)
            for (index, id) in merged.enumerated() {
                patchedByID[id]?.order = index
            }
        }

        space.pinned = SidebarTreeFlattening.unflatten(Array(patchedByID.values), spaceID: space.id)
    }

    struct IncomingBuckets {
        var profiles: [Profile] = []
        var spaceFields: [SpaceScalarFields] = []
        var favorites: [FlatFavorite] = []
        var sidebarNodes: [FlatSidebarNode] = []
        var todayEntries: [FlatTodayEntry] = []
        var tabs: [Tab] = []
        var boosts: [Boost] = []
        var easels: [Easel] = []
        var notes: [Note] = []
        var routingRules: [RoutingRule] = []

        var deletedProfileIDs: Set<UUID> = []
        var deletedSpaceIDs: Set<UUID> = []
        var deletedTabIDs: Set<UUID> = []
        var deletedBoostIDs: Set<UUID> = []
        var deletedEaselIDs: Set<UUID> = []
        var deletedNoteIDs: Set<UUID> = []
        var deletedRoutingRuleIDs: Set<UUID> = []
        var favoriteDeletionsBySpace: [SpaceID: Set<UUID>] = [:]
        var sidebarDeletionsBySpace: [SpaceID: Set<UUID>] = [:]
        var todayDeletionsBySpace: [SpaceID: Set<TabID>] = [:]

        var hasChanges: Bool {
            !profiles.isEmpty || !spaceFields.isEmpty || !favorites.isEmpty || !sidebarNodes.isEmpty
                || !todayEntries.isEmpty || !tabs.isEmpty || !boosts.isEmpty || !easels.isEmpty || !notes.isEmpty
                || !routingRules.isEmpty || !deletedProfileIDs.isEmpty || !deletedSpaceIDs.isEmpty
                || !deletedTabIDs.isEmpty || !deletedBoostIDs.isEmpty || !deletedEaselIDs.isEmpty
                || !deletedNoteIDs.isEmpty || !deletedRoutingRuleIDs.isEmpty || !favoriteDeletionsBySpace.isEmpty
                || !sidebarDeletionsBySpace.isEmpty || !todayDeletionsBySpace.isEmpty
        }

        @discardableResult
        mutating func absorb(_ record: CKRecord) -> Bool {
            switch record.recordType {
            case SyncRecordType.profile:
                guard let m = SyncRecordMapping.profile(from: record) else { return false }
                if SyncScope.isSyncable(m) { profiles.append(m) }
            case SyncRecordType.space:
                guard let m = SyncRecordMapping.spaceScalarFields(from: record) else { return false }
                spaceFields.append(m)
            case SyncRecordType.favorite:
                guard let m = SyncRecordMapping.favorite(from: record) else { return false }
                favorites.append(m)
            case SyncRecordType.sidebarNode:
                guard let m = SyncRecordMapping.sidebarNode(from: record) else { return false }
                sidebarNodes.append(m)
            case SyncRecordType.todayEntry:
                guard let m = SyncRecordMapping.todayEntry(from: record) else { return false }
                todayEntries.append(m)
            case SyncRecordType.tab:
                guard let m = SyncRecordMapping.tab(from: record) else { return false }
                tabs.append(m)
            case SyncRecordType.boost:
                guard let m = SyncRecordMapping.boost(from: record) else { return false }
                boosts.append(m)
            case SyncRecordType.easel:
                guard let m = SyncRecordMapping.easel(from: record) else { return false }
                easels.append(m)
            case SyncRecordType.note:
                guard let m = SyncRecordMapping.note(from: record) else { return false }
                notes.append(m)
            case SyncRecordType.routingRule:
                guard let m = SyncRecordMapping.routingRule(from: record) else { return false }
                routingRules.append(m)
            default:
                break
            }
            return true
        }

        mutating func absorbDeletion(id: CKRecord.ID, type: String, groupingKey: String?) {
            if type == SyncRecordType.todayEntry {
                if let (spaceID, tabID) = TodayEntryRecordName.parse(id.recordName) {
                    todayDeletionsBySpace[spaceID, default: []].insert(tabID)
                }
                return
            }
            guard let entityID = UUID(uuidString: id.recordName) else { return }
            switch type {
            case SyncRecordType.profile: deletedProfileIDs.insert(entityID)
            case SyncRecordType.space: deletedSpaceIDs.insert(entityID)
            case SyncRecordType.favorite:
                if let key = groupingKey, let spaceID = UUID(uuidString: key) {
                    favoriteDeletionsBySpace[spaceID, default: []].insert(entityID)
                }
            case SyncRecordType.sidebarNode:
                if let key = groupingKey, let spaceID = UUID(uuidString: key) {
                    sidebarDeletionsBySpace[spaceID, default: []].insert(entityID)
                }
            case SyncRecordType.tab: deletedTabIDs.insert(entityID)
            case SyncRecordType.boost: deletedBoostIDs.insert(entityID)
            case SyncRecordType.easel: deletedEaselIDs.insert(entityID)
            case SyncRecordType.note: deletedNoteIDs.insert(entityID)
            case SyncRecordType.routingRule: deletedRoutingRuleIDs.insert(entityID)
            default: break
            }
        }

        func apply(to state: inout OrbitState, tombstonedUUIDs: Set<UUID>) {
            let localEphemeralProfiles = SyncScope.ephemeralProfileIDs(in: state)
            let localEphemeralSpaces = SyncScope.ephemeralSpaceIDs(in: state)

            for profile in profiles where !localEphemeralProfiles.contains(profile.id) {
                if let idx = state.profiles.firstIndex(where: { $0.id == profile.id }) {
                    state.profiles[idx] = SyncRecordMapping.merging(incoming: profile, onto: state.profiles[idx])
                } else {
                    state.profiles.append(profile)
                }
            }
            state.profiles.removeAll { deletedProfileIDs.contains($0.id) && !localEphemeralProfiles.contains($0.id) }

            for fields in spaceFields where !localEphemeralSpaces.contains(fields.id) {
                if let idx = state.spaces.firstIndex(where: { $0.id == fields.id }) {
                    fields.applying(to: &state.spaces[idx])
                } else {
                    var space = Space(id: fields.id, name: fields.name, profileID: fields.profileID)
                    fields.applying(to: &space)
                    state.spaces.append(space)
                }
            }
            state.spaces.removeAll { deletedSpaceIDs.contains($0.id) && !localEphemeralSpaces.contains($0.id) }

            for tab in tabs where !localEphemeralSpaces.contains(tab.spaceID) {
                state.tabs[tab.id] = SyncRecordMapping.merging(incoming: tab, onto: state.tabs[tab.id])
            }
            for id in deletedTabIDs {
                guard let existing = state.tabs[id], !localEphemeralSpaces.contains(existing.spaceID) else { continue }
                state.tabs.removeValue(forKey: id)
            }

            upsert(boosts, into: &state.boosts, deleting: deletedBoostIDs)
            upsert(easels, into: &state.easels, deleting: deletedEaselIDs)
            upsert(notes, into: &state.notes, deleting: deletedNoteIDs)
            upsert(routingRules, into: &state.routingRules, deleting: deletedRoutingRuleIDs)

            let touchedSpaceIDs = Set(favorites.map(\.spaceID))
                .union(sidebarNodes.map(\.spaceID))
                .union(todayEntries.map(\.spaceID))
                .union(favoriteDeletionsBySpace.keys)
                .union(sidebarDeletionsBySpace.keys)
                .union(todayDeletionsBySpace.keys)
                .subtracting(localEphemeralSpaces)

            for spaceID in touchedSpaceIDs {
                guard let index = state.spaces.firstIndex(where: { $0.id == spaceID }) else { continue }
                var space = state.spaces[index]

                CloudSyncEngine.mergeFavorites(
                    into: &space,
                    pulled: favorites.filter { $0.spaceID == spaceID },
                    deletedIDs: favoriteDeletionsBySpace[spaceID] ?? [],
                    tombstoned: tombstonedUUIDs
                )
                CloudSyncEngine.mergePinnedTree(
                    into: &space,
                    pulledNodes: sidebarNodes.filter { $0.spaceID == spaceID },
                    deletedIDs: sidebarDeletionsBySpace[spaceID] ?? [],
                    tombstoned: tombstonedUUIDs
                )
                CloudSyncEngine.mergeToday(
                    into: &space,
                    pulled: todayEntries.filter { $0.spaceID == spaceID },
                    deletedTabIDs: todayDeletionsBySpace[spaceID] ?? [],
                    tombstoned: tombstonedUUIDs
                )

                state.spaces[index] = space
            }
        }

        private func upsert<T: Identifiable>(_ items: [T], into array: inout [T], deleting ids: Set<UUID>) where T.ID == UUID {
            for item in items {
                if let idx = array.firstIndex(where: { $0.id == item.id }) {
                    array[idx] = item
                } else {
                    array.append(item)
                }
            }
            array.removeAll { ids.contains($0.id) }
        }
    }

    func absorbIncoming(modifications: [CKRecord], deletions: [(id: CKRecord.ID, type: String)]) {
        guard let store else { return }
        var buckets = IncomingBuckets()
        var unreadable: [String] = []

        for record in modifications {
            let name = record.recordID.recordName

            if let pendingClock = pendingLocalModifiedAt[name] {
                let remoteClock = extractClock(record)
                if pendingClock >= remoteClock {
                    let systemData = encodeSystemFields(record)
                    if var cached = recordCache[name] {
                        cached.systemFieldsData = systemData
                        recordCache[name] = cached
                    } else {
                        recordCache[name] = CachedRecord(
                            recordType: record.recordType, systemFieldsData: systemData,
                            contentHash: "", clientModifiedAt: pendingClock, groupingKey: groupingKey(for: record)
                        )
                    }
                    continue
                }
                pendingPush.removeValue(forKey: name)
                pendingLocalModifiedAt.removeValue(forKey: name)
                transport.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            }

            recordCache[name] = CachedRecord(
                recordType: record.recordType,
                systemFieldsData: encodeSystemFields(record),
                contentHash: Self.cacheContentHash(for: record),
                clientModifiedAt: extractClock(record),
                groupingKey: groupingKey(for: record)
            )
            if !buckets.absorb(record) { unreadable.append(record.recordType) }
        }

        if !unreadable.isEmpty {
            unreadableRemoteRecordCount += unreadable.count
            surface(.unreadableRemoteData(count: unreadableRemoteRecordCount, recordTypes: Set(unreadable)))
        }

        for (id, type) in deletions {
            let name = id.recordName
            let key = recordCache[name]?.groupingKey
            tombstones.record(name)
            recordCache.removeValue(forKey: name)
            pendingPush.removeValue(forKey: name)
            pendingLocalModifiedAt.removeValue(forKey: name)
            transport.remove(pendingRecordZoneChanges: [.saveRecord(id), .deleteRecord(id)])
            buckets.absorbDeletion(id: id, type: type, groupingKey: key)
        }

        persistCaches()
        guard buckets.hasChanges else { return }

        let tombstonedUUIDs = Set(tombstones.deletedAt.keys.compactMap(UUID.init(uuidString:)))
        store.applySyncEngineUpdate { state in
            buckets.apply(to: &state, tombstonedUUIDs: tombstonedUUIDs)
            if let repaired = state.repairingSidebarMembership() { state = repaired }
        }
    }

    // MARK: Conflict resolution (push-time `.serverRecordChanged`)

    func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) {
        let name = serverRecord.recordID.recordName
        let clientClock = extractClock(clientRecord)
        let serverClock = extractClock(serverRecord)

        if clientClock >= serverClock {
            for key in clientRecord.allKeys() + clientRecord.encryptedValues.allKeys() {
                serverRecord.setStoredValue(clientRecord.storedValue(forKey: key), forKey: key)
            }
            recordCache[name] = CachedRecord(
                recordType: serverRecord.recordType,
                systemFieldsData: encodeSystemFields(serverRecord),
                contentHash: Self.cacheContentHash(for: serverRecord),
                clientModifiedAt: clientClock,
                groupingKey: groupingKey(for: serverRecord)
            )
            pendingLocalModifiedAt[name] = clientClock
            transport.add(pendingRecordZoneChanges: [.saveRecord(serverRecord.recordID)])
        } else {
            absorbIncoming(modifications: [serverRecord], deletions: [])
            transport.remove(pendingRecordZoneChanges: [.saveRecord(clientRecord.recordID)])
        }
    }

    private func abandonPendingSave(_ recordID: CKRecord.ID) {
        transport.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        pendingPush.removeValue(forKey: recordID.recordName)
        pendingLocalModifiedAt.removeValue(forKey: recordID.recordName)
    }

    // MARK: Error handling

    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) {
        let error = failure.error
        let problem = SyncProblem.classify(error, recordType: failure.record.recordType)
        switch problem.kind {
        case .conflict:
            if let serverRecord = error.serverRecord {
                resolveConflict(clientRecord: failure.record, serverRecord: serverRecord)
            } else {
                abandonPendingSave(failure.record.recordID)
            }
        case .zoneMissing:
            transport.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        case .network, .interrupted:
            break // transient — CKSyncEngine retries automatically
        case .rateLimited(let retryAfter):
            scheduleRetry(after: retryAfter ?? 3)
        default:
            // A rejection that will repeat unchanged is dropped from the queue; the next reconcile re-queues it, so it never retries in a loop.
            if problem.isPermanent { abandonPendingSave(failure.record.recordID) }
            surface(problem)
        }
    }

    private func surface(_ problem: SyncProblem) {
        if case .notAuthenticated = problem.kind {
            status = .unavailable(reason: .noAccount)
            return
        }
        storedProblem = problem
        status = .error(message: problem.message)
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, seconds)))
            guard !Task.isCancelled, let self else { return }
            self.reconcileAndPush()
        }
    }

    func handleTopLevelError(_ error: Error) {
        let problem = SyncProblem.classify(error)
        switch problem.kind {
        case .network, .interrupted:
            break
        case .rateLimited(let retryAfter):
            scheduleRetry(after: retryAfter ?? 3)
        case .zoneMissing:
            transport.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            surface(problem)
        default:
            surface(problem)
        }
    }

    // MARK: Push bookkeeping

    func notePushSucceeded(savedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID]) {
        for record in savedRecords {
            let name = record.recordID.recordName
            let stagedHash = pendingPush[name]?.contentHash
            recordCache[name] = CachedRecord(
                recordType: record.recordType,
                systemFieldsData: encodeSystemFields(record),
                contentHash: stagedHash ?? Self.cacheContentHash(for: record),
                clientModifiedAt: extractClock(record),
                groupingKey: groupingKey(for: record)
            )
            pendingPush.removeValue(forKey: name)
            pendingLocalModifiedAt.removeValue(forKey: name)
        }
        for id in deletedRecordIDs {
            recordCache.removeValue(forKey: id.recordName)
        }
        for url in pendingNoteAssetFiles {
            try? FileManager.default.removeItem(at: url)
        }
        pendingNoteAssetFiles.removeAll()
        persistCaches()
        if pendingPush.isEmpty, transport.pendingRecordZoneChanges.isEmpty, !isRecovering, unreadableRemoteRecordCount == 0 {
            status = .idle(lastSyncedAt: Date())
        }
    }

    private static let maximumChangesPerBatch = 200

    public func replaceICloudWithThisMac() async {
        guard await beginRecovery() else { return }
        do {
            clearPendingChanges()
            transport.add(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
            try await sendChangesOutsideDelegateCallback()
            guard zoneDeletionCompleted() else { return finishRecovery() }
            try restartEngineWithEmptyState()
            transport.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            reconcile()
            try await sendChangesOutsideDelegateCallback()
            finishRecovery()
        } catch {
            // Left queued, the engine would delete the zone on a later send after the user was told it failed.
            transport.remove(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
            failRecovery(error)
        }
    }

    public func replaceThisMacWithICloud() async {
        guard await beginRecovery() else { return }
        do {
            clearPendingChanges()
            try restartEngineWithEmptyState()
            transport.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            try await fetchChangesOutsideDelegateCallback()
            reconcile()
            try await sendChangesOutsideDelegateCallback()
            finishRecovery()
        } catch {
            failRecovery(error)
        }
    }

    private func beginRecovery() async -> Bool {
        guard !isRecovering, isEnabled, isStarted, transport.isActivated else { return false }
        isRecovering = true
        storedProblem = nil
        needsReconcileAfterRecovery = false
        debounceTask?.cancel()
        retryTask?.cancel()
        status = .syncing
        await refreshAccountStatus()
        guard case .syncing = status else {
            isRecovering = false
            return false
        }
        return true
    }

    private func finishRecovery() {
        isRecovering = false
        if case .syncing = status { status = .idle(lastSyncedAt: Date()) }
        if needsReconcileAfterRecovery {
            needsReconcileAfterRecovery = false
            reconcileAndPush()
        }
    }

    private func failRecovery(_ error: Error) {
        surface(SyncProblem.classify(error))
        finishRecovery()
    }

    private func clearPendingChanges() {
        transport.remove(pendingRecordZoneChanges: transport.pendingRecordZoneChanges)
        transport.remove(pendingDatabaseChanges: transport.pendingDatabaseChanges)
        for url in pendingNoteAssetFiles {
            try? FileManager.default.removeItem(at: url)
        }
        pendingNoteAssetFiles.removeAll()
    }

    private func zoneDeletionCompleted() -> Bool {
        let stillPending = transport.pendingDatabaseChanges.contains { change in
            if case .deleteZone(let id) = change { return id == Self.zoneID }
            return false
        }
        transport.remove(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
        guard case .syncing = status else { return false }
        guard !stillPending else {
            surface(.incompleteRecovery())
            return false
        }
        return true
    }

    // CKSyncEngine has no API to forget its change token, so a full re-fetch needs a new engine built without the saved state.
    private func restartEngineWithEmptyState() throws {
        clearLocalCaches()
        transport.deactivate()
        try transport.activate(delegate: self, stateSerialization: nil)
    }

    // MARK: Test-visible state

    #if DEBUG
    var _test_cachedRecordNames: Set<String> { Set(recordCache.keys) }
    var _test_pendingPushNames: Set<String> { Set(pendingPush.keys) }
    func _test_isTombstoned(_ recordName: String) -> Bool { tombstones.contains(recordName) }
    var _test_cachedContentHashes: [String: String] { recordCache.mapValues(\.contentHash) }

    static func _test_desiredContentHashes(for state: OrbitState) -> [String: String] {
        desiredPushes(from: state).mapValues { contentHash(for: $0.payload) }
    }

    static func _test_desiredHashInputs(for state: OrbitState) -> [String: String] {
        desiredPushes(from: state).mapValues { hashInput(for: $0.payload) }
    }
    #endif
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncEngine: @unchecked Sendable {}

extension CloudSyncEngine: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            persistStateSerialization(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                await refreshAccountStatus()
                reconcileAndPush()
            case .signOut:
                status = .unavailable(reason: .noAccount)
            case .switchAccounts:
                resetForAccountSwitch()
                await refreshAccountStatus()
                reconcileAndPush()
            @unknown default:
                await refreshAccountStatus()
            }

        case .fetchedRecordZoneChanges(let changes):
            let modifications = changes.modifications.map(\.record)
            let deletions = changes.deletions.map { (id: $0.recordID, type: $0.recordType) }
            absorbIncoming(modifications: modifications, deletions: deletions)

        case .fetchedDatabaseChanges:
            break // single zone — nothing extra to reconcile at the database level

        case .sentRecordZoneChanges(let sent):
            notePushSucceeded(savedRecords: sent.savedRecords, deletedRecordIDs: sent.deletedRecordIDs)
            for failure in sent.failedRecordSaves {
                handleFailedSave(failure)
            }
            for (_, error) in sent.failedRecordDeletes {
                handleTopLevelError(error)
            }

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                handleTopLevelError(failure.error)
            }
            for (_, error) in sent.failedZoneDeletes where error.code != .zoneNotFound {
                handleTopLevelError(error)
            }

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges:
            break

        case .willSendChanges:
            status = .syncing

        case .didSendChanges:
            if status.isActivelyWorking, !isRecovering, unreadableRemoteRecordCount == 0 {
                status = .idle(lastSyncedAt: Date())
            }

        @unknown default:
            break
        }
    }

    // Device-local only: the record cache, the tombstone log and CKSyncEngine's
    // serialised state. Nothing is deleted from iCloud.
    public func clearLocalCaches() {
        resetForAccountSwitch()
        cachePersistTask?.cancel()
        cachePersistTask = nil
        cacheWriter.remove([recordCacheURL, tombstoneLogURL, stateSerializationURL])
    }

    func resetForAccountSwitch() {
        unreadableRemoteRecordCount = 0
        recordCache.removeAll()
        tombstones = SyncTombstoneLog()
        pendingPush.removeAll()
        pendingLocalModifiedAt.removeAll()
        persistCaches()
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = Array(syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }.prefix(Self.maximumChangesPerBatch))
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            await self?.buildRecordForSave(recordID: recordID)
        }
    }
}

/// Encodes and writes files on one serial queue, in the order they were requested. A newer write to a file replaces an older one still waiting, unless a delete of that file sits between them, so a delete is never overtaken by an earlier write.
nonisolated final class SyncCacheWriter: @unchecked Sendable {

    private enum Operation {
        case write(url: URL, encode: @Sendable () -> Data?)
        case remove([URL])
    }

    private let queue = DispatchQueue(label: "com.orbit.sync-cache-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: [Operation] = []
    private var drainScheduled = false

    static func encode<Value: Encodable>(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    func write(to url: URL, encode: @escaping @Sendable () -> Data?) {
        lock.lock()
        defer { lock.unlock() }
        for index in pending.indices.reversed() {
            switch pending[index] {
            case .remove(let urls) where urls.contains(url):
                pending.append(.write(url: url, encode: encode))
                scheduleDrainLocked()
                return
            case .write(let queuedURL, _) where queuedURL == url:
                pending[index] = .write(url: url, encode: encode)
                return
            default:
                continue
            }
        }
        pending.append(.write(url: url, encode: encode))
        scheduleDrainLocked()
    }

    func remove(_ urls: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(.remove(urls))
        scheduleDrainLocked()
    }

    /// Returns once everything requested before the call has been written. Never call it from the writer's own queue.
    func flush() {
        queue.sync {}
    }

    private func scheduleDrainLocked() {
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.async { [self] in drain() }
    }

    private func drain() {
        while let operation = nextOperation() {
            switch operation {
            case .write(let url, let encode):
                guard let data = encode() else { continue }
                try? data.write(to: url, options: .atomic)
            case .remove(let urls):
                for url in urls { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private func nextOperation() -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else {
            drainScheduled = false
            return nil
        }
        return pending.removeFirst()
    }
}
