import Foundation

/// Native half of the Chrome extension wrapper. WebKit runs the extension;
/// calls the wrapper cannot answer itself land here and hit Orbit's own stores.
@MainActor
enum ChromeExtensionAPI {
    static let applicationIdentifier = "com.orbit.chrome"

    static func invoke(namespace: String, method: String, args: [Any]) async -> Result<Any, Error> {
        do {
            let value = try await perform(namespace: namespace, method: method, args: args)
            return .success(value)
        } catch {
            return .failure(error)
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
            let json = jsonString(object)
            let result = OrbitChromiumBookmarksBridge.shared.perform(method: method, argsJSON: json)
            if let error = result["error"] { throw ChromeExtensionAPIError(error) }
            if let id = result["id"], let node = findNode(id, in: BookmarkTreeProjection.treeObject(for: store.state)) {
                return node
            }
            return result
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
            let json = jsonString(args.first as? [String: Any] ?? [:])
            if let error = OrbitChromiumDownloadsBridge.shared.perform(method: method, argsJSON: json) {
                throw ChromeExtensionAPIError(error.rawValue)
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
        let bridge = OrbitChromiumHistoryBridge.shared
        let json: String
        switch method {
        case "search":
            json = await bridge.search(jsonString(args.first as? [String: Any] ?? [:]))
        case "getVisits":
            let url = (args.first as? String) ?? (args.first as? [String: Any])?["url"] as? String ?? ""
            json = await bridge.getVisits(url)
        case "addUrl":
            let object = args.first as? [String: Any] ?? [:]
            json = await bridge.addUrl(object["url"] as? String ?? "", title: object["title"] as? String ?? "")
        case "deleteUrl":
            let url = (args.first as? String) ?? (args.first as? [String: Any])?["url"] as? String ?? ""
            json = await bridge.deleteURL(url)
        case "deleteRange":
            let object = args.first as? [String: Any] ?? [:]
            let start = (object["startTime"] as? NSNumber)?.doubleValue ?? 0
            let end = (object["endTime"] as? NSNumber)?.doubleValue ?? 0
            json = await bridge.deleteRange(startMilliseconds: start, endMilliseconds: end)
        case "deleteAll":
            json = await bridge.deleteAll()
        default:
            throw ChromeExtensionAPIError("Unknown history.\(method)")
        }
        if json.isEmpty { return [] }
        return decodeJSON(json)
    }

    // MARK: - sessions, search, management

    private static func sessions(_ method: String, _ args: [Any]) throws -> Any {
        switch method {
        case "getRecentlyClosed":
            let max = (args.first as? [String: Any])?["maxResults"] as? Int ?? 25
            return decodeJSON(OrbitChromiumSessionsBridge.shared.recentlyClosedJSON(maxResults: Int32(max)))
        case "restore":
            let id = (args.first as? String) ?? ""
            return decodeJSON(OrbitChromiumSessionsBridge.shared.restoreJSON(sessionID: id))
        default:
            throw ChromeExtensionAPIError("Unknown sessions.\(method)")
        }
    }

    private static func search(_ method: String, _ args: [Any]) throws -> Any {
        guard method == "query" else { throw ChromeExtensionAPIError("Unknown search.\(method)") }
        let object = args.first as? [String: Any] ?? [:]
        let text = object["text"] as? String ?? ""
        let disposition = object["disposition"] as? String ?? ""
        let target: OrbitChromiumSearchBridge.Target
        switch disposition {
        case "NEW_TAB": target = .newTab
        case "NEW_WINDOW": target = .newWindow
        default: target = .currentTab
        }
        let error = OrbitChromiumSearchBridge.shared.perform(text: text, target: target)
        if !error.isEmpty { throw ChromeExtensionAPIError(error) }
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
