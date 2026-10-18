import AppKit
import Foundation
import Observation

/// Native half of the Chrome extension wrapper. WebKit runs the extension;
/// calls the wrapper cannot answer itself land here and hit Orbit's own stores.
@MainActor
enum ChromeExtensionAPI {
    static let applicationIdentifier = WebKitExtensionTransport.applicationIdentifier

    /// `declaredPermissions` is what the extension holds now: its manifest's required
    /// permissions plus any optional ones the user granted. `session` is the profile the
    /// extension was loaded into.
    static func invoke(
        namespace: String,
        method: String,
        args: [Any],
        declaredPermissions: Set<String>,
        extensionID: String = "",
        session: WebKitSession? = nil,
        engine: WebKitEngine? = nil
    ) async -> Result<Any, Error> {
        ensureBookmarkRelay()
        if let required = requiredPermission(for: namespace, method: method), !declaredPermissions.contains(required) {
            return .failure(ChromeExtensionAPIError("Missing \(required) permission."))
        }
        do {
            let value = try await perform(
                namespace: namespace,
                method: method,
                args: args,
                declaredPermissions: declaredPermissions,
                extensionID: extensionID,
                session: session,
                engine: engine
            )
            return .success(value)
        } catch {
            return .failure(error)
        }
    }

    static func requiredPermission(for namespace: String) -> String? {
        switch namespace {
        case "bookmarks", "downloads", "history", "sessions", "management", "search", "privacy",
             "idle", "power", "offscreen", "system.cpu", "system.memory", "system.display", "system.storage":
            return namespace
        default:
            return nil
        }
    }

    /// chrome.management keeps three members with no permission dependency upstream.
    static let ungatedManagementMethods: Set<String> = ["getSelf", "uninstallSelf", "getPermissionWarningsByManifest"]

    static func requiredPermission(for namespace: String, method: String) -> String? {
        if namespace == "management", ungatedManagementMethods.contains(method) { return nil }
        return requiredPermission(for: namespace)
    }

