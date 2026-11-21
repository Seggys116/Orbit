import Foundation
import WebKit

// MARK: - Supporting types

struct AppIDBDatabase: Identifiable, Equatable {
    var name: String
    var version: Int
    var id: String { name }
}

struct AppIDBIndex: Identifiable, Equatable {
    var name: String
    var keyPath: String
    var unique: Bool
    var multiEntry: Bool
    var id: String { name }
}

struct AppIDBStore: Identifiable, Equatable {
    var name: String
    var keyPath: String
    var autoIncrement: Bool
    var indexes: [AppIDBIndex]
    var count: Int
    var id: String { name }
}

struct AppIDBRecord: Identifiable, Equatable {
    var keyDisplay: String
    var primaryKeyDisplay: String
    var keyJSON: String
    var primaryKeyJSON: String
    var value: String
    var id: String { primaryKeyJSON + keyJSON }
}

struct AppCacheEntry: Identifiable, Equatable {
    var url: String
    var status: Int
    var contentType: String
    var size: Int
    var id: String { url }
}

struct AppServiceWorkerInfo: Equatable {
    var state: String
    var scriptURL: String
}

struct AppServiceWorker: Identifiable, Equatable {
    var scope: String
    var scriptURL: String
    var updateViaCache: String
    var installing: AppServiceWorkerInfo?
    var waiting: AppServiceWorkerInfo?
    var active: AppServiceWorkerInfo?
    var id: String { scope }
}

struct AppFrame: Identifiable, Equatable {
    var url: String
    var origin: String
    var name: String
    var isSecureContext: Bool
    var isCrossOriginIsolated: Bool
    var depth: Int
    var id: String { url + "|" + String(depth) }
}

struct AppPermission: Identifiable, Equatable {
    var name: String
    var state: String      // "granted", "denied", "prompt", "n/a"
    var detail: String
    var id: String { name }
}

// MARK: - Sidebar

enum AppSection: Hashable {
    case manifest
    case serviceWorkers
    case storageOverview
    case localStorage
    case sessionStorage
    case indexedDBHeader
    case indexedDBDatabase(String)
    case indexedDBStore(db: String, store: String)
    case cacheStorageHeader
    case cacheStorageBucket(String)
    case cookiesHeader
    case frames
    case permissions
}

struct AppSidebarItem: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    var depth: Int
    var section: AppSection
    var badge: Int? = nil
}

// MARK: - Model

