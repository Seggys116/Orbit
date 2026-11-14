import SwiftUI
import AppKit

// MARK: - Sidebar

struct AppSidebarView: View {
    @Bindable var model: OrbitApplicationModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.sidebarItems) { item in
                    AppSidebarRow(item: item, isSelected: model.selectedSection == item.section) {
                        model.selectedSection = item.section
                        handleSelection(item.section)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(InspectChrome.surface)
    }

    private func handleSelection(_ section: AppSection) {
        switch section {
        case .indexedDBDatabase(let db):
            model.selectIDBDatabase(db)
        case .indexedDBStore(let db, let store):
            model.selectIDBStore(db, store)
        case .cacheStorageBucket(let name):
            model.loadCacheEntries(name)
        default:
            break
        }
    }
}

private struct AppSidebarRow: View {
    var item: AppSidebarItem
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(item.depth) * 12)
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? InspectChrome.accent : InspectChrome.muted)
                .frame(width: 14)
            Text(item.title)
                .font(InspectChrome.label)
                .foregroundStyle(InspectChrome.ink)
                .lineLimit(1)
            Spacer()
            if let badge = item.badge {
                Text("\(badge)")
                    .font(InspectChrome.monoSmall)
                    .foregroundStyle(InspectChrome.muted)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(InspectChrome.hover))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: InspectChrome.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
                .fill(isSelected ? InspectChrome.selection : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(action: action))
    }
}

// MARK: - Storage table (local + session)

struct AppStorageTableView: View {
    var entries: [OrbitApplicationLogic.StorageEntry]
    var origin: String
    var filter: Binding<String>
    var error: String?
    var onSet: (String, String) -> Void
    var onRemove: (String) -> Void
    var onClear: () -> Void

    @State private var selectedKey: String?
    @State private var editingCell: EditCell?
    @State private var editText: String = ""
    @FocusState private var cellFocused: Bool

    struct EditCell: Equatable {
        var key: String
        var field: EditField
        enum EditField { case value }
    }

    var body: some View {
        InspectSplit(key: "app.storage.detail", defaultFraction: 0.6, minFirst: 150, minSecond: 100, stackBelow: 0) {
            tableContent
        } second: {
            detailPanel
        }
    }