    private static func perform(
        namespace: String,
        method: String,
        args: [Any],
        declaredPermissions: Set<String>,
        extensionID: String,
        session: WebKitSession?,
        engine: WebKitEngine?
    ) async throws -> Any {
        switch namespace {
        case "bookmarks": return try bookmarks(method, args)
        case "downloads": return try await downloads(method, args, permissions: declaredPermissions, session: session)
        case "history": return try await history(method, args)
        case "sessions": return try sessions(method, args)
        case "search": return try search(method, args)
        case "management": return try management(method, args, extensionID: extensionID, engine: engine)
        case "privacy": return try privacy(method, args)
        case "commands": return commands(method, extensionID: extensionID)
        case "action": return try action(method, args, extensionID: extensionID)
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
                let children = node["children"] as? [[String: Any]] ?? []
                return children.map { child -> [String: Any] in
                    var flat = child
                    flat.removeValue(forKey: "children")
                    return flat
                }
            }
            return [node]
        case "search":
            let tree = BookmarkTreeProjection.treeObject(for: store.state)
            if let object = args.first as? [String: Any] {
                return searchBookmarkQuery(object, in: tree)
            }
            return searchNodes(args.first as? String ?? "", in: tree)
        case "create", "move", "update", "remove", "removeTree":
            let object = bookmarkMutationArguments(method, args)
            let before = (object["id"] as? String).flatMap {
                findNode($0, in: BookmarkTreeProjection.treeObject(for: store.state))
            }
            // The relay also watches this store. Hold it across the whole apply so
            // removeTree's per-child writes stay one notification, which this path posts.
            ensureBookmarkRelay()
            bookmarkRelaySuppressCount += 1
            defer {
                bookmarkRelaySuppressCount -= 1
                refreshBookmarkSnapshot()
            }
            do {
                let id = try BookmarkMutationRouter.apply(method: method, args: object, store: store)
                let node = findNode(id.rawValue, in: BookmarkTreeProjection.treeObject(for: store.state))
                    ?? ["id": id.rawValue]
                postBookmarkMutation(method, id: id.rawValue, before: before, after: node)
                return node
            } catch let error as BookmarkMutationError {
                throw ChromeExtensionAPIError(error.message)
            }
        default:
            throw ChromeExtensionAPIError("Unknown bookmarks.\(method)")
        }
    }

    // MARK: - downloads

    private static func downloads(_ method: String, _ args: [Any], permissions: Set<String>, session: WebKitSession?) async throws -> Any {
        let store = AppEnvironment.processRoot.downloadStore
        switch method {
        case "search":
            return try searchDownloads(args.first as? [String: Any] ?? [:], store: store)
        case "erase":
            return try eraseDownloads(args, store: store)
        case "open", "show", "removeFile", "showDefaultFolder":
            if let error = downloadAction(method, args, permissions: permissions, store: store) {
                throw ChromeExtensionAPIError(error)
            }
            return [:]
        case "pause", "resume", "cancel":
            if let error = await transferAction(method, args, store: store) {
                throw ChromeExtensionAPIError(error)
            }
            return [:]
        case "download":
            return try await startDownload(args.first as? [String: Any] ?? [:], store: store, session: session)
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
            let removed = try await store.deleteEntries(matching: url)
            await environment.reloadHistoryCacheAfterBulkImport()
            if removed { postVisitsRemoved(allHistory: false, urls: [url]) }
            return [:]
        case "deleteRange":
            let object = args.first as? [String: Any] ?? [:]
            let start = millisecondsDate(object["startTime"]) ?? .distantPast
            let end = millisecondsDate(object["endTime"]) ?? Date()
            guard start <= end else { return [:] }
            let purged = try await store.deleteVisits(in: start...end)
            await environment.reloadHistoryCacheAfterBulkImport()
            if !purged.isEmpty { postVisitsRemoved(allHistory: false, urls: purged) }
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

    /// history.onVisitRemoved's payload; WebKitExtensionServices delivers it.
    static func postVisitsRemoved(allHistory: Bool, urls: [URL]) {
        NotificationCenter.default.post(
            name: .orbitHistoryVisitsRemoved, object: nil,
            userInfo: ["allHistory": allHistory, "urls": allHistory ? [String]() : urls.map(\.absoluteString)]
        )
    }

    /// history.onVisited's payload for a visit Orbit just recorded.
    static func postVisited(_ row: HistoryStore.HistoryURLRow) {
        NotificationCenter.default.post(name: .orbitHistoryVisited, object: nil, userInfo: ["item": historyItem(row)])
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
        case "getDevices":
            // Orbit syncs no sessions from other devices, so there are none to list.
            return [Any]()
        default:
            throw ChromeExtensionAPIError("Unknown sessions.\(method)")
        }
    }

    static func performSearchQuery(_ query: [String: Any]) throws {
        _ = try search("query", [query])
    }

    private static func search(_ method: String, _ args: [Any]) throws -> Any {
        guard method == "query" else { throw ChromeExtensionAPIError("Unknown search.\(method)") }
        let object = args.first as? [String: Any] ?? [:]
        let text = object["text"] as? String ?? ""
        let disposition = object["disposition"] as? String ?? ""
        try openSearch(text, disposition: disposition, tabID: integer(object["tabId"]))
        return [:]
    }

    private static func management(_ method: String, _ args: [Any], extensionID: String, engine: WebKitEngine?) throws -> Any {
        let store = AppEnvironment.processRoot.extensionStore
        // The store lists installs. The engine that received the call also holds extensions
        // loaded straight from a directory, which never pass through the store.
        func everyExtension() -> [LoadedExtension] {
            var all = store.installed()
            let engines = engine.map { [$0] } ?? visibleEngines()
            for candidate in engines {
                for loaded in candidate.loadedExtensions(session: candidate.defaultSession)
                where !all.contains(where: { $0.id == loaded.id }) {
                    all.append(loaded)
                }
            }
            return all
        }
        func installed(_ id: String) throws -> LoadedExtension {
            guard let ext = everyExtension().first(where: { $0.id == id }) else {
                throw ChromeExtensionAPIError("Failed to find extension with id \(id).")
            }
            return ext
        }
        switch method {
        case "getAll":
            return everyExtension().map(extensionInfo)
        case "get":
            return extensionInfo(try installed(string(args, 0) ?? ""))
        case "getSelf":
            return extensionInfo(try installed(extensionID))
        case "getPermissionWarningsById":
            let ext = try installed(string(args, 0) ?? "")
            let manifest = try ChromeExtensionManifest.read(fromDirectory: ext.directory)
            return installWarnings(for: manifest)
        case "getPermissionWarningsByManifest":
            guard let text = string(args, 0), let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let manifest = try? ChromeExtensionManifest.parse(
                    json, directory: FileManager.default.temporaryDirectory,
                    manifestURL: FileManager.default.temporaryDirectory.appendingPathComponent("manifest.json")
                  )
            else { throw ChromeExtensionAPIError("Manifest file is invalid") }
            return installWarnings(for: manifest)
        case "setEnabled":
            let object = args.first as? [String: Any] ?? [:]
            let id = object["id"] as? String ?? string(args, 0) ?? ""
            let enabled = object["enabled"] as? Bool ?? (args.count > 1 ? args[1] as? Bool : nil) ?? true
            try store.setEnabled(enabled, id: id)
            return [:]
        case "uninstall":
            let id = (args.first as? String) ?? (args.first as? [String: Any])?["id"] as? String ?? ""
            let name = try installed(id).name
            // Removing another extension is always the user's decision, as in Chrome.
            guard confirmUninstall(name: name) else { throw ChromeExtensionAPIError("User cancelled uninstall.") }
            try store.remove(id: id)
            return [:]
        case "uninstallSelf":
            let options = args.first as? [String: Any] ?? [:]
            let name = try installed(extensionID).name
            if options["showConfirmDialog"] as? Bool == true, !confirmUninstall(name: name) {
                throw ChromeExtensionAPIError("User cancelled uninstall.")
            }
            try store.remove(id: extensionID)
            return [:]
        default:
            throw ChromeExtensionAPIError("Unknown management.\(method)")
        }
    }

    private static func installWarnings(for manifest: ChromeExtensionManifest) -> [String] {
        ExtensionPermissionWarnings.warnings(for: manifest).filter(\.isGrantedAtInstall).map(\.text)
    }

    /// main's OrbitChromiumManagementBridge.requestUninstallConsent: the probe's non-interactive run
    /// approves, an unattended test run has nobody to ask, everyone else gets the alert.
    private static func confirmUninstall(name: String) -> Bool {
        if ProcessInfo.processInfo.environment["ORBIT_WEBSTORE_PROBE"] == "1" { return true }
        guard !DebugFlags.isRunningUnderTests else { return false }
        let alert = NSAlert()
        alert.messageText = "Remove \(name)?"
        alert.informativeText = "This extension will be removed from Orbit."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// chrome.management.ExtensionInfo, read from the extension's own manifest on disk.
    static func extensionInfo(_ ext: LoadedExtension) -> [String: Any] {
        let manifestURL = ext.directory.appendingPathComponent("manifest.json")
        let json = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let manifest = try? ChromeExtensionManifest.read(fromDirectory: ext.directory)
        let origin = "chrome-extension://\(ext.id)/"
        var info: [String: Any] = [
            "id": ext.id,
            "name": ext.name,
            "shortName": json["short_name"] as? String ?? ext.name,
            "description": manifest?.description ?? "",
            "version": ext.version,
            "enabled": ext.isEnabled,
            "mayDisable": true,
            "mayEnable": true,
            "isApp": false,
            "type": "extension",
            "offlineEnabled": json["offline_enabled"] as? Bool ?? false,
            "optionsUrl": manifest?.optionsPagePath.map { origin + $0 } ?? "",
            // Store installs carry the CRX's public key in their manifest; anything else was loaded unpacked.
            "installType": manifest?.key == nil ? "development" : "normal",
        ]
        if !ext.isEnabled { info["disabledReason"] = "unknown" }
        if let versionName = json["version_name"] as? String { info["versionName"] = versionName }
        if let homepage = json["homepage_url"] as? String {
            info["homepageUrl"] = homepage
        } else if let update = json["update_url"] as? String, update.contains("google.com") {
            info["homepageUrl"] = "https://chromewebstore.google.com/detail/\(ext.id)"
        }
        if let update = json["update_url"] as? String { info["updateUrl"] = update }
        let granted = (AppEnvironment.processRoot.engine as? WebKitEngine)?.services.grantedPermissions(ext.id)
        let permissions = granted.map { Array($0) } ?? manifest?.permissions ?? []
        info["permissions"] = permissions.filter { !$0.contains("://") && $0 != "<all_urls>" }.sorted()
        info["hostPermissions"] = Array(Set((manifest?.hostPermissions ?? []) + (manifest?.contentScriptMatches ?? []))).sorted()
        if let icons = json["icons"] as? [String: Any] {
            info["icons"] = icons.compactMap { size, path -> [String: Any]? in
                guard let size = Int(size), let path = path as? String else { return nil }
                let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
                return ["size": size, "url": origin + relative]
            }.sorted { ($0["size"] as? Int ?? 0) < ($1["size"] as? Int ?? 0) }
        }
        return info
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

    private static func downloadAction(
        _ method: String, _ args: [Any], permissions: Set<String>, store: DownloadStore
    ) -> String? {
        switch method {
        case "showDefaultFolder":
            let directory = (try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            _ = NSWorkspace.shared.open(directory)
            return nil
        case "open":
            guard permissions.contains("downloads.open") else {
                return "The \"downloads.open\" permission is required"
            }
            guard let item = downloadItem(apiID: firstInteger(args), store: store) else { return "Invalid downloadId" }
            guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return "Download file already deleted" }
            _ = NSWorkspace.shared.open(item.destinationURL)
            return nil
        case "show":
            guard let item = downloadItem(apiID: firstInteger(args), store: store) else { return "Invalid downloadId" }
            store.revealInFinder(item.id)
            return nil
        case "removeFile":
            guard let item = downloadItem(apiID: firstInteger(args), store: store) else { return "Invalid downloadId" }
            guard item.state == .completed else { return "Download must be complete" }
            guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return "Download file already deleted" }
            guard store.removeFile(item.id) else { return "Unable to remove file" }
            return nil
        default:
            return "Invalid downloadId"
        }
    }

    private static func transferAction(_ method: String, _ args: [Any], store: DownloadStore) async -> String? {
        guard let item = downloadItem(apiID: firstInteger(args), store: store) else { return "Invalid downloadId" }
        let downloads = WebKitDownloads.shared
        switch method {
        case "pause":
            // A store record the engine is not tracking is not a live transfer; pausing it would pretend the engine can stop it.
            guard downloads.isTracking(item.id) else { return WebKitDownloads.mustBeInProgress }
            return await downloads.pause(id: item.id)
        case "resume":
            guard downloads.isTracking(item.id) else { return WebKitDownloads.cannotResume }
            return await downloads.resume(id: item.id)
        default:
            if downloads.isTracking(item.id) {
                downloads.cancel(id: item.id)
            } else if item.state == .inProgress || item.state == .pending || item.state == .paused {
                store.cancel(item.id)
            }
            return nil
        }
    }

    private static let forbiddenDownloadHeaders: Set<String> = [
        "accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
        "connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive",
        "origin", "referer", "te", "trailer", "transfer-encoding", "upgrade", "user-agent", "via",
    ]

    private static func startDownload(_ options: [String: Any], store: DownloadStore, session callerSession: WebKitSession?) async throws -> Int {
        guard let urlString = options["url"] as? String, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), ["http", "https", "data"].contains(scheme)
        else { throw ChromeExtensionAPIError("Invalid URL") }
        var request = URLRequest(url: url)
        if let method = options["method"] as? String {
            guard ["GET", "POST"].contains(method.uppercased()) else { throw ChromeExtensionAPIError("Invalid method") }
            request.httpMethod = method.uppercased()
        }
        for header in options["headers"] as? [[String: Any]] ?? [] {
            guard let name = header["name"] as? String, let value = header["value"] as? String else {
                throw ChromeExtensionAPIError("Invalid header")
            }
            let lowered = name.lowercased()
            guard !forbiddenDownloadHeaders.contains(lowered), !lowered.hasPrefix("proxy-"), !lowered.hasPrefix("sec-") else {
                throw ChromeExtensionAPIError("Invalid header name: \(name)")
            }
            request.addValue(value, forHTTPHeaderField: name)
        }
        if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }

        var transfer = WebKitDownloads.ExtensionOptions()
        transfer.filename = options["filename"] as? String
        transfer.saveAs = options["saveAs"] as? Bool ?? false
        if let raw = options["conflictAction"] as? String {
            guard let action = WebKitDownloads.ConflictAction(rawValue: raw) else {
                throw ChromeExtensionAPIError("Invalid conflictAction")
            }
            transfer.conflictAction = action
        }
        // The download belongs to the profile the extension runs in, not whichever one is default.
        guard let session = callerSession
            ?? (AppEnvironment.processRoot.engine as? WebKitEngine)?.defaultSession as? WebKitSession
        else {
            throw ChromeExtensionAPIError("Orbit's WebKit engine is not running.")
        }
        let id: UUID
        do {
            id = try await WebKitDownloads.shared.startExtensionDownload(request, session: session, options: transfer)
        } catch {
            throw ChromeExtensionAPIError(error.localizedDescription)
        }
        guard let apiID = store.downloads.first(where: { $0.id == id })?.apiID else {
            throw ChromeExtensionAPIError("Download failed")
        }
        return apiID
    }

    private static func eraseDownloads(_ args: [Any], store: DownloadStore) throws -> [Int] {
        let ids = integerList(args)
        guard !ids.isEmpty else { throw ChromeExtensionAPIError("Invalid downloadId") }
        var erased: [Int] = []
        for id in ids {
            guard let item = downloadItem(apiID: id, store: store) else { continue }
            store.remove(item.id)
            erased.append(id)
        }
        return erased
    }

    private static func searchDownloads(_ query: [String: Any], store: DownloadStore) throws -> [[String: Any]] {
        if let limit = integer(query["limit"]), limit < 0 {
            throw ChromeExtensionAPIError("Invalid query limit")
        }
        let orderFields = query["orderBy"] as? [String] ?? []
        for field in orderFields {
            let name = field.hasPrefix("-") ? String(field.dropFirst()) : field
            guard name == "startTime" || name == "filename" || name == "url" else {
                throw ChromeExtensionAPIError("Invalid orderBy field")
            }
        }
        if let state = query["state"] as? String,
           state != "complete", state != "in_progress", state != "interrupted" {
            throw ChromeExtensionAPIError("Invalid state")
        }
        var matched = store.downloads.filter { $0.apiID != nil }
        if let state = query["state"] as? String {
            matched = matched.filter { DownloadItemProjection.chromeState(for: $0.state) == state }
        }
        if let id = integer(query["id"]) {
            matched = matched.filter { $0.apiID == id }
        }
        if let terms = query["query"] as? [String] {
            for term in terms {
                let excluded = term.hasPrefix("-")
                let text = excluded ? String(term.dropFirst()) : term
                matched = matched.filter { item in
                    let haystack = (item.destinationURL.path + " " + item.sourceURL.absoluteString).lowercased()
                    let hit = haystack.contains(text.lowercased())
                    return excluded ? !hit : hit
                }
            }
        }
        if let pattern = query["filenameRegex"] as? String {
            let expression = try NSRegularExpression(pattern: pattern)
            matched = matched.filter { item in
                let name = item.destinationURL.path as NSString
                return expression.firstMatch(in: item.destinationURL.path, range: NSRange(location: 0, length: name.length)) != nil
            }
        }
        if let minimum = integer(query["totalBytesGreater"]) {
            matched = matched.filter { $0.totalBytes > Int64(minimum) }
        }
        if let raw = query["startedAfter"] as? String, let start = isoDate(raw) {
            matched = matched.filter { $0.startedAt > start }
        }
        for field in orderFields.reversed() {
            let descending = field.hasPrefix("-")
            let name = descending ? String(field.dropFirst()) : field
            matched.sort { left, right in
                let ordered: Bool
                switch name {
                case "filename":
                    ordered = left.destinationURL.path < right.destinationURL.path
                case "url":
                    ordered = left.sourceURL.absoluteString < right.sourceURL.absoluteString
                default:
                    if left.startedAt != right.startedAt { ordered = left.startedAt < right.startedAt }
                    else { ordered = (left.apiID ?? 0) < (right.apiID ?? 0) }
                }
                return descending ? !ordered : ordered
            }
        }
        if let limit = integer(query["limit"]), limit > 0 {
            matched = Array(matched.prefix(limit))
        }
        return matched.map(extensionDownloadObject)
    }

    static func extensionDownloadObject(_ download: DownloadItem) -> [String: Any] {
        var item = DownloadItemProjection.item(for: download)
        item["startTime"] = isoString(download.startedAt)
        if let finished = download.finishedAt {
            item["endTime"] = isoString(finished)
        } else {
            item.removeValue(forKey: "endTime")
        }
        return item
    }

    private static func firstInteger(_ args: [Any]) -> Int? {
        integerList(args).first
    }

    private static func integerList(_ args: [Any]) -> [Int] {
        if let object = args.first as? [String: Any] {
            if let id = integer(object["id"]) { return [id] }
            if let ids = object["ids"] as? [Any] { return ids.compactMap { integer($0) } }
        }
        if let id = integer(args.first) { return [id] }
        return []
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return nil
    }

    private static func downloadItem(apiID: Int?, store: DownloadStore) -> DownloadItem? {
        guard let apiID else { return nil }
        return store.downloads.first { $0.apiID == apiID }
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func isoDate(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text)
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

    private static func openSearch(_ text: String, disposition: String, tabID: Int?) throws {
        let environment = AppEnvironment.frontmost
        guard let spaceID = environment.activeSpace?.id else {
            throw ChromeExtensionAPIError("No active browser window.")
        }
        guard let url = environment.searchEngine(forSpace: spaceID).searchURL(for: text) else {
            throw ChromeExtensionAPIError("No search provider is configured.")
        }
        if let tabID {
            guard let engine = environment.engine as? WebKitEngine,
                  let uuid = engine.storeTabID(forNumericID: Int32(tabID)),
                  environment.state.tabs[uuid] != nil
            else { throw ChromeExtensionAPIError("No tab with id: \(tabID).") }
            environment.loadInTab(uuid, url: url)
            return
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
                    "active": false,
                    "highlighted": false,
                    "pinned": record.pinnedURL != nil,
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
        var restoredTab: [String: Any] = [
            "id": -1,
            "url": tab.url.absoluteString,
            "title": tab.displayTitle,
            "active": true,
        ]
        // The wrapper swaps this for the tabs.Tab WebKit reports, so the id is the extension's own.
        if let reference = (environment.engine as? WebKitEngine)?.extensionTabReference(forTabID: tab.id) {
            restoredTab["__orbitTab"] = reference
        }
        return [
            "sessionId": record.tabID.uuidString,
            "lastModified": Int(Date().timeIntervalSince1970),
            "tab": restoredTab,
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

    /// Chrome passes move/update/remove as (id, details), not one object.
    private static func bookmarkMutationArguments(_ method: String, _ args: [Any]) -> [String: Any] {
        switch method {
        case "create":
            return args.first as? [String: Any] ?? [:]
        case "move", "update":
            var object = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
            if object["id"] == nil, let id = args.first as? String {
                object["id"] = id
            } else if object.isEmpty, let only = args.first as? [String: Any] {
                object = only
            }
            return object
        case "remove", "removeTree":
            if let id = args.first as? String { return ["id": id] }
            return args.first as? [String: Any] ?? [:]
        default:
            return args.first as? [String: Any] ?? [:]
        }
    }

    private static func postBookmarkMutation(
        _ method: String, id: String, before: [String: Any]?, after: [String: Any]
    ) {
        switch method {
        case "create":
            NotificationCenter.default.post(
                name: .orbitBookmarkCreated, object: nil, userInfo: ["id": id, "node": after]
            )
        case "move":
            let info: [String: Any] = [
                "parentId": after["parentId"] ?? "",
                "index": after["index"] ?? 0,
                "oldParentId": before?["parentId"] ?? "",
                "oldIndex": before?["index"] ?? 0,
            ]
            NotificationCenter.default.post(
                name: .orbitBookmarkMoved, object: nil, userInfo: ["id": id, "info": info]
            )
        case "update":
            var info: [String: Any] = [:]
            if let title = after["title"] { info["title"] = title }
            if let url = after["url"] { info["url"] = url }
            NotificationCenter.default.post(
                name: .orbitBookmarkChanged, object: nil, userInfo: ["id": id, "info": info]
            )
        case "remove", "removeTree":
            // Chrome's removeInfo.node is the removed tree with parentId omitted;
            // parentId and index live on removeInfo itself.
            var node = before ?? ["id": id]
            node.removeValue(forKey: "parentId")
            let info: [String: Any] = [
                "parentId": before?["parentId"] ?? "",
                "index": before?["index"] ?? 0,
                "node": node,
            ]
            NotificationCenter.default.post(
                name: .orbitBookmarkRemoved, object: nil, userInfo: ["id": id, "info": info]
            )
        default:
            break
        }
    }

    private static func searchBookmarkQuery(_ query: [String: Any], in node: [String: Any]) -> [[String: Any]] {
        let text = query["query"] as? String
        let url = query["url"] as? String
        let title = query["title"] as? String
        guard text != nil || url != nil || title != nil else { return [] }
        var matches: [[String: Any]] = []
        func walk(_ node: [String: Any]) {
            let nodeTitle = (node["title"] as? String) ?? ""
            let nodeURL = node["url"] as? String
            var matchesQuery = true
            if let text, !text.isEmpty {
                let inTitle = nodeTitle.localizedCaseInsensitiveContains(text)
                let inURL = nodeURL?.localizedCaseInsensitiveContains(text) ?? false
                matchesQuery = inTitle || inURL
            }
            if let url { matchesQuery = matchesQuery && nodeURL == url }
            if let title { matchesQuery = matchesQuery && nodeTitle.localizedCaseInsensitiveContains(title) }
            if matchesQuery { matches.append(node) }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(node)
        return matches
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

    // MARK: - privacy

    /// chrome.privacy.services.searchSuggestEnabled. Only this setting exists:
    /// the rest of chrome.privacy names features Orbit does not honour.
    private static func privacy(_ method: String, _ args: [Any]) throws -> Any {
        let name = args.first as? String ?? ""
        guard name == "searchSuggestEnabled" else {
            throw ChromeExtensionAPIError("Unknown privacy setting.")
        }
        let details = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
        switch method {
        case "get":
            return SearchSuggestChromeSetting.get()
        case "set":
            let value = details["value"] as? Bool ?? true
            return SearchSuggestChromeSetting.set(value)
        case "clear":
            return SearchSuggestChromeSetting.clear()
        default:
            throw ChromeExtensionAPIError("Unknown privacy.\(method)")
        }
    }

    // MARK: - commands

    private static func commands(_ method: String, extensionID: String) -> Any {
        switch method {
        case "getAll":
            return ExtensionCommandRegistry.shared.commands(forExtension: extensionID).map { command in
                [
                    "name": command.name,
                    "description": command.commandDescription,
                    "shortcut": command.shortcut,
                ]
            }
        default:
            return []
        }
    }

    // MARK: - action
    //
    // WKWebExtension.Action stores badge text, label, enabled, and an icon, and
    // nothing else. Badge colour and the popup path live here. The toolbar reads
    // the popup path through ExtensionActionPopupSupport. Colour and an explicit
    // setIcon are also written onto every WebKitEngine this process can see;
    // WebKitEngine.publishAction still replaces that snapshot from the Action
    // object, which cannot carry colour or a popup path.

    private struct ActionRecord {
        var badgeBackgroundColor: ExtensionActionColor?
        var badgeTextColor: ExtensionActionColor?
        var title: String?
        var badgeText: String?
        var badgeTextByTab: [Int32: String] = [:]
        var isEnabled: Bool?
        var popupPath: String = ""
        var hasPopupPath = false
        var iconPNG: Data?
        var iconWasSet = false
    }

    private static var actionRecords: [String: ActionRecord] = [:]
    private static var rememberedEngines = NSHashTable<WebKitEngine>.weakObjects()

    static func remember(engine: WebKitEngine) {
        rememberedEngines.add(engine)
    }

    /// nil when chrome.action.setPopup has not been called. "" means it cleared the popup.
    static func actionPopupOverride(for extensionID: String) -> String? {
        guard let record = actionRecords[extensionID], record.hasPopupPath else { return nil }
        return record.popupPath
    }

    static func storedBadgeBackgroundColor(for extensionID: String) -> ExtensionActionColor? {
        actionRecords[extensionID]?.badgeBackgroundColor
    }

    static func storedBadgeText(for extensionID: String) -> String? {
        actionRecords[extensionID]?.badgeText
    }

    static func storedBadgeText(for extensionID: String, tabID: Int32) -> String? {
        actionRecords[extensionID]?.badgeTextByTab[tabID]
    }

    static func storedActionTitle(for extensionID: String) -> String? {
        actionRecords[extensionID]?.title
    }

    static func storedActionIsEnabled(for extensionID: String) -> Bool? {
        actionRecords[extensionID]?.isEnabled
    }

    static func storedIconWasSet(for extensionID: String) -> Bool {
        actionRecords[extensionID]?.iconWasSet == true
    }

    static func storedIconPNG(for extensionID: String) -> Data? {
        actionRecords[extensionID]?.iconPNG
    }

    private static func action(_ method: String, _ args: [Any], extensionID: String) throws -> Any {
        let details = args.first as? [String: Any] ?? [:]
        switch method {
        case "setBadgeBackgroundColor":
            let color = actionColor(from: details["color"]) ?? .unset
            updateAction(extensionID: extensionID) { $0.badgeBackgroundColor = color }
            return [:]
        case "getBadgeBackgroundColor":
            let color = actionRecords[extensionID]?.badgeBackgroundColor ?? .unset
            return [Int(color.red), Int(color.green), Int(color.blue), Int(color.alpha)]
        case "setBadgeTextColor":
            let color = actionColor(from: details["color"]) ?? .unset
            updateAction(extensionID: extensionID) { $0.badgeTextColor = color }
            return [:]
        case "getBadgeTextColor":
            let color = actionRecords[extensionID]?.badgeTextColor ?? .unset
            return [Int(color.red), Int(color.green), Int(color.blue), Int(color.alpha)]
        case "setPopup":
            let path = relativeActionPopupPath(details["popup"] as? String ?? "", extensionID: extensionID)
            updateAction(extensionID: extensionID) {
                $0.popupPath = path
                $0.hasPopupPath = true
            }
            return [:]
        case "getPopup":
            let path = actionRecords[extensionID]?.popupPath ?? ""
            guard !path.isEmpty else { return "" }
            return "chrome-extension://\(extensionID)/\(path)"
        case "setTitle":
            updateAction(extensionID: extensionID) { $0.title = details["title"] as? String ?? "" }
            return [:]
        case "getTitle":
            return actionRecords[extensionID]?.title ?? ""
        case "setBadgeText":
            let text = details["text"] as? String ?? ""
            if let tabID = integer(details["tabId"]).map(Int32.init) {
                updateAction(extensionID: extensionID) { $0.badgeTextByTab[tabID] = text }
            } else {
                updateAction(extensionID: extensionID) { $0.badgeText = text }
            }
            return [:]
        case "getBadgeText":
            if let tabID = integer(details["tabId"]).map(Int32.init),
               let text = actionRecords[extensionID]?.badgeTextByTab[tabID] {
                return text
            }
            return actionRecords[extensionID]?.badgeText ?? ""
        case "enable":
            updateAction(extensionID: extensionID) { $0.isEnabled = true }
            return [:]
        case "disable":
            updateAction(extensionID: extensionID) { $0.isEnabled = false }
            return [:]
        case "isEnabled":
            return actionRecords[extensionID]?.isEnabled ?? true
        case "setIcon":
            let png = actionIconPNG(details, extensionID: extensionID)
            updateAction(extensionID: extensionID) {
                $0.iconPNG = png
                $0.iconWasSet = true
            }
            return [:]
        default:
            throw ChromeExtensionAPIError("Unknown action.\(method)")
        }
    }

    private static func updateAction(extensionID: String, _ change: (inout ActionRecord) -> Void) {
        var record = actionRecords[extensionID] ?? ActionRecord()
        change(&record)
        actionRecords[extensionID] = record
        publishActionRecord(record, extensionID: extensionID)
    }

    private static func publishActionRecord(_ record: ActionRecord, extensionID: String) {
        for engine in visibleEngines() {
            let existing = engine.extensionActionStates.snapshots[extensionID]
            var defaults = existing?.defaults ?? ExtensionActionState()
            var perTab = existing?.perTab ?? [:]
            if let color = record.badgeBackgroundColor { defaults.badgeBackgroundColor = color }
            if let color = record.badgeTextColor { defaults.badgeTextColor = color }
            if let title = record.title { defaults.title = title }
            if let text = record.badgeText { defaults.badgeText = text }
            for (tabID, text) in record.badgeTextByTab {
                var tabState = perTab[tabID] ?? defaults
                tabState.badgeText = text
                perTab[tabID] = tabState
            }
            if let enabled = record.isEnabled { defaults.isEnabled = enabled }
            if record.hasPopupPath {
                defaults.popupURLString = record.popupPath.isEmpty
                    ? ""
                    : "chrome-extension://\(extensionID)/\(record.popupPath)"
            }
            // iconPNG is only the bitmap from chrome.action.setIcon. Nil leaves
            // the toolbar on the manifest icon.
            if record.iconWasSet { defaults.iconPNG = record.iconPNG }
            let snapshot = ExtensionActionSnapshot(extensionID: extensionID, defaults: defaults, perTab: perTab)
            guard snapshot != existing else { continue }
            engine.extensionActionStates.apply(snapshot)
        }
    }

    private static func visibleEngines() -> [WebKitEngine] {
        var list = rememberedEngines.allObjects
        let environments = [AppEnvironment.processRoot, AppEnvironment.frontmost]
        for environment in environments {
            guard let engine = environment.engine as? WebKitEngine else { continue }
            if !list.contains(where: { $0 === engine }) { list.append(engine) }
        }
        return list
    }

    private static func relativeActionPopupPath(_ popup: String, extensionID: String) -> String {
        let trimmed = popup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "chrome-extension",
           url.host == nil || url.host == extensionID {
            return String(url.path.drop(while: { $0 == "/" }))
        }
        let relative = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return relative
    }

    private static func actionIconPNG(_ details: [String: Any], extensionID: String) -> Data? {
        if let path = details["path"] as? String {
            return actionIconFile(path, extensionID: extensionID)
        }
        if let paths = details["path"] as? [String: Any] {
            let preferred = paths["32"] ?? paths["48"] ?? paths["128"] ?? paths.values.first
            if let path = preferred as? String { return actionIconFile(path, extensionID: extensionID) }
        }
        if let image = details["imageData"] as? [String: Any] {
            return png(fromImageData: image)
        }
        return nil
    }

    private static func actionIconFile(_ path: String, extensionID: String) -> Data? {
        let relative = relativeActionPopupPath(path, extensionID: extensionID)
        guard !relative.isEmpty, !relative.contains("..") else { return nil }
        for engine in visibleEngines() {
            guard let directory = engine.loadedExtensions(session: engine.defaultSession)
                .first(where: { $0.id == extensionID })?.directory
            else { continue }
            let file = directory.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        }
        return nil
    }

    private static func png(fromImageData image: [String: Any]) -> Data? {
        guard let width = (image["width"] as? NSNumber)?.intValue, width > 0,
              let height = (image["height"] as? NSNumber)?.intValue, height > 0
        else { return nil }
        let bytes = (image["data"] as? [Any])?.compactMap { ($0 as? NSNumber)?.uint8Value } ?? []
        guard bytes.count >= width * height * 4 else { return nil }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32
        )
        guard let rep, let plane = rep.bitmapData else { return nil }
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            plane.update(from: base, count: width * height * 4)
        }
        return rep.representation(using: .png, properties: [:])
    }

    private static func actionColor(from value: Any?) -> ExtensionActionColor? {
        if let text = value as? String { return actionColor(hex: text) }
        let numbers: [Int]
        if let ints = value as? [Int] {
            numbers = ints
        } else if let list = value as? [Any] {
            numbers = list.compactMap { ($0 as? NSNumber)?.intValue ?? ($0 as? Int) }
        } else {
            return nil
        }
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count >= 4 ? numbers[3] : 255
        return ExtensionActionColor(
            red: UInt8(clamping: numbers[0]),
            green: UInt8(clamping: numbers[1]),
            blue: UInt8(clamping: numbers[2]),
            alpha: UInt8(clamping: alpha)
        )
    }

    private static func actionColor(hex: String) -> ExtensionActionColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 6 { text += "FF" }
        return ExtensionActionColor(hexRGBA: text)
    }

    // MARK: - bookmark relay
    //
    // Sidebar pin, rename, move, and delete write BrowserStore and never call
    // bookmarks.*. The chrome.bookmarks events for those mutations are posted
    // from here. API mutations post their own notification and suppress the
    // relay so removeTree stays a single onRemoved.
    //
    // The snapshot is one flat record per id. Nested `children` arrays made
    // every subtree live once per ancestor. onRemoved and onCreated rebuild
    // that tree for the event only.

    private static var bookmarkRelayStore: BrowserStore?
    private static var bookmarkSnapshot: [String: [String: Any]] = [:]
    private static var bookmarkSnapshotGeneration = 0
    private static var bookmarkRelayToken = 0
    private static var bookmarkRelayArmed = false
    private static var bookmarkRelaySuppressCount = 0

    static func ensureBookmarkRelay() {
        let store = AppEnvironment.processRoot.store
        if bookmarkRelayStore !== store {
            bookmarkRelayToken += 1
            bookmarkRelayStore = store
            installBookmarkSnapshot(bookmarkIndex(BookmarkTreeProjection.treeObject(for: store.state)))
            armBookmarkRelay(on: store)
            return
        }
        if !bookmarkRelayArmed { armBookmarkRelay(on: store) }
    }

    private static func refreshBookmarkSnapshot() {
        guard let store = bookmarkRelayStore else { return }
        installBookmarkSnapshot(bookmarkIndex(BookmarkTreeProjection.treeObject(for: store.state)))
    }

    private static func installBookmarkSnapshot(_ next: [String: [String: Any]]) {
        bookmarkSnapshot = next
        bookmarkSnapshotGeneration &+= 1
    }

    private static func armBookmarkRelay(on store: BrowserStore) {
        bookmarkRelayArmed = true
        let token = bookmarkRelayToken
        withObservationTracking {
            _ = store.state
        } onChange: {
            let generation = MainActor.assumeIsolated { bookmarkSnapshotGeneration }
            Task { @MainActor in
                guard token == bookmarkRelayToken else { return }
                bookmarkRelayArmed = false
                relayBookmarkChange(from: store, observedGeneration: generation)
                if AppEnvironment.processRoot.store === store {
                    armBookmarkRelay(on: store)
                }
            }
        }
    }

    private static func relayBookmarkChange(from store: BrowserStore, observedGeneration: Int) {
        guard AppEnvironment.processRoot.store === store, bookmarkRelayStore === store else { return }
        if bookmarkRelaySuppressCount > 0 { return }
        // bookmarks.* already installed the post-mutation snapshot and posted
        // the notification. Diffing that same tree would only allocate it again.
        guard observedGeneration == bookmarkSnapshotGeneration else { return }
        let next = bookmarkIndex(BookmarkTreeProjection.treeObject(for: store.state))
        let previous = bookmarkSnapshot
        guard !bookmarkIndexEqual(previous, next) else { return }
        installBookmarkSnapshot(next)
        emitBookmarkDiff(from: previous, to: next)
    }

    private static func bookmarkIndex(_ root: [String: Any]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        func walk(_ node: [String: Any]) {
            guard let id = node["id"] as? String else { return }
            var stored = node
            stored.removeValue(forKey: "children")
            result[id] = stored
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(root)
        return result
    }

    private static func bookmarkIndexEqual(
        _ lhs: [String: [String: Any]], _ rhs: [String: [String: Any]]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (id, node) in lhs {
            guard let other = rhs[id], bookmarkFieldsEqual(node, other) else { return false }
        }
        return true
    }

    private static func bookmarkFieldsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, value) in lhs {
            guard let other = rhs[key], bookmarkValuesEqual(value, other) else { return false }
        }
        return true
    }

    private static func bookmarkValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (left as String, right as String): return left == right
        case let (left as Bool, right as Bool): return left == right
        case let (left as Int, right as Int): return left == right
        case let (left as Double, right as Double): return left == right
        default: return false
        }
    }

    private static func childrenByParent(_ index: [String: [String: Any]]) -> [String: [String]] {
        var grouped: [String: [(Int, String)]] = [:]
        for (id, node) in index {
            guard let parent = node["parentId"] as? String else { continue }
            let position: Int
            if let value = node["index"] as? Int {
                position = value
            } else if let value = node["index"] as? NSNumber {
                position = value.intValue
            } else {
                position = 0
            }
            grouped[parent, default: []].append((position, id))
        }
        return grouped.mapValues { pairs in
            pairs.sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }.map(\.1)
        }
    }

    /// Folders have no url. Leaves keep the flat record, so a bookmark does not
    /// grow a children array it never had.
    private static func bookmarkTreeNode(
        _ id: String, in index: [String: [String: Any]], children: [String: [String]]
    ) -> [String: Any] {
        var node = index[id] ?? ["id": id]
        guard node["url"] == nil else { return node }
        node["children"] = (children[id] ?? []).map { bookmarkTreeNode($0, in: index, children: children) }
        return node
    }

    private static func emitBookmarkDiff(from old: [String: [String: Any]], to new: [String: [String: Any]]) {
        let removed = Set(old.keys).subtracting(new.keys)
        let created = Set(new.keys).subtracting(old.keys)
        let topRemoved = removed.filter { id in
            guard let parent = old[id]?["parentId"] as? String else { return true }
            return !removed.contains(parent)
        }
        let oldChildren = topRemoved.contains(where: { old[$0]?["url"] == nil })
            ? childrenByParent(old) : [:]
        let newChildren = created.contains(where: { new[$0]?["url"] == nil })
            ? childrenByParent(new) : [:]
        for id in topRemoved.sorted() {
            postBookmarkMutation(
                "remove", id: id,
                before: bookmarkTreeNode(id, in: old, children: oldChildren),
                after: ["id": id]
            )
        }
        for id in created.sorted() {
            postBookmarkMutation(
                "create", id: id, before: nil,
                after: bookmarkTreeNode(id, in: new, children: newChildren)
            )
        }
        for id in Set(old.keys).intersection(new.keys).sorted() {
            guard let before = old[id], let after = new[id] else { continue }
            if (before["parentId"] as? String) != (after["parentId"] as? String) {
                postBookmarkMutation("move", id: id, before: before, after: after)
            }
            let titleChanged = (before["title"] as? String) != (after["title"] as? String)
            let urlChanged = (before["url"] as? String) != (after["url"] as? String)
            if titleChanged || urlChanged {
                postBookmarkMutation("update", id: id, before: before, after: after)
            }
        }
    }
}

