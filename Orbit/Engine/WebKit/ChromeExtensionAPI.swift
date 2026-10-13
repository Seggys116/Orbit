import AppKit
import Foundation

/// Native half of the Chrome extension wrapper. WebKit runs the extension;
/// calls the wrapper cannot answer itself land here and hit Orbit's own stores.
@MainActor
enum ChromeExtensionAPI {
    static let applicationIdentifier = "com.orbit.chrome"

    static func invoke(
        namespace: String,
        method: String,
        args: [Any],
        declaredPermissions: Set<String>
    ) async -> Result<Any, Error> {
        if let required = requiredPermission(for: namespace), !declaredPermissions.contains(required) {
            return .failure(ChromeExtensionAPIError("Missing \(required) permission."))
        }
        do {
            let value = try await perform(namespace: namespace, method: method, args: args)
            return .success(value)
        } catch {
            return .failure(error)
        }
    }

    static func requiredPermission(for namespace: String) -> String? {
        switch namespace {
        case "bookmarks", "downloads", "history", "sessions", "management", "search":
            return namespace
        default:
            return nil
        }
    }

    private static func perform(namespace: String, method: String, args: [Any]) async throws -> Any {
        switch namespace {
        case "bookmarks": return try bookmarks(method, args)
        case "downloads": return try downloads(method, args)
        case "history": return try await history(method, args)
        case "sessions": return try sessions(method, args)
        case "search": return try search(method, args)
        case "management": return try management(method, args)
        default:
            throw ChromeExtensionAPIError("Orbit has no \(namespace).\(method) wrapper.")
        }
    }

    // MARK: - bookmarks

    private static func bookmarks(_ method: String, _ args: [Any]) throws -> Any {
        let store = AppEnvironment.processRoot.store
        switch method {
        case "getTree":
            return [BookmarkTreeProjection.treeObject(for: store.state)]
        case "get", "getSubTree", "getChildren":
            let id = string(args, 0) ?? (args.first as? [String: Any]).flatMap { $0["id"] as? String } ?? "0"
            guard let node = findNode(id, in: BookmarkTreeProjection.treeObject(for: store.state)) else {
                throw ChromeExtensionAPIError(BookmarkErrors.noNode)
            }
            if method == "getChildren" {
                return node["children"] as? [Any] ?? []
            }
            return [node]
        case "search":
            let query = (args.first as? String) ?? (args.first as? [String: Any])?["query"] as? String ?? ""
            return searchNodes(query, in: BookmarkTreeProjection.treeObject(for: store.state))
        case "create", "move", "update", "remove", "removeTree":
            let object = args.first as? [String: Any] ?? [:]
            do {
                let id = try BookmarkMutationRouter.apply(method: method, args: object, store: store)
                if let node = findNode(id.rawValue, in: BookmarkTreeProjection.treeObject(for: store.state)) {
                    return node
                }
                return ["id": id.rawValue]
            } catch let error as BookmarkMutationError {
                throw ChromeExtensionAPIError(error.message)
            }
        default:
            throw ChromeExtensionAPIError("Unknown bookmarks.\(method)")
        }
    }

    // MARK: - downloads

    private static func downloads(_ method: String, _ args: [Any]) throws -> Any {
        let store = AppEnvironment.processRoot.downloadStore
        switch method {
        case "search":
            return DownloadItemProjection.itemsObject(for: store.downloads)
        case "erase", "open", "show", "removeFile", "showDefaultFolder", "pause", "resume", "cancel":
            if let error = downloadAction(method, args.first as? [String: Any] ?? [:], store: store) {
                throw ChromeExtensionAPIError(error)
            }
            return [:]
        case "download":
            throw ChromeExtensionAPIError("chrome.downloads.download is started by the page, not by this call.")
        default:
            throw ChromeExtensionAPIError("Unknown downloads.\(method)")
        }
    }

    // MARK: - history

