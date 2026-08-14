import Combine
import Foundation
import OSLog

@MainActor
public final class ContentBlockingController: ObservableObject {

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "ContentBlocking")

    // MARK: - Published state

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var enabledListIDs: Set<String>
    @Published public private(set) var allowlistedHosts: Set<String>
    @Published public private(set) var listStates: [String: FilterListState] = [:]
    @Published public private(set) var compileStats = ContentBlockingCompileStats()
    @Published public private(set) var listCompileStats: [String: ContentBlockingCompileStats] = [:]
    @Published public private(set) var isUpdating = false
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var compiledRuleCount = 0

    // MARK: - Collaborators

    public let blocker = ContentBlocker()
    private let store: FilterListStore
    private let defaults: UserDefaults
    private weak var engine: (any BrowserEngine)?

    private struct WeakSessionBox {
        weak var session: (any EngineSession)?
    }
    private var sessions: [ObjectIdentifier: WeakSessionBox] = [:]

    private var initialCacheLoadTask: Task<Void, Never>?

    public private(set) var hasCompletedInitialCacheLoad = false

    // MARK: - Capability

    public private(set) var engineCanCountBlockedRequests = false
    public private(set) var engineSupportsContentBlocking = false

    public var blockedRequestCount: UInt64? {
        engineCanCountBlockedRequests ? blocker.blockedRequestCount : nil
    }

    public func blockedRequestCount(forHost host: String) -> UInt64? {
        engineCanCountBlockedRequests ? blocker.blockedRequestCount(forDocumentHost: host) : nil
    }

    // MARK: - Defaults keys

    private enum Key {
        static let enabled = "contentBlocking.enabled"
        static let lists = "contentBlocking.enabledLists"
        static let allowlist = "contentBlocking.allowlist"
        static let lastUpdated = "contentBlocking.lastUpdatedAt"
        static let uBlockListMigration = "contentBlocking.enabledLists.didAddUBlockDefault"
        static let uBlockUnbreakListMigration = "contentBlocking.enabledLists.didAddUBlockUnbreakDefault"
    }

    // MARK: - Init

    public init(store: FilterListStore? = nil, defaults: UserDefaults = OrbitDefaults.standard) {
        self.store = store ?? FilterListStore(directory: FilterListStore.defaultDirectory())
        self.defaults = defaults

        self.isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        let persistedLists = defaults.stringArray(forKey: Key.lists)
        self.enabledListIDs = Set(persistedLists ?? Array(FilterListCatalog.defaultEnabledIDs))
        self.allowlistedHosts = Set(defaults.stringArray(forKey: Key.allowlist) ?? [])
        self.lastUpdatedAt = defaults.object(forKey: Key.lastUpdated) as? Date

        blocker.isEnabled = isEnabled
        blocker.setAllowlist(allowlistedHosts)

        Self.migrateEnabledLists(
            &enabledListIDs,
            hadPersistedSelection: persistedLists != nil,
            defaults: defaults
        )
    }

    private static func migrateEnabledLists(
        _ ids: inout Set<String>,
        hadPersistedSelection: Bool,
        defaults: UserDefaults
    ) {
        guard hadPersistedSelection else { return }
        adoptDefault("uBlock", migrationKey: Key.uBlockListMigration, into: &ids, defaults: defaults)
        adoptDefault("uBlockUnbreak", migrationKey: Key.uBlockUnbreakListMigration, into: &ids, defaults: defaults)
    }

    private static func adoptDefault(
        _ listID: String,
        migrationKey: String,
        into ids: inout Set<String>,
        defaults: UserDefaults
    ) {
        guard defaults.object(forKey: migrationKey) == nil else { return }
        defaults.set(true, forKey: migrationKey)
        guard !ids.contains(listID) else { return }
        ids.insert(listID)
        defaults.set(Array(ids).sorted(), forKey: Key.lists)
    }

    // MARK: - Engine binding

    public func attach(engine: any BrowserEngine, sessions newSessions: [any EngineSession]) async {
        self.engine = engine
        engineSupportsContentBlocking = engine.capabilities.contains(.contentBlocking)
        engineCanCountBlockedRequests = engine.capabilities.contains(.blockedRequestCounts)
        sessions = sessions.filter { $0.value.session != nil }
        for session in newSessions {
            self.sessions[ObjectIdentifier(session)] = WeakSessionBox(session: session)
        }
        await pushToEngine()
    }

    private func pushToEngine() async {
        guard let engine, engineSupportsContentBlocking else { return }
        let payload: ContentBlocker? = isEnabled ? blocker : nil
        for box in sessions.values {
            guard let session = box.session else { continue }
            await engine.applyContentBlocker(payload, session: session)
        }
    }

    // MARK: - Settings

    public func setEnabled(_ newValue: Bool) async {
        guard newValue != isEnabled else { return }
        isEnabled = newValue
        blocker.isEnabled = newValue
        defaults.set(newValue, forKey: Key.enabled)
        if newValue && compiledRuleCount == 0 {
            await refresh()
        } else {
            await pushToEngine()
        }
    }

    public func setList(_ listID: String, enabled: Bool) async {
        guard FilterListCatalog.descriptor(id: listID) != nil else { return }
        if enabled {
            guard !enabledListIDs.contains(listID) else { return }
            enabledListIDs.insert(listID)
        } else {
            guard enabledListIDs.contains(listID) else { return }
            enabledListIDs.remove(listID)
        }
        defaults.set(Array(enabledListIDs).sorted(), forKey: Key.lists)
        await refresh()
    }

    public func isCategoryEnabled(_ category: FilterListCategory) -> Bool {
        FilterListCatalog.lists(in: category).contains { enabledListIDs.contains($0.id) }
    }

    public func setCategory(_ category: FilterListCategory, enabled: Bool) async {
        let lists = FilterListCatalog.lists(in: category)
        guard !lists.isEmpty else { return }

        var changed = false
        if enabled {
            var toEnable = lists.filter(\.isDefaultEnabled).map(\.id)
            if toEnable.isEmpty, let first = lists.first { toEnable = [first.id] }
            for id in toEnable where !enabledListIDs.contains(id) {
                enabledListIDs.insert(id)
                changed = true
            }
        } else {
            for descriptor in lists where enabledListIDs.contains(descriptor.id) {
                enabledListIDs.remove(descriptor.id)
                changed = true
            }
        }
        guard changed else { return }
        defaults.set(Array(enabledListIDs).sorted(), forKey: Key.lists)
        await refresh()
    }

    // MARK: - Per-site allowlist

    public func isAllowlisted(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return blocker.isAllowlisted(host: host)
    }

    @discardableResult
    public func setAllowlisted(_ allowlisted: Bool, for url: URL) async -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let key = ContentBlockerRuleSet.baseDomain(of: host)
        if allowlisted {
            guard !allowlistedHosts.contains(key) else { return true }
            allowlistedHosts.insert(key)
        } else {
            let before = allowlistedHosts
            allowlistedHosts = allowlistedHosts.filter { !ContentBlockingURL.host(host, matchesDomain: $0) }
            guard before != allowlistedHosts else { return true }
        }
        defaults.set(Array(allowlistedHosts).sorted(), forKey: Key.allowlist)
        blocker.setAllowlist(allowlistedHosts)
        await pushToEngine()
        return true
    }

    // MARK: - Updating

    public func refresh(force: Bool = false) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let ids = enabledListIDs
        let results = await store.updateAll(ids: ids, force: force)
        for (id, state) in results {
            listStates[id] = state
            if case .failed(let message, _) = state {
                Self.logger.error("Filter list \(id, privacy: .public) failed: \(message, privacy: .public)")
            }
        }
        for descriptor in FilterListCatalog.all where listStates[descriptor.id] == nil {
            listStates[descriptor.id] = await store.state(of: descriptor.id)
        }

        await compile()
        lastUpdatedAt = Date()
        defaults.set(lastUpdatedAt, forKey: Key.lastUpdated)
    }

    public func loadFromCache() async {
        listStates = await store.states()
        await compile()
    }

    @discardableResult
    public func beginInitialCacheLoad() -> Task<Void, Never> {
        if let initialCacheLoadTask { return initialCacheLoadTask }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadFromCache()
            self.hasCompletedInitialCacheLoad = true
        }
        initialCacheLoadTask = task
        return task
    }

    // AppEnvironment.materializeWebContents awaits this before a session's
    // first navigation; must block on loadFromCache(), not refresh().
    public func awaitInitialCacheLoad() async {
        await beginInitialCacheLoad().value
    }

    private func compile() async {
        let ids = enabledListIDs
        let store = self.store

        let (built, perListStats) = await Self.buildRuleSet(ids: ids, store: store)

        blocker.setRuleSet(built)
        compiledRuleCount = built.networkRuleCount
        compileStats = built.stats
        listCompileStats = perListStats
        Self.logger.info(
            """
            Compiled \(built.networkRuleCount, privacy: .public) network rules \
            (\(built.stats.redirectRules, privacy: .public) redirect, \
            \(built.stats.unblockRules, privacy: .public) un-block), \
            \(built.stats.cosmeticRules, privacy: .public) cosmetic, \
            \(built.stats.unsupportedRules, privacy: .public) unsupported, \
            \(built.untokenizedRuleCount, privacy: .public) untokenized
            """
        )
        await pushToEngine()
    }

    // @concurrent is load-bearing: bare `nonisolated` runs on the caller's
    // (main) actor under NonisolatedNonsendingByDefault. Folds in catalogue
    // order, not completion order, and installs only once every list is done.
    @concurrent
    private nonisolated static func buildRuleSet(
        ids: Set<String>,
        store: FilterListStore
    ) async -> (ContentBlockerRuleSet, [String: ContentBlockingCompileStats]) {
        let descriptors = FilterListCatalog.all.filter { ids.contains($0.id) }

        let outputs: [String: FilterListParser.Output] = await withTaskGroup(
            of: (String, FilterListParser.Output?).self
        ) { group in
            for descriptor in descriptors {
                group.addTask {
                    (descriptor.id, await Self.loadOrParseList(descriptor.id, store: store))
                }
            }
            var result: [String: FilterListParser.Output] = [:]
            for await (id, output) in group {
                if let output { result[id] = output }
            }
            return result
        }

        var ruleSet = ContentBlockerRuleSet()
        for descriptor in descriptors {
            guard let output = outputs[descriptor.id] else { continue }
            ruleSet.add(parsed: output, listID: descriptor.id)
        }
        return (ruleSet, outputs.mapValues(\.stats))
    }

    @concurrent
    private nonisolated static func loadOrParseList(
        _ listID: String,
        store: FilterListStore
    ) async -> FilterListParser.Output? {
        guard let entry = await store.cacheEntry(for: listID) else { return nil }

        if let cached = await store.compiledCacheData(for: listID),
           let output = CompiledFilterListCache.decode(
               cached,
               expectedContentHash: entry.contentHash,
               listID: listID
           ) {
            return output
        }

        guard let text = await store.cachedText(for: listID) else { return nil }
        let output = FilterListParser.parse(text, listID: listID)

        let contentHash = entry.contentHash
        Task {
            let data = CompiledFilterListCache.encode(output, contentHash: contentHash)
            await store.storeCompiledCache(data, for: listID)
        }

        return output
    }
}