    private var tableContent: some View {
        VStack(spacing: 0) {
            toolbar
            InspectDivider()
            if let err = error {
                InspectEmptyState(symbol: "exclamationmark.triangle", title: "Storage unavailable", message: err)
            } else if entries.isEmpty && filter.wrappedValue.isEmpty {
                InspectEmptyState(symbol: "tray", title: "No entries", message: "This origin has no items in \(origin.isEmpty ? "storage" : origin)")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        tableHeader
                        InspectDivider()
                        ForEach(entries) { entry in
                            storageRow(entry)
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            InspectSearchField(placeholder: "Filter", text: filter)
            Spacer()
            InspectIconButton(symbol: "plus", help: "Add entry") {
                let key = "new_key_\(Int(Date().timeIntervalSince1970) % 1000)"
                onSet(key, "")
            }
            InspectIconButton(symbol: "trash", help: "Clear all entries", action: onClear)
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 6)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("Key").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            InspectVerticalDivider()
            Text("Value").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            InspectVerticalDivider()
            Text("Size").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                .frame(width: 56, alignment: .trailing).padding(.horizontal, 8)
        }
        .frame(height: InspectChrome.rowHeight)
        .background(InspectChrome.surface)
    }

    private func storageRow(_ entry: OrbitApplicationLogic.StorageEntry) -> some View {
        let isSelected = selectedKey == entry.key
        let isEditingValue = editingCell == EditCell(key: entry.key, field: .value)
        return HStack(spacing: 0) {
            Text(entry.key)
                .font(InspectChrome.mono)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
            InspectVerticalDivider()
            Group {
                if isEditingValue {
                    TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(InspectChrome.mono)
                    .focused($cellFocused)
                    .onSubmit {
                        onSet(entry.key, editText)
                        editingCell = nil
                    }
                    .onKeyPress(.escape) { editingCell = nil; return .handled }
                } else {
                    Text(entry.value)
                        .font(InspectChrome.mono)
                        .lineLimit(1)
                        .foregroundStyle(InspectChrome.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            InspectVerticalDivider()
            Text(OrbitApplicationLogic.formatBytes(entry.size))
                .font(InspectChrome.monoSmall)
                .foregroundStyle(InspectChrome.muted)
                .frame(width: 56, alignment: .trailing)
                .padding(.horizontal, 8)
        }
        .frame(height: InspectChrome.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
                .fill(isSelected ? InspectChrome.selection : Color.clear)
                .padding(.horizontal, 2)
        )
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(
            doubleAction: {
                editText = entry.value
                editingCell = EditCell(key: entry.key, field: .value)
                cellFocused = true
            },
            action: { selectedKey = entry.key }
        ))
        .contextMenu {
            Button("Copy key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.key, forType: .string) }
            Button("Copy value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.value, forType: .string) }
            InspectDivider()
            Button("Delete") { onRemove(entry.key) }
        }
    }

    private var detailPanel: some View {
        Group {
            if let key = selectedKey, let entry = entries.first(where: { $0.key == key }) {
                AppValueDetailView(value: entry.value)
            } else {
                InspectEmptyState(symbol: "cursorarrow.click", title: "Select an entry", message: "Click a row to preview its value")
            }
        }
    }
}

// MARK: - Cookie table

struct AppCookieTableView: View {
    @Bindable var model: OrbitApplicationModel
    var session: OrbitInspectSession

    @State private var selectedID: String?
    @State private var editingCookie: OrbitApplicationLogic.CookieRecord?

    var body: some View {
        InspectSplit(key: "app.cookies.detail", defaultFraction: 0.65, minFirst: 200, minSecond: 120, stackBelow: 0) {
            tableContent
        } second: {
            detailPanel
        }
    }

    private var tableContent: some View {
        VStack(spacing: 0) {
            cookieToolbar
            InspectDivider()
            if let err = model.errors["cookies"] {
                InspectEmptyState(symbol: "exclamationmark.triangle", title: "Cookies unavailable", message: err)
            } else {
                // The columns have fixed widths, so a narrow dock scrolls sideways instead of clipping them.
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        cookieHeader
                        InspectDivider()
                        ForEach(model.filteredCookies) { cookie in
                            cookieRow(cookie)
                        }
                    }
                    .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in max(width, 560) }
                }
            }
        }
    }

    private var cookieToolbar: some View {
        HStack(spacing: 8) {
            InspectSearchField(placeholder: "Filter cookies", text: $model.cookieFilter)
            InspectChip("All for site", selected: model.showAllDomainCookies) {
                model.showAllDomainCookies.toggle()
            }
            Spacer()
            InspectIconButton(symbol: "plus", help: "Add cookie") {
                let host = URL(string: session.pageURL)?.host ?? ""
                editingCookie = OrbitApplicationLogic.CookieRecord(
                    id: "", name: "", value: "", domain: "." + host,
                    path: "/", expiresDate: nil, isHTTPOnly: false, isSecure: false,
                    sameSite: "", partitionKey: "", priority: "")
            }
            InspectIconButton(symbol: "trash", help: "Clear all cookies for site", action: model.clearAllCookies)
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 6)
    }

    private var cookieHeader: some View {
        HStack(spacing: 0) {
            cookieHeaderCell("Name", flex: true)
            cookieHeaderCell("Value", flex: true)
            cookieHeaderCell("Domain", width: 130)
            cookieHeaderCell("Path", width: 60)
            cookieHeaderCell("Expires", width: 100)
            cookieHeaderCell("Size", width: 50)
            cookieHeaderCell("H", width: 22)
            cookieHeaderCell("S", width: 22)
            cookieHeaderCell("SameSite", width: 60)
        }
        .frame(height: InspectChrome.rowHeight)
        .background(InspectChrome.surface)
    }

    private func cookieHeaderCell(_ title: String, flex: Bool = false, width: CGFloat? = nil) -> some View {
        Group {
            if flex {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            } else if let w = width {
                Text(title).frame(width: w, alignment: .leading)
            } else {
                Text(title)
            }
        }
        .font(InspectChrome.sectionTitle)
        .foregroundStyle(InspectChrome.muted)
        .padding(.horizontal, 6)
    }

    private func cookieRow(_ cookie: OrbitApplicationLogic.CookieRecord) -> some View {
        let isSelected = selectedID == cookie.id
        return HStack(spacing: 0) {
            Text(cookie.name).font(InspectChrome.mono).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            Text(cookie.value).font(InspectChrome.mono).lineLimit(1).foregroundStyle(InspectChrome.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            Text(cookie.domain).font(InspectChrome.mono).lineLimit(1).frame(width: 130, alignment: .leading).padding(.horizontal, 6)
            Text(cookie.path).font(InspectChrome.mono).lineLimit(1).frame(width: 60, alignment: .leading).padding(.horizontal, 6)
            Text(OrbitApplicationLogic.formatCookieExpiry(cookie.expiresDate)).font(InspectChrome.monoSmall).lineLimit(1).frame(width: 100, alignment: .leading).padding(.horizontal, 6)
            Text(OrbitApplicationLogic.formatBytes(cookie.size)).font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted).frame(width: 50, alignment: .trailing).padding(.horizontal, 6)
            Image(systemName: cookie.isHTTPOnly ? "checkmark" : "").font(.system(size: 9)).frame(width: 22).foregroundStyle(InspectChrome.goodColor)
            Image(systemName: cookie.isSecure ? "lock.fill" : "").font(.system(size: 9)).frame(width: 22).foregroundStyle(InspectChrome.goodColor)
            Text(cookie.sameSite).font(InspectChrome.monoSmall).frame(width: 60, alignment: .leading).padding(.horizontal, 6)
        }
        .frame(height: InspectChrome.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
                .fill(isSelected ? InspectChrome.selection : Color.clear)
                .padding(.horizontal, 2)
        )
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(
            doubleAction: { editingCookie = cookie },
            action: { selectedID = cookie.id }
        ))
        .contextMenu {
            Button("Copy name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cookie.name, forType: .string) }
            Button("Copy value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cookie.value, forType: .string) }
            InspectDivider()
            Button("Edit cookie") { editingCookie = cookie }
            Button("Delete cookie") { model.deleteCookie(cookie) }
        }
    }

    private var detailPanel: some View {
        Group {
            if let sheet = editingCookie {
                AppCookieEditorView(cookie: sheet,
                    onSave: { updated in
                        model.addOrUpdateCookie(updated)
                        editingCookie = nil
                    },
                    onCancel: { editingCookie = nil }
                )
            } else if let id = selectedID, let cookie = model.filteredCookies.first(where: { $0.id == id }) {
                AppCookieDetailView(cookie: cookie)
            } else {
                cookieNote
            }
        }
    }

    private var cookieNote: some View {
        VStack(spacing: 8) {
            InspectEmptyState(symbol: "globe", title: "Cookies",
                message: "HttpOnly cookies are listed here via the browser's native cookie store — they are never exposed to page JavaScript.")
        }
    }
}

private struct AppCookieDetailView: View {
    var cookie: OrbitApplicationLogic.CookieRecord
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                InspectSectionHeader("Cookie details")
                cookieRow("Name", cookie.name)
                cookieRow("Value", cookie.value)
                cookieRow("Domain", cookie.domain)
                cookieRow("Path", cookie.path)
                cookieRow("Expires", OrbitApplicationLogic.formatCookieExpiry(cookie.expiresDate))
                cookieRow("Size", OrbitApplicationLogic.formatBytes(cookie.size))
                cookieRow("HttpOnly", cookie.isHTTPOnly ? "Yes" : "No")
                cookieRow("Secure", cookie.isSecure ? "Yes" : "No")
                cookieRow("SameSite", cookie.sameSite.isEmpty ? "unset" : cookie.sameSite)
                InspectDivider()
                InspectSectionHeader("URL-decoded value")
                Text(OrbitApplicationLogic.urlDecoded(cookie.value))
                    .font(InspectChrome.mono)
                    .textSelection(.enabled)
            }
            .padding(InspectChrome.panelPadding)
        }
    }