    private static func history(_ method: String, _ args: [Any]) async throws -> Any {
        let environment = AppEnvironment.processRoot
        guard let store = environment.browserHistory else {
            throw ChromeExtensionAPIError("History is not available.")
        }
        switch method {
        case "search":
            let query = args.first as? [String: Any] ?? [:]
            let text = query["text"] as? String ?? ""
            let start = millisecondsDate(query["startTime"])
            let end = millisecondsDate(query["endTime"])
            let maxResults = (query["maxResults"] as? NSNumber).map { max($0.intValue, 0) } ?? 100
            guard maxResults > 0 else { return [] }
            let rows = try await store.urlRows(matchingText: text, start: start, end: end, limit: maxResults)
            return rows.map(historyItem)
        case "getVisits":
            let urlString = (args.first as? String) ?? (args.first as? [String: Any])?["url"] as? String ?? ""
            guard let url = URL(string: urlString) else { throw ChromeExtensionAPIError("Url is invalid.") }
            let visits = try await store.visitRows(forURL: url)
            return visits.map(visitItem)
        case "addUrl":
            let object = args.first as? [String: Any] ?? [:]
            let urlString = object["url"] as? String ?? ""
            guard let url = URL(string: urlString) else { throw ChromeExtensionAPIError("Url is invalid.") }
            guard let space = environment.activeSpace else {
                throw ChromeExtensionAPIError("No active Space to record the visit in.")
            }
            let row = await environment.recordVisitReportingItem(
                url: url, title: object["title"] as? String ?? "", profileID: space.profileID, spaceID: space.id
            )
            guard row != nil else { throw ChromeExtensionAPIError("Orbit did not record the visit; this Space keeps no history.") }
            return [:]
        case "deleteUrl":
            let urlString = (args.first as? String) ?? (args.first as? [String: Any])?["url"] as? String ?? ""
            guard let url = URL(string: urlString) else { throw ChromeExtensionAPIError("Url is invalid.") }
            _ = try await store.deleteEntries(matching: url)
            await environment.reloadHistoryCacheAfterBulkImport()
            return [:]
        case "deleteRange":
            let object = args.first as? [String: Any] ?? [:]
            let start = millisecondsDate(object["startTime"]) ?? .distantPast
            let end = millisecondsDate(object["endTime"]) ?? Date()
            guard start <= end else { return [:] }
            _ = try await store.deleteVisits(in: start...end)
            await environment.reloadHistoryCacheAfterBulkImport()
            return [:]
        case "deleteAll":
            guard await environment.clearAllHistory() else {
                throw ChromeExtensionAPIError("Orbit could not clear its history.")
            }
            return [:]
        default:
            throw ChromeExtensionAPIError("Unknown history.\(method)")
        }
    }

    // MARK: - sessions, search, management

    private static func sessions(_ method: String, _ args: [Any]) throws -> Any {
        switch method {
        case "getRecentlyClosed":
            let max = (args.first as? [String: Any])?["maxResults"] as? Int ?? 25
            return recentlyClosed(maxResults: max, in: AppEnvironment.processRoot.store)
        case "restore":
            let id = (args.first as? String) ?? ""
            return try restoreSession(id, in: AppEnvironment.processRoot)
        default:
            throw ChromeExtensionAPIError("Unknown sessions.\(method)")
        }
    }

    private static func search(_ method: String, _ args: [Any]) throws -> Any {
        guard method == "query" else { throw ChromeExtensionAPIError("Unknown search.\(method)") }
        let object = args.first as? [String: Any] ?? [:]
        let text = object["text"] as? String ?? ""
        let disposition = object["disposition"] as? String ?? ""
        try openSearch(text, disposition: disposition)
        return [:]
    }

    private static func management(_ method: String, _ args: [Any]) throws -> Any {
        let store = AppEnvironment.processRoot.extensionStore
        switch method {
        case "getAll":
            return store.installed().map(info)
        case "get", "getSelf":
            let id = string(args, 0) ?? ""
            guard let ext = store.installed().first(where: { $0.id == id }) else {
                throw ChromeExtensionAPIError("No extension with id \(id).")
            }
            return info(ext)
        case "setEnabled":
            let object = args.first as? [String: Any] ?? [:]
            let id = object["id"] as? String ?? string(args, 0) ?? ""
            let enabled = object["enabled"] as? Bool ?? (args.count > 1 ? args[1] as? Bool : nil) ?? true
            try store.setEnabled(enabled, id: id)
            return [:]
        case "uninstall":
            let id = (args.first as? String) ?? (args.first as? [String: Any])?["id"] as? String ?? ""
            try store.remove(id: id)
            return [:]
        default:
            throw ChromeExtensionAPIError("Unknown management.\(method)")
        }
    }

    private static func info(_ ext: LoadedExtension) -> [String: Any] {
        [
            "id": ext.id,
            "name": ext.name,
            "version": ext.version,
            "enabled": ext.isEnabled,
            "installType": "normal",
            "type": "extension",
        ]
    }

    // MARK: - JSON helpers

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func decodeJSON(_ text: String) -> Any {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        return object
    }