/// Extension override of Profile.includesSearchSuggestions. clear() restores the
/// value the profile had before the first set, which is Chrome's ChromeSetting contract.
@MainActor
private enum SearchSuggestChromeSetting {
    private static var override: Bool?
    private static var baseline: Bool?

    static func get() -> [String: Any] {
        if let override {
            return ["value": override, "levelOfControl": "controlled_by_this_extension"]
        }
        return [
            "value": AppEnvironment.processRoot.includesSearchSuggestions,
            "levelOfControl": "controllable_by_this_extension",
        ]
    }

    static func set(_ value: Bool) -> [String: Any] {
        if override == nil {
            baseline = AppEnvironment.processRoot.includesSearchSuggestions
        }
        override = value
        AppEnvironment.processRoot.applyEngineSearchSuggestPreference(value)
        return get()
    }

    static func clear() -> [String: Any] {
        override = nil
        if let baseline {
            AppEnvironment.processRoot.applyEngineSearchSuggestPreference(baseline)
            self.baseline = nil
        }
        return get()
    }
}

extension Notification.Name {
    static let orbitBookmarkCreated = Notification.Name("orbit.bookmark.created")
    static let orbitBookmarkRemoved = Notification.Name("orbit.bookmark.removed")
    static let orbitBookmarkChanged = Notification.Name("orbit.bookmark.changed")
    static let orbitBookmarkMoved = Notification.Name("orbit.bookmark.moved")
}

struct ChromeExtensionAPIError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
