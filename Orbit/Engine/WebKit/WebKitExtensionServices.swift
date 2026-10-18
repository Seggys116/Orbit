import AppKit
import Foundation
import OSLog
import WebKit

private let extensionServicesLogger = Logger(subsystem: "com.orbit.browser", category: "WebKitExtensionServices")

/// One loaded extension as Orbit's own APIs see it.
@MainActor
final class WebKitExtensionEntry {
    let id: String
    let context: WKWebExtensionContext
    let directory: URL
    let manifest: ChromeExtensionManifest
    let session: WebKitSession
    /// Names from this manifest WebKit itself implements; every other declared name is Orbit's to honour.
    let webKitPermissions: Set<String>
    /// Built once. The manifest stored on the entry does not change, and permission checks run per event.
    let declaredPermissions: Set<String>
    let optionalPermissions: Set<String>

    init(id: String, context: WKWebExtensionContext, directory: URL, manifest: ChromeExtensionManifest, session: WebKitSession, webKitPermissions: Set<String>) {
        self.id = id
        self.context = context
        self.directory = directory
        self.manifest = manifest
        self.session = session
        self.webKitPermissions = webKitPermissions
        self.declaredPermissions = Set(manifest.permissions)
        self.optionalPermissions = Set(manifest.optionalPermissions)
    }

    var declaresNativeMessaging: Bool { declaredPermissions.contains("nativeMessaging") }
}

/// The Chrome behaviour Orbit owns on top of WKWebExtensionController: optional permissions,
/// install/startup lifecycle, event delivery to extension contexts, blocking onAuthRequired,
/// webNavigation for the main frame, and the remembered declarativeNetRequest regexes.
@MainActor
final class WebKitExtensionServices {
    weak var engine: WebKitEngine?
    let state: WebKitExtensionStateStore
    let nativeMessaging = WebKitNativeMessaging()
    private(set) lazy var system = WebKitExtensionSystemAPIs(services: self)
    private(set) var entries: [String: WebKitExtensionEntry] = [:]
    private var loadOrder: [String] = []
    private var pendingLifecycle: [String: [[String: Any]]] = [:]
    private var observers: [NSObjectProtocol] = []
    private var managementObserver: (store: ExtensionStore, token: UUID)?

    static let orbitPermissions = ChromeAPISurfaceInventory.wrappedPermissions

    private static let webKitPermissionNames = ChromeAPISurfaceInventory.webKitNativePermissions

    init(stateDirectory: URL?) {
        state = WebKitExtensionStateStore(directory: stateDirectory)
    }

    func entry(_ extensionID: String) -> WebKitExtensionEntry? { entries[extensionID] }

    func entry(for context: WKWebExtensionContext) -> WebKitExtensionEntry? {
        entries[context.uniqueIdentifier] ?? entries.values.first { $0.context === context }
    }

    // MARK: - Load and unload

    func wrapperConfiguration(forExtensionID id: String, manifest: ChromeExtensionManifest) -> ChromeAPIWrapperScript.Configuration {
        let optional = Set(manifest.optionalPermissions)
        var configuration = ChromeAPIWrapperScript.Configuration()
        configuration.grantedOptionalPermissions = state.state(for: id).grantedOptionalPermissions.filter { optional.contains($0) }
        configuration.maxSessionResults = AppEnvironment.processRoot.store.recentlyClosedCapacity
        return configuration
    }

    func register(
        id: String,
        context: WKWebExtensionContext,
        webExtension: WKWebExtension,
        directory: URL,
        manifest: ChromeExtensionManifest,
        session: WebKitSession,
        reason: ExtensionLoadReason
    ) {
        let webKitPermissions = Set(webExtension.requestedPermissions.map(\.rawValue))
            .union(webExtension.optionalPermissions.map(\.rawValue))
        let entry = WebKitExtensionEntry(
            id: id, context: context, directory: directory, manifest: manifest,
            session: session, webKitPermissions: webKitPermissions
        )
        entries[id] = entry
        loadOrder.removeAll { $0 == id }
        loadOrder.append(id)
        WebKitExtensionTransport.open(on: context)
        restoreOptionalGrants(entry)
        pendingLifecycle[id] = lifecycleEvents(for: entry, reason: reason)
        system.extensionLoaded(entry)
    }

    func unregister(_ extensionID: String, uninstalled: Bool) {
        entries[extensionID] = nil
        loadOrder.removeAll { $0 == extensionID }
        pendingLifecycle[extensionID] = nil
        queuedEvents[extensionID] = nil
        authListenerExtensions.remove(extensionID)
        sessionRegexFilters[extensionID] = nil
        for (key, record) in ports where record.extensionID == extensionID {
            ports[key] = nil
        }
        resumePendingAuth(forExtensionID: extensionID)
        nativeMessaging.closeAll(forExtensionID: extensionID)
        system.extensionUnloaded(extensionID)
        if uninstalled { state.remove(extensionID) }
    }