@MainActor
@Observable
final class OrbitApplicationModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?

    var messageTypes: Set<String> {
        ["app.localStorageData", "app.sessionStorageData", "app.storageChanged",
         "app.idbDatabases", "app.idbStoreInfo", "app.idbRecords",
         "app.cacheNames", "app.cacheEntries", "app.serviceWorkers",
         "app.manifest", "app.quota", "app.frames", "app.permissions", "app.error"]
    }

    // MARK: Sidebar selection
    var selectedSection: AppSection = .storageOverview {
        didSet {
            if selectedSection != oldValue { updatePolling() }
        }
    }

    // MARK: Local Storage
    var localStorageEntries: [OrbitApplicationLogic.StorageEntry] = []
    var localStorageFilter: String = ""
    var localStorageOrigin: String = ""

    var filteredLocalStorage: [OrbitApplicationLogic.StorageEntry] {
        guard !localStorageFilter.isEmpty else { return localStorageEntries }
        return localStorageEntries.filter {
            $0.key.localizedCaseInsensitiveContains(localStorageFilter) ||
            $0.value.localizedCaseInsensitiveContains(localStorageFilter)
        }
    }

    // MARK: Session Storage
    var sessionStorageEntries: [OrbitApplicationLogic.StorageEntry] = []
    var sessionStorageFilter: String = ""
    var sessionStorageOrigin: String = ""

    var filteredSessionStorage: [OrbitApplicationLogic.StorageEntry] {
        guard !sessionStorageFilter.isEmpty else { return sessionStorageEntries }
        return sessionStorageEntries.filter {
            $0.key.localizedCaseInsensitiveContains(sessionStorageFilter) ||
            $0.value.localizedCaseInsensitiveContains(sessionStorageFilter)
        }
    }

    // MARK: Cookies (native WKHTTPCookieStore)
    var cookieRecords: [OrbitApplicationLogic.CookieRecord] = []
    var cookieFilter: String = ""
    var showAllDomainCookies: Bool = false

    var filteredCookies: [OrbitApplicationLogic.CookieRecord] {
        var result = cookieRecords
        if !showAllDomainCookies, let url = URL(string: session?.pageURL ?? "") {
            result = result.filter { OrbitApplicationLogic.cookie($0, matchesURL: url) }
        }
        if !cookieFilter.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(cookieFilter) ||
                $0.value.localizedCaseInsensitiveContains(cookieFilter) ||
                $0.domain.localizedCaseInsensitiveContains(cookieFilter)
            }
        }
        return result
    }

    // MARK: IndexedDB
    var idbDatabases: [AppIDBDatabase] = []
    var idbStoresByDB: [String: [AppIDBStore]] = [:]
    var idbLoadedDBs: Set<String> = []
    var idbCurrentRecords: [AppIDBRecord] = []
    var idbCurrentPage: Int = 0
    var idbTotalRecords: Int = 0
    var idbFilter: String = ""
    var idbSelectedDB: String?
    var idbSelectedStore: String?

    // MARK: Cache Storage
    var cacheNames: [String] = []
    var cacheEntriesByName: [String: [AppCacheEntry]] = [:]
    var cacheSelectedName: String?

    var currentCacheEntries: [AppCacheEntry] {
        cacheSelectedName.flatMap { cacheEntriesByName[$0] } ?? []
    }

    // MARK: Service Workers
    var serviceWorkers: [AppServiceWorker] = []

    // MARK: Manifest
    var manifestData: OrbitApplicationLogic.ManifestData?
    var manifestURL: String = ""

    var installabilityChecks: [OrbitApplicationLogic.InstallabilityCheck] {
        manifestData.map { OrbitApplicationLogic.installabilityChecks(for: $0) } ?? []
    }

    // MARK: Quota
    var quotaUsage: Int = 0
    var quotaTotal: Int = 0
    var quotaDetails: [String: Int] = [:]
    var quotaIsPersisted: Bool = false

    // MARK: Frames
    var frames: [AppFrame] = []

    // MARK: Permissions
    var permissions: [AppPermission] = []

    // MARK: Per-section errors
    var errors: [String: String] = [:]

    // MARK: Sidebar items (precomputed to avoid body work)
    var sidebarItems: [AppSidebarItem] {
        var items: [AppSidebarItem] = []
        items.append(.init(id: "manifest", title: "Manifest", symbol: "doc.badge.plus", depth: 0, section: .manifest))
        items.append(.init(id: "sw", title: "Service Workers", symbol: "antenna.radiowaves.left.and.right", depth: 0, section: .serviceWorkers, badge: serviceWorkers.isEmpty ? nil : serviceWorkers.count))
        items.append(.init(id: "storage", title: "Storage", symbol: "internaldrive", depth: 0, section: .storageOverview))
        items.append(.init(id: "ls", title: "Local Storage", symbol: "tray", depth: 1, section: .localStorage, badge: localStorageEntries.isEmpty ? nil : localStorageEntries.count))
        items.append(.init(id: "ss", title: "Session Storage", symbol: "tray.2", depth: 1, section: .sessionStorage, badge: sessionStorageEntries.isEmpty ? nil : sessionStorageEntries.count))
        items.append(.init(id: "idb", title: "IndexedDB", symbol: "cylinder", depth: 1, section: .indexedDBHeader, badge: idbDatabases.isEmpty ? nil : idbDatabases.count))
        for db in idbDatabases {
            items.append(.init(id: "idb.\(db.name)", title: db.name, symbol: "cylinder.fill", depth: 2, section: .indexedDBDatabase(db.name)))
            if idbLoadedDBs.contains(db.name) {
                for store in (idbStoresByDB[db.name] ?? []) {
                    items.append(.init(id: "idb.\(db.name).\(store.name)", title: store.name, symbol: "tablecells", depth: 3, section: .indexedDBStore(db: db.name, store: store.name), badge: store.count > 0 ? store.count : nil))
                }
            }
        }
        items.append(.init(id: "cs", title: "Cache Storage", symbol: "archivebox", depth: 1, section: .cacheStorageHeader, badge: cacheNames.isEmpty ? nil : cacheNames.count))
        for name in cacheNames {
            items.append(.init(id: "cs.\(name)", title: name, symbol: "archivebox.fill", depth: 2, section: .cacheStorageBucket(name)))
        }
        items.append(.init(id: "cookies", title: "Cookies", symbol: "globe", depth: 0, section: .cookiesHeader, badge: cookieRecords.isEmpty ? nil : cookieRecords.count))
        items.append(.init(id: "frames", title: "Frames", symbol: "rectangle.3.group", depth: 0, section: .frames, badge: frames.isEmpty ? nil : frames.count))
        items.append(.init(id: "perms", title: "Permissions", symbol: "lock.shield", depth: 0, section: .permissions))
        return items
    }

    @ObservationIgnored private var cookieObserver: AppCookieObserver?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var cookieObserverAttached = false

    // MARK: - OrbitInspectModule

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        guard frame.isMain else { return }
        switch type {
        case "app.localStorageData":
            let origin = OrbitInspectDecode.string(object, "origin")
            let raw = OrbitInspectDecode.objects(object, "entries")
            let entries = raw.map { OrbitApplicationLogic.StorageEntry(key: OrbitInspectDecode.string($0, "key"), value: OrbitInspectDecode.string($0, "value")) }
            let (result, changed) = OrbitApplicationLogic.diffStorage(old: localStorageEntries, new: entries)
            if changed { localStorageEntries = result }
            if localStorageOrigin.isEmpty { localStorageOrigin = origin }
            errors.removeValue(forKey: "localStorage")

        case "app.sessionStorageData":
            let origin = OrbitInspectDecode.string(object, "origin")
            let raw = OrbitInspectDecode.objects(object, "entries")
            let entries = raw.map { OrbitApplicationLogic.StorageEntry(key: OrbitInspectDecode.string($0, "key"), value: OrbitInspectDecode.string($0, "value")) }
            let (result, changed) = OrbitApplicationLogic.diffStorage(old: sessionStorageEntries, new: entries)
            if changed { sessionStorageEntries = result }
            if sessionStorageOrigin.isEmpty { sessionStorageOrigin = origin }
            errors.removeValue(forKey: "sessionStorage")

        case "app.storageChanged":
            // Refetch both storages to stay in sync
            session?.command(["op": "app.getLocalStorage"])
            session?.command(["op": "app.getSessionStorage"])

        case "app.idbDatabases":
            let dbs = OrbitInspectDecode.objects(object, "databases")
            idbDatabases = dbs.map { AppIDBDatabase(name: OrbitInspectDecode.string($0, "name"), version: OrbitInspectDecode.integer($0, "version")) }
            errors.removeValue(forKey: "indexedDB")

        case "app.idbStoreInfo":
            let dbName = OrbitInspectDecode.string(object, "db")
            let storeObjs = OrbitInspectDecode.objects(object, "stores")
            let stores: [AppIDBStore] = storeObjs.map { s in
                let idxObjs = OrbitInspectDecode.objects(s, "indexes")
                let indexes = idxObjs.map { idx in
                    AppIDBIndex(name: OrbitInspectDecode.string(idx, "name"),
                                keyPath: OrbitInspectDecode.string(idx, "keyPath"),
                                unique: OrbitInspectDecode.bool(idx, "unique"),
                                multiEntry: OrbitInspectDecode.bool(idx, "multiEntry"))
                }
                return AppIDBStore(name: OrbitInspectDecode.string(s, "name"),
                                   keyPath: OrbitInspectDecode.string(s, "keyPath"),
                                   autoIncrement: OrbitInspectDecode.bool(s, "autoIncrement"),
                                   indexes: indexes,
                                   count: OrbitInspectDecode.integer(s, "count"))
            }
            idbStoresByDB[dbName] = stores
            idbLoadedDBs.insert(dbName)

        case "app.idbRecords":
            let records: [AppIDBRecord] = OrbitInspectDecode.objects(object, "records").map { r in
                AppIDBRecord(keyDisplay: OrbitInspectDecode.string(r, "keyDisplay"),
                             primaryKeyDisplay: OrbitInspectDecode.string(r, "primaryKeyDisplay"),
                             keyJSON: OrbitInspectDecode.string(r, "keyJSON"),
                             primaryKeyJSON: OrbitInspectDecode.string(r, "primaryKeyJSON"),
                             value: OrbitInspectDecode.string(r, "value"))
            }
            idbCurrentRecords = records
            idbCurrentPage = OrbitInspectDecode.integer(object, "page")
            idbTotalRecords = OrbitInspectDecode.integer(object, "total")

        case "app.cacheNames":
            cacheNames = OrbitInspectDecode.strings(object, "names")
            errors.removeValue(forKey: "cacheStorage")

        case "app.cacheEntries":
            let cacheName = OrbitInspectDecode.string(object, "name")
            let entryObjs = OrbitInspectDecode.objects(object, "entries")
            cacheEntriesByName[cacheName] = entryObjs.map { e in
                AppCacheEntry(url: OrbitInspectDecode.string(e, "url"),
                              status: OrbitInspectDecode.integer(e, "status"),
                              contentType: OrbitInspectDecode.string(e, "contentType"),
                              size: OrbitInspectDecode.integer(e, "size"))
            }

        case "app.serviceWorkers":
            let regObjs = OrbitInspectDecode.objects(object, "registrations")
            serviceWorkers = regObjs.map { reg in
                func workerInfo(_ key: String) -> AppServiceWorkerInfo? {
                    guard let obj = OrbitInspectDecode.object(reg, key) else { return nil }
                    return AppServiceWorkerInfo(state: OrbitInspectDecode.string(obj, "state"),
                                               scriptURL: OrbitInspectDecode.string(obj, "scriptURL"))
                }
                return AppServiceWorker(scope: OrbitInspectDecode.string(reg, "scope"),
                                        scriptURL: OrbitInspectDecode.string(reg, "scriptURL"),
                                        updateViaCache: OrbitInspectDecode.string(reg, "updateViaCache"),
                                        installing: workerInfo("installing"),
                                        waiting: workerInfo("waiting"),
                                        active: workerInfo("active"))
            }
            errors.removeValue(forKey: "serviceWorkers")

        case "app.manifest":
            manifestURL = OrbitInspectDecode.string(object, "url")
            let json = OrbitInspectDecode.string(object, "json")
            manifestData = OrbitApplicationLogic.parseManifest(json)
            if manifestData == nil {
                errors["manifest"] = "Could not parse manifest JSON"
            } else {
                errors.removeValue(forKey: "manifest")
            }

        case "app.quota":
            quotaUsage = OrbitInspectDecode.integer(object, "usage")
            quotaTotal = OrbitInspectDecode.integer(object, "quota")
            quotaIsPersisted = OrbitInspectDecode.bool(object, "isPersisted")
            if let details = OrbitInspectDecode.object(object, "usageDetails") {
                var map: [String: Int] = [:]
                for (k, v) in details {
                    if let n = OrbitInspectDecode.integer(v) { map[k] = n }
                }
                quotaDetails = map
            }
            errors.removeValue(forKey: "quota")

        case "app.frames":
            let frameObjs = OrbitInspectDecode.objects(object, "frames")
            frames = frameObjs.map { f in
                AppFrame(url: OrbitInspectDecode.string(f, "url"),
                         origin: OrbitInspectDecode.string(f, "origin"),
                         name: OrbitInspectDecode.string(f, "name"),
                         isSecureContext: OrbitInspectDecode.bool(f, "isSecureContext"),
                         isCrossOriginIsolated: OrbitInspectDecode.bool(f, "isCrossOriginIsolated"),
                         depth: OrbitInspectDecode.integer(f, "depth"))
            }

        case "app.permissions":
            let permObjs = OrbitInspectDecode.objects(object, "permissions")
            permissions = permObjs.map { p in
                AppPermission(name: OrbitInspectDecode.string(p, "name"),
                              state: OrbitInspectDecode.string(p, "state"),
                              detail: OrbitInspectDecode.string(p, "detail"))
            }
            errors.removeValue(forKey: "permissions")

        case "app.error":
            let section = OrbitInspectDecode.string(object, "section")
            let message = OrbitInspectDecode.string(object, "message")
            errors[section] = message

        default: break
        }
    }

    func pageDidReset(preservingLog: Bool) {
        localStorageEntries = []
        localStorageOrigin = ""
        sessionStorageEntries = []
        sessionStorageOrigin = ""
        idbDatabases = []
        idbStoresByDB = [:]
        idbLoadedDBs = []
        idbCurrentRecords = []
        idbCurrentPage = 0
        idbTotalRecords = 0
        idbSelectedDB = nil
        idbSelectedStore = nil
        cacheNames = []
        cacheEntriesByName = [:]
        cacheSelectedName = nil
        serviceWorkers = []
        manifestData = nil
        manifestURL = ""
        quotaUsage = 0
        quotaTotal = 0
        quotaDetails = [:]
        quotaIsPersisted = false
        frames = []
        permissions = []
        errors = [:]
        panelDidDisappear()
    }

    func panelDidAppear(force: Bool) {
        guard session?.isPanelVisible == true else { return }
        setupCookieObserverIfNeeded()
        loadCookiesNative()
        session?.command(["op": "app.getLocalStorage"])
        session?.command(["op": "app.getSessionStorage"])
        session?.command(["op": "app.idbListDatabases"])
        session?.command(["op": "app.listCaches"])
        session?.command(["op": "app.getServiceWorkers"])
        session?.command(["op": "app.getManifest"])
        session?.command(["op": "app.getQuota"])
        session?.command(["op": "app.getFrames"])
        session?.command(["op": "app.getPermissions"])
        // Re-load the currently selected section's detailed data
        if force { refreshSelectedSection() }
        updatePolling()
    }

    func panelDidDisappear() {
        teardownCookieObserver()
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Cookie native access

    func loadCookiesNative() {
        guard let dataStore = session?.contents?.webView.configuration.websiteDataStore else { return }
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cookieRecords = cookies.map { OrbitApplicationLogic.cookieRecord(from: $0) }
                self.errors.removeValue(forKey: "cookies")
            }
        }
    }

    func addOrUpdateCookie(_ record: OrbitApplicationLogic.CookieRecord) {
        guard let cookie = OrbitApplicationLogic.httpCookie(from: record),
              let dataStore = session?.contents?.webView.configuration.websiteDataStore else { return }
        dataStore.httpCookieStore.setCookie(cookie) { [weak self] in
            Task { @MainActor [weak self] in self?.loadCookiesNative() }
        }
    }

    func deleteCookie(_ record: OrbitApplicationLogic.CookieRecord) {
        guard let dataStore = session?.contents?.webView.configuration.websiteDataStore else { return }
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            // Find the matching cookie by identity: name+domain+path
            let match = cookies.first {
                $0.name == record.name && $0.domain == record.domain && $0.path == record.path
            }
            guard let match else { return }
            dataStore.httpCookieStore.delete(match) { [weak self] in
                Task { @MainActor [weak self] in self?.loadCookiesNative() }
            }
        }
    }

    func clearAllCookies() {
        guard let dataStore = session?.contents?.webView.configuration.websiteDataStore else { return }
        let cookieStore = dataStore.httpCookieStore
        Task { @MainActor [weak self] in
            let cookies = await cookieStore.allCookies()
            guard let self else { return }
            // Only this site's cookies. The store is shared by every tab in the profile.
            let host = URL(string: self.session?.pageURL ?? "")?.host ?? ""
            let site = OrbitApplicationLogic.registrableDomain(of: host)
            for cookie in cookies {
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                guard !site.isEmpty, OrbitApplicationLogic.registrableDomain(of: domain) == site else { continue }
                await cookieStore.deleteCookie(cookie)
            }
            self.loadCookiesNative()
        }
    }

    // MARK: - IDB helpers

    func selectIDBDatabase(_ name: String) {
        idbSelectedDB = name
        idbSelectedStore = nil
        idbCurrentRecords = []
        idbCurrentPage = 0
        if !idbLoadedDBs.contains(name) {
            session?.command(["op": "app.idbGetStoreInfo", "db": name])
        }
    }

    func selectIDBStore(_ db: String, _ store: String) {
        idbSelectedDB = db
        idbSelectedStore = store
        idbCurrentPage = 0
        loadIDBRecords()
    }

    func loadIDBRecords(page: Int? = nil) {
        guard let db = idbSelectedDB, let store = idbSelectedStore else { return }
        let p = page ?? idbCurrentPage
        idbCurrentPage = p
        var cmd: [String: Any] = ["op": "app.idbGetRecords", "db": db, "store": store, "page": p]
        cmd["direction"] = "next"
        session?.command(cmd)
    }

    func deleteIDBRecord(_ record: AppIDBRecord) {
        guard let db = idbSelectedDB, let store = idbSelectedStore else { return }
        session?.command(["op": "app.idbDeleteRecord", "db": db, "store": store, "keyJSON": record.keyJSON])
        // Reload after a brief delay to let IndexedDB commit
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.loadIDBRecords()
        }
    }

    func clearIDBStore(_ db: String, _ store: String) {
        session?.command(["op": "app.idbClearStore", "db": db, "store": store])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.loadIDBRecords()
        }
    }

    // MARK: - Cache helpers

    func loadCacheEntries(_ name: String) {
        cacheSelectedName = name
        session?.command(["op": "app.getCacheEntries", "name": name])
    }

    func deleteCacheEntry(url: String) {
        guard let cache = cacheSelectedName else { return }
        session?.command(["op": "app.deleteCacheEntry", "cacheName": cache, "url": url])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if let name = self?.cacheSelectedName {
                self?.session?.command(["op": "app.getCacheEntries", "name": name])
            }
        }
    }

    func deleteEntireCache(_ name: String) {
        session?.command(["op": "app.deleteCache", "name": name])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.session?.command(["op": "app.listCaches"])
        }
    }

    // MARK: - Storage editing

    func setLocalStorageEntry(key: String, value: String) {
        session?.command(["op": "app.setStorage", "stype": "local", "key": key, "value": value])
        session?.command(["op": "app.getLocalStorage"])
    }

    func removeLocalStorageEntry(key: String) {
        session?.command(["op": "app.removeStorage", "stype": "local", "key": key])
        session?.command(["op": "app.getLocalStorage"])
    }

    func clearLocalStorage() {
        session?.command(["op": "app.clearStorage", "stype": "local"])
        session?.command(["op": "app.getLocalStorage"])
    }

    func setSessionStorageEntry(key: String, value: String) {
        session?.command(["op": "app.setStorage", "stype": "session", "key": key, "value": value])
        session?.command(["op": "app.getSessionStorage"])
    }

    func removeSessionStorageEntry(key: String) {
        session?.command(["op": "app.removeStorage", "stype": "session", "key": key])
        session?.command(["op": "app.getSessionStorage"])
    }

    func clearSessionStorage() {
        session?.command(["op": "app.clearStorage", "stype": "session"])
        session?.command(["op": "app.getSessionStorage"])
    }

    // MARK: - Quota

    func requestPersist() {
        session?.command(["op": "app.requestPersist"])
    }

    // MARK: - Service Workers

    func updateServiceWorker(scope: String) {
        session?.command(["op": "app.swUpdate", "scope": scope])
    }

    func unregisterServiceWorker(scope: String) {
        session?.command(["op": "app.swUnregister", "scope": scope])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.session?.command(["op": "app.getServiceWorkers"])
        }
    }

    func skipWaitingServiceWorker(scope: String) {
        session?.command(["op": "app.swSkipWaiting", "scope": scope])
    }

    // MARK: - Private helpers

    private func setupCookieObserverIfNeeded() {
        guard !cookieObserverAttached else { return }
        guard let dataStore = session?.contents?.webView.configuration.websiteDataStore else { return }
        let observer = AppCookieObserver()
        observer.onChange = { [weak self] in self?.loadCookiesNative() }
        dataStore.httpCookieStore.add(observer)
        cookieObserver = observer
        cookieObserverAttached = true
    }

    private func teardownCookieObserver() {
        guard let observer = cookieObserver,
              let dataStore = session?.contents?.webView.configuration.websiteDataStore else {
            cookieObserverAttached = false
            cookieObserver = nil
            return
        }
        dataStore.httpCookieStore.remove(observer)
        cookieObserver = nil
        cookieObserverAttached = false
    }

    private func updatePolling() {
        switch selectedSection {
        case .localStorage, .sessionStorage, .storageOverview:
            guard session?.isPanelVisible == true, session?.panel == .application else { return }
            guard pollTask == nil else { return }
        default:
            pollTask?.cancel()
            pollTask = nil
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(200))
                guard !Task.isCancelled, let self else { break }
                self.refreshStorageForCurrentSection()
            }
        }
    }

    private func refreshStorageForCurrentSection() {
        switch selectedSection {
        case .localStorage:
            session?.command(["op": "app.getLocalStorage"])
        case .sessionStorage:
            session?.command(["op": "app.getSessionStorage"])
        case .storageOverview:
            session?.command(["op": "app.getQuota"])
        default:
            break
        }
    }

    private func refreshSelectedSection() {
        switch selectedSection {
        case .indexedDBDatabase(let db):
            session?.command(["op": "app.idbGetStoreInfo", "db": db])
        case .indexedDBStore(let db, _):
            session?.command(["op": "app.idbGetStoreInfo", "db": db])
            loadIDBRecords(page: 0)
        case .cacheStorageBucket(let name):
            session?.command(["op": "app.getCacheEntries", "name": name])
        default:
            break
        }
    }
}