    private func cookieRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted).frame(width: 72, alignment: .trailing)
            Text(value).font(InspectChrome.mono).textSelection(.enabled)
        }
    }
}

private struct AppCookieEditorView: View {
    @State private var draft: OrbitApplicationLogic.CookieRecord
    var onSave: (OrbitApplicationLogic.CookieRecord) -> Void
    var onCancel: () -> Void

    init(cookie: OrbitApplicationLogic.CookieRecord, onSave: @escaping (OrbitApplicationLogic.CookieRecord) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: cookie)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                InspectSectionHeader(draft.id.isEmpty ? "Add Cookie" : "Edit Cookie")
                editorField("Name", binding: $draft.name)
                editorField("Value", binding: $draft.value)
                editorField("Domain", binding: $draft.domain)
                editorField("Path", binding: $draft.path)
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("Secure").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                        OrbitToggle(accessibilityLabel: "Secure cookie", isOn: $draft.isSecure)
                    }
                }
                Text("Note: HttpOnly flag cannot be set from the inspector (server-only flag).")
                    .font(InspectChrome.caption)
                    .foregroundStyle(InspectChrome.muted)
                HStack(spacing: 8) {
                    InspectTextButton("Cancel", action: onCancel)
                    InspectTextButton("Save", prominent: true) {
                        // Regen ID
                        var updated = draft
                        updated.id = "\(draft.name)|\(draft.domain)|\(draft.path)"
                        onSave(updated)
                    }
                }
                .padding(.top, 4)
            }
            .padding(InspectChrome.panelPadding)
        }
    }

    private func editorField(_ label: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .font(InspectChrome.mono)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous)
                        .stroke(InspectChrome.hairline, lineWidth: 1)
                )
        }
    }
}

// MARK: - IndexedDB

struct AppIDBDatabaseListView: View {
    @Bindable var model: OrbitApplicationModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("IndexedDB").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                Spacer()
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.session?.command(["op": "app.idbListDatabases"])
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            if let err = model.errors["indexedDB"] {
                InspectEmptyState(symbol: "exclamationmark.triangle", title: "IndexedDB unavailable", message: err)
            } else if model.idbDatabases.isEmpty {
                InspectEmptyState(symbol: "cylinder", title: "No databases", message: "No IndexedDB databases found for this origin.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.idbDatabases) { db in
                            idbDBRow(db)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func idbDBRow(_ db: AppIDBDatabase) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.fill").font(.system(size: 11)).foregroundStyle(InspectChrome.muted)
            Text(db.name).font(InspectChrome.mono)
            Spacer()
            Text("v\(db.version)").font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted)
            InspectIconButton(symbol: "trash", help: "Delete database") {
                model.session?.command(["op": "app.idbDeleteDatabase", "name": db.name])
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    model.session?.command(["op": "app.idbListDatabases"])
                }
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .frame(height: InspectChrome.rowHeight)
        .contentShape(Rectangle())
        .overlay(InspectHitTarget {
            model.selectedSection = .indexedDBDatabase(db.name)
            model.selectIDBDatabase(db.name)
        })
    }
}