    private func restoreOptionalGrants(_ entry: WebKitExtensionEntry) {
        let remembered = state.state(for: entry.id)
        let optional = entry.optionalPermissions
        let keptNames = remembered.grantedOptionalPermissions.filter { optional.contains($0) }
        for name in keptNames where entry.webKitPermissions.contains(name) {
            entry.context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name))
        }
        let declaredHosts = declaredHostPatterns(entry)
        let keptOrigins = remembered.grantedOptionalOrigins.filter { origin in
            guard let pattern = try? WKWebExtension.MatchPattern(string: origin) else { return false }
            return declaredHosts.contains { $0.matches(pattern, options: [.ignorePaths]) }
        }
        for origin in keptOrigins {
            if let pattern = try? WKWebExtension.MatchPattern(string: origin) {
                entry.context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
        state.update(entry.id) {
            $0.grantedOptionalPermissions = keptNames
            $0.grantedOptionalOrigins = keptOrigins
        }
    }

    // MARK: - runtime.onInstalled / onStartup

    /// Chrome's rules, which WebKit's own (a five-second "fresh controller" window) does not follow:
    /// install once, update on a version change, startup only when the browser itself starts.
    private func lifecycleEvents(for entry: WebKitExtensionEntry, reason: ExtensionLoadReason) -> [[String: Any]] {
        let version = entry.manifest.version
        let previous = state.state(for: entry.id).lastSeenVersion
        var events: [[String: Any]] = []
        if reason == .browserStartup {
            events.append(["event": "onStartup", "args": [Any]()])
        }
        if let previous {
            if previous != version {
                events.append(["event": "onInstalled", "args": [["reason": "update", "previousVersion": previous]]])
            }
        } else if reason == .userAction {
            events.append(["event": "onInstalled", "args": [["reason": "install"]]])
        }
        state.update(entry.id) { $0.lastSeenVersion = version }
        return events
    }

    func takeLifecycleEvents(_ extensionID: String) -> [[String: Any]] {
        pendingLifecycle.removeValue(forKey: extensionID) ?? []
    }

    // MARK: - Permissions

    func hasPermission(_ name: String, extensionID: String) -> Bool {
        guard let entry = entries[extensionID] else { return false }
        if name == WKWebExtension.Permission.nativeMessaging.rawValue { return entry.declaresNativeMessaging }
        if entry.webKitPermissions.contains(name) {
            return entry.context.hasPermission(WKWebExtension.Permission(rawValue: name))
        }
        if entry.declaredPermissions.contains(name) { return true }
        return entry.optionalPermissions.contains(name)
            && state.state(for: extensionID).grantedOptionalPermissions.contains(name)
    }

    func grantedPermissions(_ extensionID: String) -> Set<String> {
        guard let entry = entries[extensionID] else { return [] }
        return entry.declaredPermissions.union(entry.optionalPermissions).filter { hasPermission($0, extensionID: extensionID) }
    }

    private func isRecognized(_ name: String, entry: WebKitExtensionEntry) -> Bool {
        Self.webKitPermissionNames.contains(name) || Self.orbitPermissions.contains(name)
            || entry.webKitPermissions.contains(name) || ExtensionPermissionWarnings.isKnownPermission(name)
    }

    private func declaredHostPatterns(_ entry: WebKitExtensionEntry) -> [WKWebExtension.MatchPattern] {
        let strings = entry.manifest.hostPermissions + entry.manifest.optionalHostPermissions + entry.manifest.contentScriptMatches
        return strings.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
    }

    private func requiredHostPatterns(_ entry: WebKitExtensionEntry) -> [WKWebExtension.MatchPattern] {
        (entry.manifest.hostPermissions + entry.manifest.contentScriptMatches).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
    }

    private func isGranted(_ pattern: WKWebExtension.MatchPattern, entry: WebKitExtensionEntry) -> Bool {
        let status = entry.context.permissionStatus(for: pattern)
        return status == .grantedExplicitly || status == .grantedImplicitly
    }

    private struct PermissionSet {
        var names: [String]
        var origins: [(string: String, pattern: WKWebExtension.MatchPattern)]
    }

    private func parsePermissionSet(_ details: Any?, entry: WebKitExtensionEntry, verb: String) throws -> PermissionSet {
        let object = details as? [String: Any] ?? [:]
        if let raw = object["permissions"], !(raw is [String]) {
            throw ChromeExtensionAPIError("Error at parameter 'permissions': Invalid type: expected array of strings.")
        }
        if let raw = object["origins"], !(raw is [String]) {
            throw ChromeExtensionAPIError("Error at parameter 'origins': Invalid type: expected array of strings.")
        }
        var names: [String] = []
        for name in object["permissions"] as? [String] ?? [] where !names.contains(name) {
            guard isRecognized(name, entry: entry) else {
                throw ChromeExtensionAPIError("Permission '\(name)' is unknown or URL pattern is malformed.")
            }
            names.append(name)
        }
        var origins: [(string: String, pattern: WKWebExtension.MatchPattern)] = []
        for origin in object["origins"] as? [String] ?? [] where !origins.contains(where: { $0.string == origin }) {
            guard let pattern = try? WKWebExtension.MatchPattern(string: origin) else {
                throw ChromeExtensionAPIError("Permission '\(origin)' is unknown or URL pattern is malformed.")
            }
            origins.append((origin, pattern))
        }
        let declared = entry.declaredPermissions.union(entry.optionalPermissions)
        let declaredHosts = declaredHostPatterns(entry)
        let undeclaredName = names.contains { !declared.contains($0) }
        let undeclaredOrigin = origins.contains { origin in
            !declaredHosts.contains { $0.matches(origin.pattern, options: [.ignorePaths]) }
        }
        if undeclaredName || undeclaredOrigin {
            throw ChromeExtensionAPIError("Only permissions specified in the manifest may be \(verb).")
        }
        return PermissionSet(names: names, origins: origins)
    }

    func permissionsGetAll(_ extensionID: String) throws -> [String: Any] {
        guard let entry = entries[extensionID] else { throw ChromeExtensionAPIError("Extension is not loaded.") }
        var names: [String] = []
        for permission in entry.context.currentPermissions.map(\.rawValue).sorted()
        where permission != WKWebExtension.Permission.nativeMessaging.rawValue || entry.declaresNativeMessaging {
            names.append(permission)
        }
        let orbitOwned = entry.declaredPermissions.union(entry.optionalPermissions)
            .subtracting(entry.webKitPermissions)
            .filter { isRecognized($0, entry: entry) && hasPermission($0, extensionID: extensionID) }
        for name in orbitOwned.sorted() where !names.contains(name) { names.append(name) }
        var origins: [String] = []
        for pattern in entry.context.currentPermissionMatchPatterns.map(\.string).sorted() where !origins.contains(pattern) {
            origins.append(pattern)
        }
        return ["permissions": names, "origins": origins]
    }

    func permissionsContains(_ extensionID: String, details: Any?) throws -> Bool {
        guard let entry = entries[extensionID] else { throw ChromeExtensionAPIError("Extension is not loaded.") }
        let object = details as? [String: Any] ?? [:]
        let names = object["permissions"] as? [String] ?? []
        let origins = object["origins"] as? [String] ?? []
        for name in names where !hasPermission(name, extensionID: extensionID) { return false }
        for origin in origins {
            guard let pattern = try? WKWebExtension.MatchPattern(string: origin), isGranted(pattern, entry: entry) else { return false }
        }
        return true
    }

    func permissionsRequest(_ extensionID: String, details: Any?) async throws -> Bool {
        guard let entry = entries[extensionID] else { throw ChromeExtensionAPIError("Extension is not loaded.") }
        let requested = try parsePermissionSet(details, entry: entry, verb: "requested")
        let names = requested.names.filter { !hasPermission($0, extensionID: extensionID) }
        let origins = requested.origins.filter { !isGranted($0.pattern, entry: entry) }
        guard !names.isEmpty || !origins.isEmpty else { return true }
        let approved = await WebKitExtensionPermissionConsent.shared.ask(
            extensionID: extensionID,
            extensionName: entry.manifest.name,
            permissions: names,
            origins: origins.map(\.string)
        )
        guard approved, let current = entries[extensionID], current === entry else { return false }
        grant(names: names, origins: origins, entry: entry)
        return true
    }

    func permissionsRemove(_ extensionID: String, details: Any?) throws -> Bool {
        guard let entry = entries[extensionID] else { throw ChromeExtensionAPIError("Extension is not loaded.") }
        let removing = try parsePermissionSet(details, entry: entry, verb: "removed")
        let requiredHosts = requiredHostPatterns(entry)
        if removing.names.contains(where: { entry.declaredPermissions.contains($0) })
            || removing.origins.contains(where: { origin in requiredHosts.contains { $0.matches(origin.pattern, options: [.ignorePaths]) } }) {
            throw ChromeExtensionAPIError("You cannot remove required permissions.")
        }
        let grantedOptional = state.state(for: extensionID).grantedOptionalPermissions
        let names = removing.names.filter {
            hasPermission($0, extensionID: extensionID) || grantedOptional.contains($0)
        }
        let origins = removing.origins.filter { isGranted($0.pattern, entry: entry) }
        for name in names where entry.webKitPermissions.contains(name) {
            entry.context.setPermissionStatus(.unknown, for: WKWebExtension.Permission(rawValue: name))
        }
        for origin in origins {
            entry.context.setPermissionStatus(.unknown, for: origin.pattern)
        }
        state.update(extensionID) { record in
            record.grantedOptionalPermissions.removeAll { names.contains($0) }
            record.grantedOptionalOrigins.removeAll { origin in origins.contains { $0.string == origin } }
        }
        if !names.isEmpty || !origins.isEmpty {
            deliver(namespace: "permissions", event: "onRemoved", args: [["permissions": names, "origins": origins.map(\.string)]], to: extensionID)
            if names.contains(where: { Self.orbitPermissions.contains($0) }) { announceGrants(extensionID) }
        }
        return true
    }

    private func grant(names: [String], origins: [(string: String, pattern: WKWebExtension.MatchPattern)], entry: WebKitExtensionEntry) {
        for name in names where entry.webKitPermissions.contains(name) {
            entry.context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name))
        }
        for origin in origins {
            entry.context.setPermissionStatus(.grantedExplicitly, for: origin.pattern)
        }
        state.update(entry.id) { record in
            for name in names where !record.grantedOptionalPermissions.contains(name) {
                record.grantedOptionalPermissions.append(name)
            }
            for origin in origins where !record.grantedOptionalOrigins.contains(origin.string) {
                record.grantedOptionalOrigins.append(origin.string)
            }
        }
        deliver(namespace: "permissions", event: "onAdded", args: [["permissions": names, "origins": origins.map(\.string)]], to: entry.id)
        if names.contains(where: { Self.orbitPermissions.contains($0) }) { announceGrants(entry.id) }
        system.permissionsChanged(entry)
    }

    /// The wrapper builds Orbit's namespaces from this list, so a grant or revoke reshapes `chrome` in place.
    private func announceGrants(_ extensionID: String) {
        let granted = grantedPermissions(extensionID).filter { Self.orbitPermissions.contains($0) }.sorted()
        deliver(namespace: "__orbit", event: "grants", args: [granted], to: extensionID)
    }

    // WebKit's own prompts, reached when WebKit itself needs consent rather than chrome.permissions.request.

    func promptForPermissions(_ permissions: Set<WKWebExtension.Permission>, context: WKWebExtensionContext) async -> Set<WKWebExtension.Permission> {
        guard let entry = entry(for: context), !permissions.isEmpty else { return [] }
        let approved = await WebKitExtensionPermissionConsent.shared.ask(
            extensionID: entry.id, extensionName: entry.manifest.name,
            permissions: permissions.map(\.rawValue).sorted(), origins: []
        )
        guard approved else { return [] }
        state.update(entry.id) { record in
            for permission in permissions where entry.optionalPermissions.contains(permission.rawValue)
                && !record.grantedOptionalPermissions.contains(permission.rawValue) {
                record.grantedOptionalPermissions.append(permission.rawValue)
            }
        }
        return permissions
    }

    func promptForMatchPatterns(_ patterns: Set<WKWebExtension.MatchPattern>, context: WKWebExtensionContext) async -> Set<WKWebExtension.MatchPattern> {
        guard let entry = entry(for: context), !patterns.isEmpty else { return [] }
        let approved = await WebKitExtensionPermissionConsent.shared.ask(
            extensionID: entry.id, extensionName: entry.manifest.name,
            permissions: [], origins: patterns.map(\.string).sorted()
        )
        guard approved else { return [] }
        state.update(entry.id) { record in
            for pattern in patterns where !record.grantedOptionalOrigins.contains(pattern.string) {
                record.grantedOptionalOrigins.append(pattern.string)
            }
        }
        return patterns
    }

    func promptForURLs(_ urls: Set<URL>, context: WKWebExtensionContext) async -> Set<URL> {
        guard let entry = entry(for: context), !urls.isEmpty else { return [] }
        let hosts = urls.compactMap { url -> String? in
            guard let scheme = url.scheme, let host = url.host else { return nil }
            return "\(scheme)://\(host)/*"
        }
        let approved = await WebKitExtensionPermissionConsent.shared.ask(
            extensionID: entry.id, extensionName: entry.manifest.name,
            permissions: [], origins: Array(Set(hosts)).sorted()
        )
        return approved ? urls : []
    }

    // MARK: - Event delivery

    private enum PortRole: String {
        case background
        case page
    }

    private struct PortRecord {
        let extensionID: String
        let port: WKWebExtension.MessagePort
        var role: PortRole?
    }

    private var ports: [ObjectIdentifier: PortRecord] = [:]
    private var queuedEvents: [String: [[String: Any]]] = [:]
    private var waking: Set<String> = []
    private var nextEventSequence = 1
    private static let queueLimit = 512
    private static let socketBeforeRequestEvents = ["onBeforeRequest"]
    private static let socketOpenEvents = [
        "onBeforeSendHeaders", "onSendHeaders", "onHeadersReceived", "onResponseStarted", "onCompleted",
    ]
    private static let socketErrorEvents = ["onErrorOccurred"]
    private static let webRequestSchemes = ["http", "https", "ws", "wss", "ftp", "file"]
    private static let webRequestWildcardSchemes = ["http", "https", "ws", "wss", "ftp"]
    private static let authenticationSchemes: [String: String] = [
        NSURLAuthenticationMethodHTTPBasic: "basic",
        NSURLAuthenticationMethodHTTPDigest: "digest",
        NSURLAuthenticationMethodNTLM: "ntlm",
        NSURLAuthenticationMethodNegotiate: "negotiate",
        NSURLAuthenticationMethodDefault: "basic",
    ]

    /// The wrapper's own port; it announces whether it lives in the background or a page.
    func attachEventPort(_ port: WKWebExtension.MessagePort, extensionID: String) {
        let key = ObjectIdentifier(port)
        ports[key] = PortRecord(extensionID: extensionID, port: port, role: nil)
        port.messageHandler = { [weak self] message, _ in
            Task { @MainActor in self?.receivePortMessage(message, key: key) }
        }
        port.disconnectHandler = { [weak self] _ in
            Task { @MainActor in self?.detachPort(key) }
        }
    }

    private func receivePortMessage(_ message: Any?, key: ObjectIdentifier) {
        guard let object = message as? [String: Any], object["orbitPortHello"] as? Bool == true,
              var record = ports[key],
              let role = PortRole(rawValue: object["role"] as? String ?? "")
        else { return }
        record.role = role
        ports[key] = record
        guard role == .background else { return }
        startBackgroundKeepAlive()
        waking.remove(record.extensionID)
        for message in queuedEvents.removeValue(forKey: record.extensionID) ?? [] {
            record.port.sendMessage(message, completionHandler: nil)
        }
    }

    private func detachPort(_ key: ObjectIdentifier) {
        guard let record = ports.removeValue(forKey: key) else { return }
        if record.role == .background {
            resumePendingAuth(forExtensionID: record.extensionID)
        }
    }

    /// A page opened a WebSocket or WebTransport. WebKit's webRequest never reports those,
    /// so the page probe hands the handshake here and each extension that may see the URL
    /// gets the same events Chrome would.
    func reportSocketWebRequest(kind: String, requestID: String, url: URL, type: String, contents: WebKitWebContents) {
        let events: [String]
        switch kind {
        case "before":
            events = Self.socketBeforeRequestEvents
        case "open":
            events = Self.socketOpenEvents
        case "error":
            events = Self.socketErrorEvents
        default:
            return
        }
        var details: [String: Any] = [
            "requestId": requestID,
            "url": url.absoluteString,
            "method": "GET",
            "frameId": 0,
            "parentFrameId": -1,
            "tabId": engine?.extensionTabIDValue(for: contents) ?? -1,
            "type": type,
            "timeStamp": Date().timeIntervalSince1970 * 1000,
        ]
        if kind == "error" { details["error"] = "net::ERR_FAILED" }
        for id in loadOrder {
            guard hasPermission("webRequest", extensionID: id),
                  let entry = entries[id],
                  maySeeWebRequest(url, entry: entry)
            else { continue }
            for event in events {
                deliver(namespace: "webRequest", event: event, args: [details], to: id)
            }
        }
    }

    /// A cookie the page stored or deleted. chrome.cookies.onChanged must see document.cookie, not only chrome.cookies.set.
    func reportBrowserCookieChange(_ cookie: HTTPCookie, removed: Bool) {
        var domain = cookie.domain
        let hostOnly = !domain.hasPrefix(".")
        if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
        var record: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "session": cookie.expiresDate == nil,
            "hostOnly": hostOnly,
            "sameSite": "unspecified",
        ]
        if let expires = cookie.expiresDate {
            record["expirationDate"] = expires.timeIntervalSince1970
        }
        let info: [String: Any] = ["removed": removed, "cookie": record, "cause": "explicit"]
        broadcast(namespace: "cookies", event: "onChanged", args: [info], permission: "cookies")
    }

    /// An HTTP load WebKit completed in the page. WebKit's webRequest object does not deliver
    /// these to a service worker, so the resource-load delegate reports them here.
    func reportHTTPWebRequest(
        events: [String],
        record: WebKitContentsExtras.HTTPWebRequestRecord,
        contents: WebKitWebContents,
        error: String? = nil
    ) {
        guard Self.webRequestSchemes.contains(record.url.scheme?.lowercased() ?? "") else { return }
        var details: [String: Any] = [
            "requestId": record.requestID,
            "url": record.url.absoluteString,
            "method": record.method,
            "frameId": record.frameID,
            "parentFrameId": record.parentFrameID,
            "tabId": engine?.extensionTabIDValue(for: contents) ?? -1,
            "type": record.type,
            "timeStamp": Date().timeIntervalSince1970 * 1000,
        ]
        if let statusCode = record.statusCode { details["statusCode"] = statusCode }
        if !record.responseHeaders.isEmpty { details["responseHeaders"] = record.responseHeaders }
        if let error { details["error"] = error }
        for id in loadOrder {
            guard hasPermission("webRequest", extensionID: id),
                  let entry = entries[id],
                  maySeeWebRequest(record.url, entry: entry)
            else { continue }
            for event in events {
                deliver(namespace: "webRequest", event: event, args: [details], to: id)
            }
        }
    }

    private func maySeeWebRequest(_ url: URL, entry: WebKitExtensionEntry) -> Bool {
        if webRequestHostListed(entry.manifest.hostPermissions, url: url, entry: entry) { return true }
        let optional = entry.manifest.optionalHostPermissions
        guard !optional.isEmpty else { return false }
        let grantedList = state.state(for: entry.id).grantedOptionalOrigins
        guard !grantedList.isEmpty else { return false }
        let granted = Set(grantedList)
        for raw in optional where granted.contains(raw) {
            if webRequestHostAllows(raw, url: url, entry: entry) { return true }
        }
        return false
    }

    private func webRequestHostListed(_ patterns: [String], url: URL, entry: WebKitExtensionEntry) -> Bool {
        for raw in patterns where webRequestHostAllows(raw, url: url, entry: entry) { return true }
        return false
    }

    /// A pattern that matches the URL still hides the request when the extension has denied it.
    private func webRequestHostAllows(_ raw: String, url: URL, entry: WebKitExtensionEntry) -> Bool {
        guard Self.chromeHostPattern(raw, matches: url) else { return false }
        if let pattern = try? WKWebExtension.MatchPattern(string: raw) {
            switch entry.context.permissionStatus(for: pattern) {
            case .deniedExplicitly, .deniedImplicitly:
                return false
            default:
                break
            }
        }
        return true
    }

    /// Chrome match patterns, including `ws:` and `wss:`, which WebKit's matcher does not always accept.
    static func chromeHostPattern(_ pattern: String, matches url: URL) -> Bool {
        if let compiled = try? WKWebExtension.MatchPattern(string: pattern), compiled.matches(url) {
            return true
        }
        guard let scheme = url.scheme?.lowercased(), Self.webRequestSchemes.contains(scheme) else { return false }
        if pattern == "<all_urls>" { return true }
        guard let schemeEnd = pattern.range(of: "://") else { return false }
        let patternScheme = pattern[..<schemeEnd.lowerBound].lowercased()
        if patternScheme == "*" {
            guard Self.webRequestWildcardSchemes.contains(scheme) else { return false }
        } else if patternScheme != scheme {
            return false
        }
        let rest = pattern[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let hostPort = rest[..<slash]
        let pathPattern = rest[slash...]
        let host: Substring
        let port: Int?
        if let colon = hostPort.lastIndex(of: ":"),
           hostPort[hostPort.index(after: colon)...].allSatisfy(\.isNumber),
           !hostPort.hasPrefix("[") {
            host = hostPort[..<colon]
            port = Int(hostPort[hostPort.index(after: colon)...])
        } else {
            host = hostPort
            port = nil
        }
        if let port, url.port != port { return false }
        let actualHost = (url.host ?? "").lowercased()
        let wanted = host.lowercased()
        if wanted != "*" {
            if wanted.hasPrefix("*.") {
                let suffix = String(wanted.dropFirst(2))
                if actualHost != suffix && !actualHost.hasSuffix("." + suffix) { return false }
            } else if actualHost != wanted {
                return false
            }
        }
        let pathname = url.path.isEmpty ? "/" : url.path
        return pathGlob(pathPattern, matches: pathname)
    }

    private static func pathGlob(_ pattern: some StringProtocol, matches pathname: String) -> Bool {
        // Printable ASCII has no line terminator for `$` or `.` to treat specially, so a glob
        // matches the same paths as the regex without compiling one per socket event.
        if let matched = asciiPathGlob(pattern, pathname) { return matched }
        var regex = String()
        regex.reserveCapacity(pattern.count * 2 + 2)
        regex.append("^")
        for character in pattern {
            switch character {
            case "*":
                regex.append(".*")
            case ".", "+", "?", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\":
                regex.append("\\")
                regex.append(character)
            default:
                regex.append(character)
            }
        }
        regex.append("$")
        return pathname.range(of: regex, options: .regularExpression) != nil
    }

    private static func asciiPathGlob(_ pattern: some StringProtocol, _ pathname: String) -> Bool? {
        guard isPrintableASCII(pattern), isPrintableASCII(pathname) else { return nil }
        guard let star = pattern.firstIndex(of: "*") else {
            return pattern.utf8.elementsEqual(pathname.utf8)
        }
        let afterStar = pattern.index(after: star)
        guard !pattern[afterStar...].contains("*") else { return nil }
        let prefix = pattern[..<star]
        let suffix = pattern[afterStar...]
        return pathname.hasPrefix(prefix)
            && pathname.hasSuffix(suffix)
            && pathname.utf8.count >= prefix.utf8.count + suffix.utf8.count
    }

    private static func isPrintableASCII(_ text: some StringProtocol) -> Bool {
        text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    /// Every extension holding `permission` (or every loaded one when nil) receives the event.
    func broadcast(namespace: String, event: String, args: [Any], permission: String?) {
        for id in loadOrder {
            if let permission, !hasPermission(permission, extensionID: id) { continue }
            deliver(namespace: namespace, event: event, args: args, to: id)
        }
    }

    func deliver(namespace: String, event: String, args: [Any], to extensionID: String, backgroundOnly: Bool = false) {
        guard let entry = entries[extensionID] else { return }
        let message: [String: Any] = [
            "orbitChromeEvent": true,
            "namespace": namespace,
            "event": event,
            "args": args,
            "seq": nextEventSequence,
        ]
        nextEventSequence += 1
        let extensionPorts = ports.values.filter { $0.extensionID == extensionID }
        var reachedBackground = false
        for record in extensionPorts {
            switch record.role {
            case .background:
                reachedBackground = true
                record.port.sendMessage(message, completionHandler: nil)
            case .page:
                if !backgroundOnly { record.port.sendMessage(message, completionHandler: nil) }
            case nil:
                break
            }
        }
        if !backgroundOnly {
            engine?.deliverChromeEventToExtensionPages(message, extensionID: extensionID)
        }
        guard !reachedBackground, entry.context.webExtension.hasBackgroundContent else { return }
        // Pull the queue out first so append does not copy every event still sitting in the dictionary.
        var queue = queuedEvents.removeValue(forKey: extensionID) ?? []
        queue.append(message)
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
        queuedEvents[extensionID] = queue
        wakeBackground(entry)
    }

    private var backgroundKeepAlive: Timer?

    /// Chrome leaves a service worker alive for a while after its last event. A port message is enough to do the same.
    private func startBackgroundKeepAlive() {
        guard backgroundKeepAlive == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for record in self.ports.values where record.role == .background {
                    record.port.sendMessage(["orbitKeepAlive": true], completionHandler: nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundKeepAlive = timer
    }

    /// A content-script match is about to run. Start the worker first so its reply is ready when the script messages it.
    func wakeForContentScripts(matching url: URL) {
        for id in loadOrder {
            guard let entry = entries[id] else { continue }
            guard entry.manifest.contentScriptMatches.contains(where: { Self.chromeHostPattern($0, matches: url) }) else { continue }
            wakeBackground(entry)
        }
    }

    /// A non-persistent background WebKit unloaded is started again; its hello flushes the queue.
    private func wakeBackground(_ entry: WebKitExtensionEntry) {
        guard !waking.contains(entry.id) else { return }
        waking.insert(entry.id)
        let id = entry.id
        entry.context.loadBackgroundContent { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard let error else { return }
                extensionServicesLogger.error("Could not wake extension \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.waking.remove(id)
                self.queuedEvents[id] = nil
                self.resumePendingAuth(forExtensionID: id)
            }
        }
    }

    // MARK: - webRequest.onAuthRequired

    private var authListenerExtensions: Set<String> = []
    private var pendingAuth: [String: (extensionID: String, continuation: CheckedContinuation<[String: Any], Never>)] = [:]

    func registerAuthListener(_ extensionID: String) {
        authListenerExtensions.insert(extensionID)
    }

    func unregisterAuthListener(_ extensionID: String, remaining: Int) {
        if remaining <= 0 { authListenerExtensions.remove(extensionID) }
    }

    func answerAuth(token: String, response: [String: Any]) {
        pendingAuth.removeValue(forKey: token)?.continuation.resume(returning: response)
    }

    private func resumePendingAuth(forExtensionID extensionID: String) {
        for (token, pending) in pendingAuth where pending.extensionID == extensionID {
            pendingAuth[token] = nil
            pending.continuation.resume(returning: [:])
        }
    }

    /// Chrome's order: the most recently installed extension asks first; the first credentials or cancel wins.
    func authenticationDecision(
        for challenge: URLAuthenticationChallenge,
        in contents: WebKitWebContents
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
        let space = challenge.protectionSpace
        guard let scheme = Self.authenticationSchemes[space.authenticationMethod],
              let response = challenge.failureResponse as? HTTPURLResponse,
              let url = response.url
        else { return nil }
        let candidates = loadOrder.reversed().filter { id in
            guard authListenerExtensions.contains(id), let entry = entries[id] else { return false }
            return hasPermission("webRequest", extensionID: id)
                && hasPermission("webRequestAuthProvider", extensionID: id)
                && entry.context.hasAccess(to: url)
        }
        guard !candidates.isEmpty else { return nil }
        let isMainFrame = contents.navigationState.url == url
        var details: [String: Any] = [
            "url": url.absoluteString,
            "frameId": isMainFrame ? 0 : -1,
            "parentFrameId": -1,
            "tabId": engine?.extensionTabIDValue(for: contents) ?? -1,
            "type": isMainFrame ? "main_frame" : "other",
            "timeStamp": Date().timeIntervalSince1970 * 1000,
            "scheme": scheme,
            "challenger": ["host": space.host, "port": space.port],
            "isProxy": space.isProxy(),
            "statusCode": response.statusCode,
            "statusLine": "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized)",
            "responseHeaders": response.allHeaderFields.map { ["name": "\($0.key)", "value": "\($0.value)"] },
        ]
        if let realm = space.realm { details["realm"] = realm }
        for id in candidates {
            let token = UUID().uuidString
            details["requestId"] = token
            let event = details
            let answer: [String: Any] = await withCheckedContinuation { continuation in
                pendingAuth[token] = (id, continuation)
                deliver(namespace: "__orbit", event: "authRequired", args: [token, event], to: id, backgroundOnly: true)
            }
            if answer["cancel"] as? Bool == true { return (.cancelAuthenticationChallenge, nil) }
            if let credentials = answer["authCredentials"] as? [String: Any],
               let user = credentials["username"] as? String,
               let password = credentials["password"] as? String {
                return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
            }
        }
        return nil
    }

    // MARK: - declarativeNetRequest regexFilter originals

    private var sessionRegexFilters: [String: [String: String]] = [:]

    func rememberRegexFilters(_ extensionID: String, ruleset: String, remembered: [String: String], forget: [String]) {
        if ruleset == "session" {
            var filters = sessionRegexFilters.removeValue(forKey: extensionID) ?? [:]
            for id in forget { filters[id] = nil }
            filters.merge(remembered) { _, new in new }
            if !filters.isEmpty { sessionRegexFilters[extensionID] = filters }
            return
        }
        state.update(extensionID) { record in
            for id in forget { record.dynamicRegexFilters[id] = nil }
            record.dynamicRegexFilters.merge(remembered) { _, new in new }
        }
    }

    func regexFilters(_ extensionID: String, ruleset: String) -> [String: String] {
        ruleset == "session" ? (sessionRegexFilters[extensionID] ?? [:]) : state.state(for: extensionID).dynamicRegexFilters
    }

    // MARK: - Store-driven events

    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .orbitHistoryVisited, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let item = note.userInfo?["item"] else { return }
                self?.broadcast(namespace: "history", event: "onVisited", args: [item], permission: "history")
            }
        })
        observers.append(center.addObserver(forName: .orbitHistoryVisitsRemoved, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let allHistory = note.userInfo?["allHistory"] as? Bool ?? false
                let urls = note.userInfo?["urls"] as? [String] ?? []
                self?.broadcast(namespace: "history", event: "onVisitRemoved", args: [["allHistory": allHistory, "urls": urls]], permission: "history")
            }
        })
        observers.append(center.addObserver(forName: .orbitRecentlyClosedDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.broadcast(namespace: "sessions", event: "onChanged", args: [], permission: "sessions")
            }
        })
        observeManagementEvents()
        system.startObserving()
    }

    /// chrome.management events come from ExtensionStore, which knows install from enable.
    private func observeManagementEvents() {
        let store = AppEnvironment.processRoot.extensionStore
        if let current = managementObserver {
            guard current.store !== store else { return }
            current.store.removeChangeObserver(current.token)
        }
        let token = store.addChangeObserver { [weak self] event in
            guard let self else { return }
            switch event {
            case .installed(let ext):
                self.broadcast(namespace: "management", event: "onInstalled", args: [ChromeExtensionAPI.extensionInfo(ext)], permission: "management")
            case .enabled(let ext):
                self.broadcast(namespace: "management", event: "onEnabled", args: [ChromeExtensionAPI.extensionInfo(ext)], permission: "management")
            case .disabled(let ext):
                self.broadcast(namespace: "management", event: "onDisabled", args: [ChromeExtensionAPI.extensionInfo(ext)], permission: "management")
            case .uninstalled(let id):
                self.broadcast(namespace: "management", event: "onUninstalled", args: [id], permission: "management")
            case .willReplace:
                break
            }
        }
        managementObserver = (store, token)
    }

    // MARK: - webNavigation, main frame

    private struct NavigationRecord {
        var transitionType: String?
        var qualifiers: [String] = []
        var documentID: String?
        var url: URL?
    }

    private var navigations: [UUID: NavigationRecord] = [:]

    func navigationStarted(_ contents: WebKitWebContents, url: URL, navigationType: WKNavigationType, browserInitiated: Bool) {
        guard Self.reportsNavigation(of: url) else { return }
        var record = NavigationRecord()
        switch navigationType {
        case .linkActivated: record.transitionType = "link"
        case .formSubmitted, .formResubmitted: record.transitionType = "form_submit"
        case .backForward:
            record.transitionType = "link"
            record.qualifiers = ["forward_back"]
        case .reload: record.transitionType = "reload"
        default: record.transitionType = browserInitiated ? "typed" : "link"
        }
        if browserInitiated, navigationType != .reload, navigationType != .backForward {
            record.qualifiers.append("from_address_bar")
        }
        record.url = url
        let open = Set(engine?.openTabs.map(\.id) ?? [])
        navigations = navigations.filter { open.contains($0.key) }
        navigations[contents.id] = record
        var details = baseDetails(contents, url: url)
        details["parentDocumentId"] = nil
        broadcast(namespace: "webNavigation", event: "onBeforeNavigate", args: [details], permission: "webNavigation")
    }

    func navigationFailed(_ contents: WebKitWebContents, url: URL, error: Error) {
        guard Self.reportsNavigation(of: url) else { return }
        var details = baseDetails(contents, url: url)
        details["error"] = Self.netErrorName(error)
        navigations[contents.id] = nil
        broadcast(namespace: "webNavigation", event: "onErrorOccurred", args: [details], permission: "webNavigation")
    }

    /// From Orbit's isolated-world observer: the document's own lifecycle, main frame only.
    func navigationDocumentEvent(_ contents: WebKitWebContents, body: [String: Any]) {
        guard let kind = body["kind"] as? String,
              let url = URL(string: body["url"] as? String ?? ""),
              Self.reportsNavigation(of: url)
        else { return }
        let key = contents.id
        var record = navigations[key] ?? NavigationRecord()
        switch kind {
        case "commit":
            if record.transitionType == nil {
                switch body["navigationType"] as? String {
                case "reload": record.transitionType = "reload"
                case "back_forward":
                    record.transitionType = "link"
                    record.qualifiers = ["forward_back"]
                default: record.transitionType = "link"
                }
            }
            record.documentID = Self.documentIdentifier()
            record.url = url
            var details = baseDetails(contents, url: url, documentID: record.documentID)
            details["transitionType"] = record.transitionType
            details["transitionQualifiers"] = record.qualifiers
            navigations[key] = NavigationRecord(transitionType: nil, qualifiers: [], documentID: record.documentID, url: url)
            broadcast(namespace: "webNavigation", event: "onCommitted", args: [details], permission: "webNavigation")
        case "domContentLoaded":
            broadcast(namespace: "webNavigation", event: "onDOMContentLoaded", args: [baseDetails(contents, url: url, documentID: record.documentID)], permission: "webNavigation")
        case "load":
            broadcast(namespace: "webNavigation", event: "onCompleted", args: [baseDetails(contents, url: url, documentID: record.documentID)], permission: "webNavigation")
        case "fragment", "historyState":
            var details = baseDetails(contents, url: url, documentID: record.documentID)
            details["transitionType"] = "link"
            details["transitionQualifiers"] = [String]()
            let event = kind == "fragment" ? "onReferenceFragmentUpdated" : "onHistoryStateUpdated"
            broadcast(namespace: "webNavigation", event: event, args: [details], permission: "webNavigation")
        default:
            break
        }
    }

    private func baseDetails(_ contents: WebKitWebContents, url: URL, documentID: String? = nil) -> [String: Any] {
        var details: [String: Any] = [
            "tabId": engine?.extensionTabIDValue(for: contents) ?? -1,
            "url": url.absoluteString,
            "processId": -1,
            "frameId": 0,
            "parentFrameId": -1,
            "frameType": "outermost_frame",
            "documentLifecycle": "active",
            "timeStamp": (Date().timeIntervalSince1970 * 1000).rounded(.down),
        ]
        if let documentID { details["documentId"] = documentID }
        return details
    }

    private static func reportsNavigation(of url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "ftp", "data", "about", "blob"].contains(scheme)
    }

    private static func documentIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }

    /// Chrome reports net error names; these are the Foundation errors WebKit hands a navigation delegate.
    static func netErrorName(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return "net::ERR_FAILED" }
        switch ns.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "net::ERR_NAME_NOT_RESOLVED"
        case NSURLErrorTimedOut: return "net::ERR_TIMED_OUT"
        case NSURLErrorCancelled: return "net::ERR_ABORTED"
        case NSURLErrorCannotConnectToHost: return "net::ERR_CONNECTION_REFUSED"
        case NSURLErrorNetworkConnectionLost: return "net::ERR_CONNECTION_RESET"
        case NSURLErrorNotConnectedToInternet: return "net::ERR_INTERNET_DISCONNECTED"
        case NSURLErrorSecureConnectionFailed: return "net::ERR_SSL_PROTOCOL_ERROR"
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return "net::ERR_CERT_INVALID"
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return "net::ERR_INVALID_URL"
        case NSURLErrorHTTPTooManyRedirects: return "net::ERR_TOO_MANY_REDIRECTS"
        case NSURLErrorFileDoesNotExist: return "net::ERR_FILE_NOT_FOUND"
        default: return "net::ERR_FAILED"
        }
    }
}