    private static func downloadAction(_ method: String, _ arguments: [String: Any], store: DownloadStore) -> String? {
        switch method {
        case "showDefaultFolder":
            let directory = (try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            _ = NSWorkspace.shared.open(directory)
            return nil
        case "erase":
            guard let guids = arguments["guids"] as? [String] else { return "Invalid downloadId" }
            for guid in guids {
                guard let item = downloadItem(guid, store: store) else { continue }
                store.remove(item.id)
            }
            return nil
        case "open":
            guard let item = downloadItem(arguments["guid"] as? String ?? "", store: store) else { return "Invalid downloadId" }
            guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return "Download file already deleted" }
            _ = NSWorkspace.shared.open(item.destinationURL)
            return nil
        case "show":
            guard let item = downloadItem(arguments["guid"] as? String ?? "", store: store) else { return "Invalid downloadId" }
            store.revealInFinder(item.id)
            return nil
        case "removeFile":
            guard let item = downloadItem(arguments["guid"] as? String ?? "", store: store) else { return "Invalid downloadId" }
            guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return "Download file already deleted" }
            guard store.removeFile(item.id) else { return "Unable to remove file" }
            return nil
        default:
            return "Invalid downloadId"
        }
    }

    private static func downloadItem(_ guid: String, store: DownloadStore) -> DownloadItem? {
        guard let uuid = UUID(uuidString: guid) else { return nil }
        return store.downloads.first { $0.id == uuid }
    }

    private static func millisecondsDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    private static func historyItem(_ row: HistoryStore.HistoryURLRow) -> [String: Any] {
        [
            "id": String(row.id),
            "url": row.url.absoluteString,
            "title": row.title,
            "lastVisitTime": row.lastVisit.timeIntervalSince1970 * 1000,
            "visitCount": row.visitCount,
            "typedCount": row.typedCount,
        ]
    }

    private static func visitItem(_ visit: HistoryStore.HistoryVisitRow) -> [String: Any] {
        [
            "id": String(visit.urlID),
            "visitId": String(visit.id),
            "visitTime": visit.visitTime.timeIntervalSince1970 * 1000,
            "referringVisitId": "0",
            "transition": visit.wasTyped ? "typed" : "link",
            "isLocal": true,
        ]
    }

    private static func openSearch(_ text: String, disposition: String) throws {
        let environment = AppEnvironment.frontmost
        guard let spaceID = environment.activeSpace?.id else {
            throw ChromeExtensionAPIError("No active browser window.")
        }
        guard let url = environment.searchEngine(forSpace: spaceID).searchURL(for: text) else {
            throw ChromeExtensionAPIError("No search provider is configured.")
        }
        switch disposition {
        case "NEW_WINDOW":
            let opened = OrbitWindowController.openNewWindow(on: environment).session.environment
            guard let openedSpace = opened.activeSpace?.id else {
                throw ChromeExtensionAPIError("No active browser window.")
            }
            _ = opened.openTab(url: url, in: openedSpace, section: .today, activate: true)
        case "NEW_TAB":
            _ = environment.openTab(url: url, in: spaceID, section: .today, activate: true)
        default:
            guard let tabID = environment.activeTabID else {
                throw ChromeExtensionAPIError("No active browser window.")
            }
            environment.loadInTab(tabID, url: url)
        }
    }

    static func recentlyClosed(maxResults: Int, in store: BrowserStore) -> [[String: Any]] {
        let limit = min(max(maxResults, 0), store.recentlyClosedCapacity)
        var sessions: [[String: Any]] = []
        for record in store.recentlyClosedRecords.reversed() {
            guard sessions.count < limit else { break }
            guard let tab = store.tab(record.tabID) else { continue }
            sessions.append([
                "sessionId": record.tabID.uuidString,
                "lastModified": Int(record.closedAt.timeIntervalSince1970),
                "tab": [
                    "sessionId": record.tabID.uuidString,
                    "url": tab.url.absoluteString,
                    "title": tab.displayTitle,
                    "id": -1,
                    "windowId": -1,
                ],
            ])
        }
        return sessions
    }

    private static func restoreSession(_ sessionID: String, in environment: AppEnvironment) throws -> [String: Any] {
        let store = environment.store
        let record: ClosedTabRecord?
        if sessionID.isEmpty {
            record = store.recentlyClosedRecords.last
        } else if let tabID = UUID(uuidString: sessionID) {
            record = store.recentlyClosedRecords.last { $0.tabID == tabID }
        } else {
            record = nil
        }
        guard let record else { throw ChromeExtensionAPIError("Invalid session id: \(sessionID).") }
        guard store.reopenClosedTab(record.tabID), let tab = store.tab(record.tabID) else {
            throw ChromeExtensionAPIError("Invalid session id: \(record.tabID.uuidString).")
        }
        environment.activateTab(record.tabID)
        let numericID = (environment.engine as? WebKitEngine)?.numericID(for: tab.id)
        return [
            "sessionId": record.tabID.uuidString,
            "lastModified": Int(Date().timeIntervalSince1970),
            "tab": [
                "id": numericID.map { Int($0) } ?? -1,
                "url": tab.url.absoluteString,
                "title": tab.displayTitle,
                "active": true,
            ],
        ]
    }

    private static func string(_ args: [Any], _ index: Int) -> String? {
        guard args.indices.contains(index) else { return nil }
        return args[index] as? String
    }

    private static func findNode(_ id: String, in node: [String: Any]) -> [String: Any]? {
        if node["id"] as? String == id { return node }
        let children = node["children"] as? [[String: Any]] ?? []
        for child in children {
            if let found = findNode(id, in: child) { return found }
        }
        return nil
    }

    private static func searchNodes(_ query: String, in node: [String: Any]) -> [[String: Any]] {
        var matches: [[String: Any]] = []
        func walk(_ node: [String: Any]) {
            let title = (node["title"] as? String) ?? ""
            let url = (node["url"] as? String) ?? ""
            if !query.isEmpty, title.localizedCaseInsensitiveContains(query) || url.localizedCaseInsensitiveContains(query) {
                matches.append(node)
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(node)
        return matches
    }
}

struct ChromeExtensionAPIError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