struct AppIDBStoreListView: View {
    @Bindable var model: OrbitApplicationModel
    var dbName: String
    var body: some View {
        let stores = model.idbStoresByDB[dbName] ?? []
        VStack(spacing: 0) {
            HStack {
                Text(dbName).font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                Spacer()
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.session?.command(["op": "app.idbGetStoreInfo", "db": dbName])
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            if stores.isEmpty {
                InspectEmptyState(symbol: "tablecells", title: "No object stores", message: "This database has no object stores")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(stores) { store in
                            storeRow(store)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func storeRow(_ store: AppIDBStore) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells").font(.system(size: 11)).foregroundStyle(InspectChrome.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.name).font(InspectChrome.mono)
                Text("keyPath: \(store.keyPath.isEmpty || store.keyPath == "null" ? "none" : store.keyPath)  \(store.autoIncrement ? "autoIncrement" : "")").font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted)
            }
            Spacer()
            Text("\(store.count)").font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted)
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 3)
        .frame(minHeight: InspectChrome.rowHeight)
        .contentShape(Rectangle())
        .overlay(InspectHitTarget {
            model.selectedSection = .indexedDBStore(db: dbName, store: store.name)
            model.selectIDBStore(dbName, store.name)
        })
    }
}

struct AppIDBRecordView: View {
    @Bindable var model: OrbitApplicationModel
    var dbName: String
    var storeName: String

    @State private var selectedID: String?
    @State private var editingRecord: AppIDBRecord?
    @State private var editJSON: String = ""
    @State private var editError: String?

    var body: some View {
        InspectSplit(key: "app.idb.detail", defaultFraction: 0.6, minFirst: 180, minSecond: 120, stackBelow: 0) {
            tableContent
        } second: {
            detailPanel
        }
    }

    private var tableContent: some View {
        VStack(spacing: 0) {
            idbToolbar
            InspectDivider()
            if let err = model.errors["indexedDB"] {
                InspectEmptyState(symbol: "exclamationmark.triangle", title: "Error", message: err)
            } else if model.idbCurrentRecords.isEmpty {
                InspectEmptyState(symbol: "tablecells", title: "No records", message: "This object store is empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        idbHeader
                        InspectDivider()
                        ForEach(model.idbCurrentRecords) { record in
                            idbRecordRow(record)
                        }
                    }
                }
                paginationBar
            }
        }
    }

    private var idbToolbar: some View {
        HStack(spacing: 8) {
            Text(storeName).font(InspectChrome.label).foregroundStyle(InspectChrome.muted)
            Spacer()
            InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                model.loadIDBRecords(page: 0)
            }
            InspectIconButton(symbol: "trash", help: "Clear store") {
                model.clearIDBStore(dbName, storeName)
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 6)
    }

    private var idbHeader: some View {
        HStack(spacing: 0) {
            Text("Key").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            InspectVerticalDivider()
            Text("Primary key").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            InspectVerticalDivider()
            Text("Value").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
        }
        .frame(height: InspectChrome.rowHeight)
        .background(InspectChrome.surface)
    }

    private func idbRecordRow(_ record: AppIDBRecord) -> some View {
        let isSelected = selectedID == record.id
        return HStack(spacing: 0) {
            Text(record.keyDisplay).font(InspectChrome.mono).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            InspectVerticalDivider()
            Text(record.primaryKeyDisplay).font(InspectChrome.mono).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            InspectVerticalDivider()
            Text(record.value).font(InspectChrome.mono).lineLimit(1).foregroundStyle(InspectChrome.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
        }
        .frame(height: InspectChrome.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
                .fill(isSelected ? InspectChrome.selection : Color.clear)
                .padding(.horizontal, 2)
        )
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(
            doubleAction: {
                editJSON = record.value
                editingRecord = record
                editError = nil
            },
            action: { selectedID = record.id }
        ))
        .contextMenu {
            Button("Copy key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.keyDisplay, forType: .string) }
            Button("Copy value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.value, forType: .string) }
            InspectDivider()
            Button("Delete record") { model.deleteIDBRecord(record) }
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 8) {
            let totalPages = max(1, (model.idbTotalRecords + 49) / 50)
            Text("Page \(model.idbCurrentPage + 1) of \(totalPages) · \(model.idbTotalRecords) records")
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted)
            Spacer()
            InspectTextButton("← Prev", enabled: model.idbCurrentPage > 0) {
                model.loadIDBRecords(page: model.idbCurrentPage - 1)
            }
            InspectTextButton("Next →", enabled: (model.idbCurrentPage + 1) * 50 < model.idbTotalRecords) {
                model.loadIDBRecords(page: model.idbCurrentPage + 1)
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 6)
        .background(InspectChrome.surface)
    }

    private var detailPanel: some View {
        Group {
            if let record = editingRecord {
                idbEditPanel(record)
            } else if let id = selectedID, let record = model.idbCurrentRecords.first(where: { $0.id == id }) {
                AppValueDetailView(value: record.value)
            } else {
                InspectEmptyState(symbol: "cursorarrow.click", title: "Select a record", message: "Click a row to preview its value. Double-click to edit.")
            }
        }
    }

    private func idbEditPanel(_ record: AppIDBRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Edit record value (JSON)").font(InspectChrome.label).foregroundStyle(InspectChrome.muted)
                Spacer()
                InspectTextButton("Cancel") { editingRecord = nil }
                InspectTextButton("Save", prominent: true) {
                    // Validate JSON
                    guard let data = editJSON.data(using: .utf8),
                          (try? JSONSerialization.jsonObject(with: data)) != nil else {
                        editError = "Invalid JSON"
                        return
                    }
                    model.session?.command(["op": "app.idbPutRecord", "db": dbName, "store": storeName, "valueJSON": editJSON])
                    editingRecord = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        model.loadIDBRecords()
                    }
                }
            }
            .padding([.horizontal, .top], InspectChrome.panelPadding)
            if let err = editError {
                Text(err).font(InspectChrome.caption).foregroundStyle(InspectChrome.badColor)
                    .padding(.horizontal, InspectChrome.panelPadding)
            }
            TextEditor(text: $editJSON)
                .font(InspectChrome.mono)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, InspectChrome.panelPadding)
        }
    }
}