/// Orbit's wrapper reaches native code through runtime.sendNativeMessage to a reserved id, which
/// WebKit only binds with nativeMessaging granted. The grant is made on the context, never written
/// into the manifest; the engine refuses every real host to an extension that did not declare it,
/// and chrome.permissions never reports it for one.
@MainActor
enum WebKitExtensionTransport {
    static let applicationIdentifier = "com.orbit.chrome"

    static func open(on context: WKWebExtensionContext) {
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
    }
}

/// chrome.permissions.request's consent, shown on the frontmost window's sheet and answered exactly once.
@MainActor
final class WebKitExtensionPermissionConsent {
    static let shared = WebKitExtensionPermissionConsent()

    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Bool, Never>] = [:]

    func ask(extensionID: String, extensionName: String, permissions: [String], origins: [String]) async -> Bool {
        if let automatic = WebStoreInstallVerifyProbe.autoAnswerExtensionPermissionsConsent {
            return automatic
        }
        // Resolved only by a click, so an unattended run has nobody to answer it.
        guard !DebugFlags.isRunningUnderTests else { return false }
        let environment = AppEnvironment.frontmost
        guard let tabID = environment.activeTabID,
              environment.pendingExtensionPermissionsConsent[tabID] == nil
        else { return false }
        var warnings = ExtensionPermissionWarnings.warnings(forPermissions: permissions, origins: origins)
        if warnings.isEmpty { warnings = permissions + origins }
        let requestID = nextRequestID
        nextRequestID += 1
        let request = ExtensionPermissionsConsentRequest(
            requestID: requestID,
            extensionID: extensionID,
            extensionName: extensionName,
            permissions: permissions,
            origins: origins,
            warnings: warnings
        )
        return await withCheckedContinuation { continuation in
            pending[requestID] = continuation
            environment.pendingExtensionPermissionsConsent[tabID] = request
        }
    }

    func answer(requestID: UInt64, approved: Bool) {
        pending.removeValue(forKey: requestID)?.resume(returning: approved)
    }
}

extension Notification.Name {
    static let orbitHistoryVisited = Notification.Name("orbit.history.visited")
    static let orbitHistoryVisitsRemoved = Notification.Name("orbit.history.visitsRemoved")
}
