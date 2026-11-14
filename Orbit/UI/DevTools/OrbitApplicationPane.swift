import SwiftUI

struct OrbitApplicationPane: View {
    var session: OrbitInspectSession

    var body: some View {
        _AppPaneBody(model: session.application, session: session)
    }
}

// MARK: - Body

private struct _AppPaneBody: View {
    @Bindable var model: OrbitApplicationModel
    var session: OrbitInspectSession

    var body: some View {
        InspectSplit(key: "app.sidebar", defaultFraction: 0.28, minFirst: 180, minSecond: 260, stackBelow: 0) {
            AppSidebarView(model: model)
        } second: {
            contentView
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch model.selectedSection {
        case .manifest:
            AppManifestView(model: model)
        case .serviceWorkers:
            AppServiceWorkersView(model: model)
        case .storageOverview:
            AppStorageOverviewView(model: model)
        case .localStorage:
            storageTableView(type: "local")
        case .sessionStorage:
            storageTableView(type: "session")
        case .indexedDBHeader:
            AppIDBDatabaseListView(model: model)
        case .indexedDBDatabase(let db):
            AppIDBStoreListView(model: model, dbName: db)
        case .indexedDBStore(let db, let store):
            AppIDBRecordView(model: model, dbName: db, storeName: store)
        case .cacheStorageHeader:
            AppCacheBucketListView(model: model)
        case .cacheStorageBucket(let name):
            AppCacheEntriesView(model: model, cacheName: name)
        case .cookiesHeader:
            AppCookieTableView(model: model, session: session)
        case .frames:
            AppFramesView(model: model)
        case .permissions:
            AppPermissionsView(model: model)
        }
    }

    private func storageTableView(type: String) -> some View {
        let isLocal = type == "local"
        let entries = isLocal ? model.filteredLocalStorage : model.filteredSessionStorage
        let origin = isLocal ? model.localStorageOrigin : model.sessionStorageOrigin
        let filter = isLocal
            ? Binding(get: { model.localStorageFilter }, set: { model.localStorageFilter = $0 })
            : Binding(get: { model.sessionStorageFilter }, set: { model.sessionStorageFilter = $0 })
        let error = isLocal ? model.errors["localStorage"] : model.errors["sessionStorage"]
        return AnyView(AppStorageTableView(
            entries: entries,
            origin: origin,
            filter: filter,
            error: error,
            onSet: { key, value in
                if isLocal { model.setLocalStorageEntry(key: key, value: value) }
                else { model.setSessionStorageEntry(key: key, value: value) }
            },
            onRemove: { key in
                if isLocal { model.removeLocalStorageEntry(key: key) }
                else { model.removeSessionStorageEntry(key: key) }
            },
            onClear: {
                if isLocal { model.clearLocalStorage() }
                else { model.clearSessionStorage() }
            }
        ))
    }
}