// MARK: - Cache Storage

struct AppCacheBucketListView: View {
    @Bindable var model: OrbitApplicationModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cache storage").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                Spacer()
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.session?.command(["op": "app.listCaches"])
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            if let err = model.errors["cacheStorage"] {
                InspectEmptyState(symbol: "exclamationmark.triangle", title: "Cache Storage unavailable", message: err)
            } else if model.cacheNames.isEmpty {
                InspectEmptyState(symbol: "archivebox", title: "No caches", message: "No Cache Storage caches found for this origin")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.cacheNames, id: \.self) { name in
                            cacheBucketRow(name)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func cacheBucketRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill").font(.system(size: 11)).foregroundStyle(InspectChrome.muted)
            Text(name).font(InspectChrome.mono)
            Spacer()
            InspectIconButton(symbol: "trash", help: "Delete cache") {
                model.deleteEntireCache(name)
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .frame(height: InspectChrome.rowHeight)
        .contentShape(Rectangle())
        .overlay(InspectHitTarget {
            model.selectedSection = .cacheStorageBucket(name)
            model.loadCacheEntries(name)
        })
    }
}

struct AppCacheEntriesView: View {
    @Bindable var model: OrbitApplicationModel
    var cacheName: String
    @State private var selectedURL: String?

    var body: some View {
        InspectSplit(key: "app.cache.detail", defaultFraction: 0.65, minFirst: 200, minSecond: 120, stackBelow: 0) {
            tableContent
        } second: {
            if let url = selectedURL {
                AppValueDetailView(value: url)
            } else {
                InspectEmptyState(symbol: "cursorarrow.click", title: "Select an entry", message: "Click a row to see the URL")
            }
        }
    }

    private var tableContent: some View {
        let entries = model.cacheEntriesByName[cacheName] ?? []
        return VStack(spacing: 0) {
            HStack {
                Text(cacheName).font(InspectChrome.label).foregroundStyle(InspectChrome.muted)
                Spacer()
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.loadCacheEntries(cacheName)
                }
                InspectIconButton(symbol: "trash", help: "Delete cache") {
                    model.deleteEntireCache(cacheName)
                    model.selectedSection = .cacheStorageHeader
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        Text("URL").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                        Text("Status").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(width: 50).padding(.horizontal, 8)
                        Text("Type").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(width: 110).padding(.horizontal, 8)
                        Text("Size").font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted).frame(width: 60, alignment: .trailing).padding(.horizontal, 8)
                    }
                    .frame(height: InspectChrome.rowHeight)
                    .background(InspectChrome.surface)
                    InspectDivider()
                    ForEach(entries) { entry in
                        cacheEntryRow(entry)
                    }
                }
            }
        }
    }

    private func cacheEntryRow(_ entry: AppCacheEntry) -> some View {
        let isSelected = selectedURL == entry.url
        return HStack(spacing: 0) {
            Text(entry.url).font(InspectChrome.mono).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            Text(entry.status > 0 ? "\(entry.status)" : "—").font(InspectChrome.mono).frame(width: 50).padding(.horizontal, 8)
            Text(entry.contentType.components(separatedBy: ";").first ?? "").font(InspectChrome.monoSmall).lineLimit(1).frame(width: 110, alignment: .leading).padding(.horizontal, 8)
            Text(entry.size >= 0 ? OrbitApplicationLogic.formatBytes(entry.size) : "—").font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted).frame(width: 60, alignment: .trailing).padding(.horizontal, 8)
        }
        .frame(height: InspectChrome.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.rowRadius, style: .continuous)
                .fill(isSelected ? InspectChrome.selection : Color.clear).padding(.horizontal, 2)
        )
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(action: { selectedURL = entry.url }))
        .contextMenu {
            Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.url, forType: .string) }
            InspectDivider()
            Button("Delete entry") { model.deleteCacheEntry(url: entry.url) }
        }
    }
}

// MARK: - Service Workers

struct AppServiceWorkersView: View {
    @Bindable var model: OrbitApplicationModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.session?.command(["op": "app.getServiceWorkers"])
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            if let err = model.errors["serviceWorkers"] {
                InspectEmptyState(symbol: "exclamationmark.triangle", title: "Service Workers unavailable", message: err)
            } else if model.serviceWorkers.isEmpty {
                InspectEmptyState(symbol: "antenna.radiowaves.left.and.right", title: "No service workers", message: "No service worker registrations found for this origin")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.serviceWorkers) { sw in
                            swCard(sw)
                        }
                    }
                    .padding(InspectChrome.panelPadding)
                }
            }
        }
    }

    private func swCard(_ sw: AppServiceWorker) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sw.scope).font(InspectChrome.label).textSelection(.enabled)
                    Text(sw.scriptURL).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted).textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 6) {
                    InspectTextButton("Update") { model.updateServiceWorker(scope: sw.scope) }
                    InspectTextButton("Unregister") { model.unregisterServiceWorker(scope: sw.scope) }
                }
            }
            HStack(spacing: 12) {
                swStateRow("Active", sw.active)
                swStateRow("Waiting", sw.waiting)
                swStateRow("Installing", sw.installing)
            }
            if sw.waiting != nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(InspectChrome.warnColor).font(.system(size: 11))
                    Text("A new service worker is waiting to activate.")
                        .font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                    InspectTextButton("Skip waiting (sends SKIP_WAITING message)") {
                        model.skipWaitingServiceWorker(scope: sw.scope)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("updateViaCache:").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
                Text(sw.updateViaCache.isEmpty ? "imports" : sw.updateViaCache).font(InspectChrome.mono)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous).fill(InspectChrome.surface))
        .overlay(RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous).stroke(InspectChrome.hairline, lineWidth: 1))
    }

    private func swStateRow(_ label: String, _ info: AppServiceWorkerInfo?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted)
            if let info {
                Text(info.state).font(InspectChrome.mono).foregroundStyle(stateColor(info.state))
            } else {
                Text("—").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted2)
            }
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "activated": return InspectChrome.goodColor
        case "activating": return InspectChrome.warnColor
        case "redundant": return InspectChrome.badColor
        default: return InspectChrome.muted
        }
    }
}

// MARK: - Manifest

struct AppManifestView: View {
    @Bindable var model: OrbitApplicationModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    InspectIconButton(symbol: "arrow.clockwise", help: "Reload manifest") {
                        model.session?.command(["op": "app.getManifest"])
                    }
                }
                if let err = model.errors["manifest"] {
                    InspectEmptyState(symbol: "exclamationmark.triangle", title: "Manifest unavailable", message: err)
                } else if let manifest = model.manifestData {
                    manifestContent(manifest)
                } else {
                    InspectEmptyState(symbol: "doc.badge.plus", title: "No manifest", message: "No web app manifest detected on this page")
                }
            }
            .padding(InspectChrome.panelPadding)
        }
    }

    private func manifestContent(_ manifest: OrbitApplicationLogic.ManifestData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Identity
            InspectSectionHeader("Identity")
            manifestRow("name", manifest.name)
            manifestRow("short_name", manifest.shortName)
            manifestRow("start_url", manifest.startURL)
            manifestRow("scope", manifest.scope)
            manifestRow("display", manifest.display)

            // Colors
            if !manifest.themeColor.isEmpty || !manifest.backgroundColor.isEmpty {
                InspectSectionHeader("Colors")
                colorRow("theme_color", manifest.themeColor)
                colorRow("background_color", manifest.backgroundColor)
            }

            // Installability
            InspectSectionHeader("Installability")
            ForEach(model.installabilityChecks) { check in
                HStack(spacing: 6) {
                    Image(systemName: check.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.pass ? InspectChrome.goodColor : InspectChrome.badColor)
                        .font(.system(size: 12))
                    Text(check.label).font(InspectChrome.caption)
                    Spacer()
                    Text(check.detail).font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted)
                }
            }

            // Icons
            if !manifest.icons.isEmpty {
                InspectSectionHeader("Icons", detail: "\(manifest.icons.count)")
                ForEach(manifest.icons) { icon in
                    iconRow(icon, baseURL: model.manifestURL)
                }
            }

            // Shortcuts
            if !manifest.shortcuts.isEmpty {
                InspectSectionHeader("Shortcuts", detail: "\(manifest.shortcuts.count)")
                ForEach(manifest.shortcuts) { shortcut in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortcut.name).font(InspectChrome.label)
                        Text(shortcut.url).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                    }
                }
            }
        }
    }

    private func manifestRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted).frame(width: 120, alignment: .trailing)
            Text(value.isEmpty ? "—" : value).font(InspectChrome.mono).textSelection(.enabled)
            Spacer()
        }
    }

    private func colorRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(InspectChrome.mono).foregroundStyle(InspectChrome.muted).frame(width: 120, alignment: .trailing)
            if !value.isEmpty {
                RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                    .fill(Color(hex: value) ?? Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous).stroke(InspectChrome.hairline, lineWidth: 1))
                    .frame(width: 18, height: 18)
            }
            Text(value.isEmpty ? "—" : value).font(InspectChrome.mono).textSelection(.enabled)
            Spacer()
        }
    }

    private func iconRow(_ icon: OrbitApplicationLogic.ManifestIcon, baseURL: String) -> some View {
        HStack(spacing: 8) {
            // Attempt to load icon if absolute URL
            let iconURL = resolveURL(icon.src, base: baseURL)
            if let url = URL(string: iconURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "photo").foregroundStyle(InspectChrome.muted)
                    }
                }
                .frame(width: 32, height: 32)
                .cornerRadius(4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(icon.src).font(InspectChrome.mono).lineLimit(1).textSelection(.enabled)
                Text("sizes: \(icon.sizes.isEmpty ? "any" : icon.sizes)  type: \(icon.type.isEmpty ? "—" : icon.type)  purpose: \(icon.purpose)").font(InspectChrome.monoSmall).foregroundStyle(InspectChrome.muted)
            }
        }
    }

    private func resolveURL(_ src: String, base: String) -> String {
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return src }
        guard let baseURL = URL(string: base), let resolved = URL(string: src, relativeTo: baseURL) else { return src }
        return resolved.absoluteString
    }
}

// MARK: - Storage Overview / Quota

struct AppStorageOverviewView: View {
    @Bindable var model: OrbitApplicationModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                        model.session?.command(["op": "app.getQuota"])
                    }
                }
                if let err = model.errors["quota"] {
                    Text(err).font(InspectChrome.caption).foregroundStyle(InspectChrome.badColor)
                } else {
                    quotaSection
                }
            }
            .padding(InspectChrome.panelPadding)
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectSectionHeader("Storage quota")
            HStack {
                Text("Usage").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted).frame(width: 80, alignment: .trailing)
                Text(OrbitApplicationLogic.formatBytes(model.quotaUsage)).font(InspectChrome.mono)
            }
            HStack {
                Text("Quota").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted).frame(width: 80, alignment: .trailing)
                Text(model.quotaTotal > 0 ? OrbitApplicationLogic.formatBytes(model.quotaTotal) : "n/a").font(InspectChrome.mono)
            }
            // Usage bar
            if model.quotaTotal > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                            .fill(InspectChrome.hover)
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: OrbitRadius.xs, style: .continuous)
                            .fill(barColor)
                            .frame(width: geo.size.width * OrbitApplicationLogic.quotaFraction(usage: model.quotaUsage, quota: model.quotaTotal), height: 10)
                    }
                }
                .frame(height: 10)
            }
            // Usage details
            if !model.quotaDetails.isEmpty {
                InspectSectionHeader("Usage breakdown")
                ForEach(model.quotaDetails.sorted(by: { $0.value > $1.value }), id: \.key) { key, bytes in
                    HStack {
                        Text(key).font(InspectChrome.mono).frame(width: 130, alignment: .trailing).foregroundStyle(InspectChrome.muted)
                        Text(OrbitApplicationLogic.formatBytes(bytes)).font(InspectChrome.mono)
                    }
                }
            }
            InspectDivider()
            HStack(spacing: 8) {
                Image(systemName: model.quotaIsPersisted ? "lock.fill" : "lock.open")
                    .foregroundStyle(model.quotaIsPersisted ? InspectChrome.goodColor : InspectChrome.warnColor)
                    .font(.system(size: 12))
                Text(model.quotaIsPersisted ? "Storage is persistent (browser will not evict)" : "Storage may be evicted under pressure")
                    .font(InspectChrome.caption)
                if !model.quotaIsPersisted {
                    InspectTextButton("Request persist") { model.requestPersist() }
                }
            }
        }
    }

    private var barColor: Color {
        let fraction = OrbitApplicationLogic.quotaFraction(usage: model.quotaUsage, quota: model.quotaTotal)
        if fraction > 0.8 { return InspectChrome.badColor }
        if fraction > 0.6 { return InspectChrome.warnColor }
        return InspectChrome.accent
    }
}

// MARK: - Frames

struct AppFramesView: View {
    @Bindable var model: OrbitApplicationModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.session?.command(["op": "app.getFrames"])
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            if model.frames.isEmpty {
                InspectEmptyState(symbol: "rectangle.3.group", title: "No frame info", message: "Frame information is gathered when the panel is opened")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.frames) { frame in
                            frameRow(frame)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func frameRow(_ frame: AppFrame) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(frame.depth) * 14)
                Image(systemName: frame.depth == 0 ? "rectangle" : "rectangle.inset.filled")
                    .font(.system(size: 11)).foregroundStyle(InspectChrome.muted)
                Text(frame.url == "cross-origin" ? "cross-origin iframe" : frame.url)
                    .font(InspectChrome.mono).lineLimit(1).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Color.clear.frame(width: CGFloat(frame.depth) * 14 + 17)
                if frame.isSecureContext {
                    Label("Secure", systemImage: "lock.fill").font(InspectChrome.caption).foregroundStyle(InspectChrome.goodColor)
                }
                if frame.isCrossOriginIsolated {
                    Label("Cross-origin isolated", systemImage: "person.crop.circle.badge.checkmark").font(InspectChrome.caption).foregroundStyle(InspectChrome.goodColor)
                }
                if !frame.name.isEmpty {
                    Text("name: \(frame.name)").font(InspectChrome.mono).foregroundStyle(InspectChrome.muted)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Permissions

struct AppPermissionsView: View {
    @Bindable var model: OrbitApplicationModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                InspectIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    model.session?.command(["op": "app.getPermissions"])
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            if let err = model.errors["permissions"] {
                InspectEmptyState(symbol: "exclamationmark.triangle", title: "Permissions unavailable", message: err)
            } else if model.permissions.isEmpty {
                InspectEmptyState(symbol: "lock.shield", title: "No permission data", message: "Permissions are queried when the panel is opened")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.permissions) { perm in
                            permRow(perm)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func permRow(_ perm: AppPermission) -> some View {
        HStack(spacing: 8) {
            Image(systemName: stateSymbol(perm.state))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(stateColor(perm.state))
                .frame(width: 14)
            Text(perm.name).font(InspectChrome.mono).frame(minWidth: 140, alignment: .leading)
            Text(perm.state).font(InspectChrome.mono).foregroundStyle(stateColor(perm.state))
            if !perm.detail.isEmpty && perm.state == "n/a" {
                Text("(not supported in WebKit)").font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
            }
            Spacer()
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .frame(height: InspectChrome.rowHeight)
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "granted": return InspectChrome.goodColor
        case "denied": return InspectChrome.badColor
        case "prompt": return InspectChrome.warnColor
        default: return InspectChrome.muted
        }
    }

    private func stateSymbol(_ state: String) -> String {
        switch state {
        case "granted": return "checkmark.circle.fill"
        case "denied": return "xmark.circle.fill"
        case "prompt": return "questionmark.circle.fill"
        default: return "minus.circle"
        }
    }
}

// MARK: - Value detail / preview

struct AppValueDetailView: View {
    var value: String
    @State private var mode: PreviewMode = .auto

    enum PreviewMode: String, CaseIterable { case auto, raw, json, urlDecoded, base64 }

    private var detectedKind: OrbitApplicationLogic.ValueKind { OrbitApplicationLogic.detectValueKind(value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(PreviewMode.allCases, id: \.self) { m in
                    InspectChip(m.rawValue, selected: mode == m) { mode = m }
                }
                Spacer()
                InspectIconButton(symbol: "doc.on.doc", help: "Copy value") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
            .padding(.horizontal, InspectChrome.panelPadding)
            .padding(.vertical, 6)
            InspectDivider()
            ScrollView {
                Text(displayText)
                    .font(InspectChrome.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(InspectChrome.panelPadding)
            }
        }
    }

    private var displayText: String {
        switch effectiveMode {
        case .json:
            return OrbitApplicationLogic.prettyJSON(value) ?? value
        case .urlDecoded:
            return OrbitApplicationLogic.urlDecoded(value)
        case .base64:
            return OrbitApplicationLogic.base64Decoded(value) ?? "(not valid base64)"
        default:
            return value
        }
    }

    private var effectiveMode: PreviewMode {
        if mode == .auto {
            switch detectedKind {
            case .json: return .json
            case .urlEncoded: return .urlDecoded
            case .base64: return .base64
            default: return .raw
            }
        }
        return mode
    }
}

// MARK: - Color from hex string

private extension Color {
    init?(hex: String) {
        var clean = hex.trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("#") { clean = String(clean.dropFirst()) }
        guard clean.count == 6 || clean.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: clean).scanHexInt64(&value) else { return nil }
        if clean.count == 6 {
            self = Color(red: Double((value >> 16) & 0xFF) / 255,
                         green: Double((value >> 8) & 0xFF) / 255,
                         blue: Double(value & 0xFF) / 255)
        } else {
            self = Color(red: Double((value >> 24) & 0xFF) / 255,
                         green: Double((value >> 16) & 0xFF) / 255,
                         blue: Double((value >> 8) & 0xFF) / 255,
                         opacity: Double(value & 0xFF) / 255)
        }
    }
}
