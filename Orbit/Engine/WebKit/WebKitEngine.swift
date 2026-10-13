import Foundation
import WebKit

typealias ChromiumEngine = WebKitEngine
typealias ChromiumWebContents = WebKitWebContents

@MainActor
final class WebKitEngine: NSObject, BrowserEngine {
    static let kind: EngineKind = .webkit

    var capabilities: EngineCapabilities {
        [
            .extensions, .developerTools, .audioMuting, .pictureInPicture,
            .backgroundSnapshots, .printing, .downloadManager, .multipleProfiles,
            .userScripts, .contentBlocking, .blockedRequestCounts,
        ]
    }

    let manageableContentSettings: Set<PermissionKind> = [
        .camera, .microphone, .geolocation, .notifications,
    ]
    let extensionActivation: ExtensionActivation = .immediate
    var versionDescription: String { WebKitProduct.versionDescription }
    let extensionActionStates = ExtensionActionStateStore()

    private let storage: EngineStorage
    private var sessions: [String: WebKitSession] = [:]
    private var userScripts: [UserScript] = []
    private var loaded: [String: LoadedExtensionRecord] = [:]
    private(set) var openTabs: [WebKitWebContents] = []
    private var activeTab: WebKitWebContents?
    private var tabNumbers: [UUID: Int32] = [:]
    private var nextTabNumber: Int32 = 1
    private var contentBlocker: ContentBlocker?
    private var nativePorts: [String: WKWebExtension.MessagePort] = [:]
    private var runtimeReplies: [String: (Any?) -> Void] = [:]
    let extensionController = WKWebExtensionController()
    let extensionWindow = WebKitExtensionWindow()
    private let schemeHandler = OrbitSchemeHandler()

    init(storage: EngineStorage) {
        self.storage = storage
        super.init()
        extensionWindow.engine = self
        extensionController.delegate = self
    }

    func start() throws {
        if let directory = EngineStorageDirectory.directory(for: storage) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("webkit-profile")
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data("webkit".utf8).write(to: marker)
            }
        }
        extensionController.didOpenWindow(extensionWindow)
        ExtensionCommandRegistry.shared.dispatch = { [weak self] extensionID, name in
            self?.performCommand(extensionID: extensionID, name: name) ?? false
        }
    }

    func shutdown() -> Bool {
        let contexts = loaded.values.map(\.context)
        loaded.removeAll()
        nativePorts.removeAll()
        runtimeReplies.removeAll()
        let tabs = openTabs
        openTabs.removeAll()
        activeTab = nil
        for tab in tabs {
            extensionController.didCloseTab(tab, windowIsClosing: false)
        }
        for context in contexts {
            try? extensionController.unload(context)
        }
        for tab in tabs { tab.teardown(notifyExtensionController: false) }
        return true
    }

    func session(identifier: String, persistent: Bool) throws -> EngineSession {
        if let existing = sessions[identifier] { return existing }
        let created = WebKitSession(
            identifier: identifier,
            persistent: persistent && storage != .ephemeral,
            storageURL: EngineStorageDirectory.directory(for: storage)
        )
        sessions[identifier] = created
        return created
    }

    var defaultSession: EngineSession {
        if let existing = sessions["default"] { return existing }
        let persistent = storage != .ephemeral
        let created = WebKitSession(
            identifier: "default",
            persistent: persistent,
            storageURL: EngineStorageDirectory.directory(for: storage)
        )
        sessions["default"] = created
        return created
    }

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        let webKitSession = (session as? WebKitSession) ?? (defaultSession as! WebKitSession)
        let contents = WebKitWebContents(engine: self, session: webKitSession, initialURL: initialURL)
        noteTabOpened(contents)
        if let initialURL { contents.load(initialURL) }
        return contents
    }

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {
        guard let webKitSession = session as? WebKitSession else { return }
        await webKitSession.clear(scope, since: since)
    }

    func addUserScript(_ script: UserScript, session: EngineSession) {
        if let index = userScripts.firstIndex(where: { $0.id == script.id }) {
            userScripts[index] = script
        } else {
            userScripts.append(script)
        }
        for tab in openTabs { tab.reinstallScripts() }
    }

    func removeUserScript(id: UUID, session: EngineSession) {
        userScripts.removeAll { $0.id == id }
        for tab in openTabs { tab.reinstallScripts() }
    }

    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {
        contentBlocker = blocker
        let json = await SafariContentRuleCompiler.json(for: blocker)
        let list = await SafariContentRuleCompiler.compile(json)
        for tab in openTabs { tab.applyContentRuleList(list) }
    }

    func blockerDecision(url: String, documentURL: String, resourceType: ContentBlockingResourceType) -> Bool {
        contentBlocker?.shouldBlock(url: url, documentURL: documentURL, resourceType: resourceType.rawValue) ?? false
    }

    func cosmeticStyleSheet(for documentURL: String) -> String {
        contentBlocker?.cosmeticStyleSheet(forDocumentURL: documentURL) ?? ""
    }

    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
        try await loadExtension(at: directory, session: session, reason: .userAction)
    }

    func loadExtension(at directory: URL, session: EngineSession, reason: ExtensionLoadReason) async throws -> LoadedExtension {
        let manifest = try? ChromeExtensionManifest.read(fromDirectory: directory)
        let declaredPermissions = Set(manifest?.permissions ?? [])
        let id = extensionID(for: directory, manifest: manifest)
        try ChromeAPIWrapperScript.install(in: directory)
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        if let error = webExtension.errors.first {
            throw EngineError(code: .unknown, underlyingDescription: error.localizedDescription)
        }
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id
        // Non-persistent stores are private tabs. Scripts inject only with this set.
        context.hasAccessToPrivateData = true
        grant(webExtension, on: context)
        try extensionController.load(context)
        if webExtension.hasBackgroundContent {
            try await context.loadBackgroundContent()
        }
        let loadedExtension = LoadedExtension(
            id: context.uniqueIdentifier,
            name: manifest?.name ?? webExtension.displayName ?? directory.lastPathComponent,
            version: manifest?.version ?? webExtension.version ?? "",
            directory: directory,
            hasToolbarAction: manifest?.hasToolbarAction ?? (webExtension.displayActionLabel != nil),
            manifestVersion: manifest?.manifestVersion ?? Int(webExtension.manifestVersion),
            isEnabled: true,
            isActivated: true,
            idIsEngineAssigned: true
        )
        loaded[loadedExtension.id] = LoadedExtensionRecord(
            extension: loadedExtension, context: context, declaredPermissions: declaredPermissions
        )
        publishAction(for: context, tab: nil)
        return loadedExtension
    }

    func unloadExtension(id: String, session: EngineSession) {
        guard let record = loaded.removeValue(forKey: id) else { return }
        try? extensionController.unload(record.context)
        extensionActionStates.remove(extensionID: id)
    }

    func uninstallExtension(id: String, session: EngineSession) {
        unloadExtension(id: id, session: session)
    }

    func extensionDiagnostics(id: String) -> String {
        guard let record = loaded[id] else { return "not loaded" }
        let errors = record.context.errors.map(\.localizedDescription).joined(separator: " | ")
        let manifest = record.context.webExtension.manifest
        let injectable = record.context.webExtension.hasInjectedContent
        return "loaded=\(record.context.isLoaded) injectable=\(injectable) private=\(record.context.hasAccessToPrivateData) errors=\(errors) manifest=\(manifest)"
    }

    func loadedExtensions(session: EngineSession) -> [LoadedExtension] {
        loaded.values.map(\.extension).sorted { $0.name < $1.name }
    }

    func makeConfiguration(session: WebKitSession, bridge: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = session.dataStore
        configuration.webExtensionController = extensionController
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "orbit")
        let content = WKUserContentController()
        content.add(bridge, name: "orbit")
        installScripts(on: content)
        configuration.userContentController = content
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }

    func installScripts(on content: WKUserContentController) {
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(
            source: Self.bootstrapSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        for script in userScripts {
            content.addUserScript(Self.userScript(script))
        }
    }

    func noteTabOpened(_ contents: WebKitWebContents) {
        guard !openTabs.contains(where: { $0 === contents }) else { return }
        openTabs.append(contents)
        tabNumbers[contents.id] = nextTabNumber
        nextTabNumber += 1
        extensionController.didOpenTab(contents)
    }

    func noteTabClosed(_ contents: WebKitWebContents) {
        openTabs.removeAll { $0 === contents }
        if activeTab === contents { activeTab = openTabs.last }
        extensionController.didCloseTab(contents, windowIsClosing: false)
    }

    func noteActive(_ contents: WebKitWebContents) {
        let previous = activeTab
        activeTab = contents
        extensionController.didActivateTab(contents, previousActiveTab: previous)
    }

    func numericID(for tabID: UUID) -> Int32? { tabNumbers[tabID] }

    func numericID(for contents: WebKitWebContents) -> Int32? { tabNumbers[contents.id] }

    private func grant(_ webExtension: WKWebExtension, on context: WKWebExtensionContext) {
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    private func extensionID(for directory: URL, manifest: ChromeExtensionManifest?) -> String {
        if let key = manifest?.key, let derived = ChromeExtensionID.id(fromPublicKeyBase64: key) {
            return derived
        }
        return ChromeExtensionID.id(forUnpackedPath: directory)
    }

    func performChromeAPI(extensionID: String, namespace: String, method: String, args: [Any]) async -> Result<Any, Error> {
        let declared = loaded[extensionID]?.declaredPermissions ?? []
        return await ChromeExtensionAPI.invoke(
            namespace: namespace, method: method, args: args, declaredPermissions: declared
        )
    }

    private func publishAction(for context: WKWebExtensionContext, tab: (any WKWebExtensionTab)?) {
        guard let action = context.action(for: tab) else { return }
        let id = context.uniqueIdentifier
        var state = ExtensionActionState(
            badgeText: action.badgeText,
            title: action.label,
            isEnabled: action.isEnabled
        )
        if let image = action.icon(for: CGSize(width: 32, height: 32)), let png = Self.pngData(from: image) {
            state.iconPNG = png
        }
        let existing = extensionActionStates.snapshots[id]
        var perTab = existing?.perTab ?? [:]
        var defaults = existing?.defaults ?? ExtensionActionState()
        if let contents = tab as? WebKitWebContents, let number = numericID(for: contents) {
            perTab[number] = state
        } else {
            defaults = state
        }
        extensionActionStates.apply(ExtensionActionSnapshot(extensionID: id, defaults: defaults, perTab: perTab))
    }

    @discardableResult
    private func performCommand(extensionID: String, name: String) -> Bool {
        guard let context = loaded[extensionID]?.context,
              let command = context.commands.first(where: { $0.id == name || $0.title == name })
        else { return false }
        context.performCommand(command)
        return true
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func userScript(_ script: UserScript) -> WKUserScript {
        let source: String
        if script.kind == .stylesheet {
            let encoded = JavaScriptLiteral.string(script.source)
            source = "(function(){var style=document.createElement('style');style.textContent=\(encoded);(document.head||document.documentElement).appendChild(style);})();"
        } else {
            source = Self.scoped(script.source, patterns: script.matchPatterns)
        }
        return WKUserScript(
            source: source,
            injectionTime: script.injectionTime == .documentStart ? .atDocumentStart : .atDocumentEnd,
            forMainFrameOnly: !script.allFrames
        )
    }

    private static func scoped(_ source: String, patterns: [String]) -> String {
        if patterns.contains("<all_urls>") || patterns.contains("*://*/*") { return source }
        let hosts = patterns.compactMap(patternHost)
        guard !hosts.isEmpty else { return source }
        let predicate = hosts.map { "location.hostname===\(JavaScriptLiteral.string($0))" }.joined(separator: "||")
        return "(function(){if(!(\(predicate)))return;\(source)})();"
    }

    private static func patternHost(_ pattern: String) -> String? {
        guard let scheme = pattern.range(of: "://") else { return nil }
        let host = pattern[scheme.upperBound...].prefix { $0 != "/" && $0 != "*" }
        guard !host.isEmpty, host != "*" else { return nil }
        return String(host)
    }

    private static let bootstrapSource = """
    window.chrome = window.chrome || {};
    window.__orbitPostMessage = function(channel, json) {
      try { window.webkit.messageHandlers.orbit.postMessage({channel: channel, json: json}); } catch (e) {}
    };
    """

    private struct LoadedExtensionRecord {
        var `extension`: LoadedExtension
        var context: WKWebExtensionContext
        var declaredPermissions: Set<String>
    }
}

@MainActor
final class WebKitExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var engine: WebKitEngine?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        engine?.openTabs ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        engine?.openTabs.last
    }
}

extension WebKitEngine: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [extensionWindow]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        extensionWindow
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        guard let record = loaded[context.uniqueIdentifier] else { return }
        publishAction(for: record.context, tab: action.associatedTab)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        guard let object = message as? [String: Any], object["orbitChromeAPI"] as? Bool == true else {
            replyHandler(nil, ChromeExtensionAPIError("Not an Orbit chrome wrapper call."))
            return
        }
        let namespace = object["namespace"] as? String ?? ""
        let method = object["method"] as? String ?? ""
        let args = object["args"] as? [Any] ?? []
        let extensionID = extensionContext.uniqueIdentifier
        Task { @MainActor in
            let result = await performChromeAPI(extensionID: extensionID, namespace: namespace, method: method, args: args)
            switch result {
            case .success(let value): replyHandler(value, nil)
            case .failure(let error): replyHandler(nil, error)
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let session = (defaultSession as? WebKitSession) ?? WebKitSession(identifier: "default", persistent: false, storageURL: nil)
        let contents = WebKitWebContents(engine: self, session: session, initialURL: configuration.url)
        noteTabOpened(contents)
        if let url = configuration.url { contents.load(url) }
        completionHandler(contents, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let id = extensionContext.uniqueIdentifier
        nativePorts[id] = port
        port.messageHandler = { [weak self] message, _ in
            Task { @MainActor in
                self?.receiveNativePortMessage(message, extensionID: id)
            }
        }
        completionHandler(nil)
    }

    private func receiveNativePortMessage(_ message: Any?, extensionID: String) {
        let object: [String: Any]?
        if let dictionary = message as? [String: Any] {
            object = dictionary
        } else if let text = message as? String, let data = text.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            object = nil
        }
        guard let object, object["orbitRuntimeReply"] as? Bool == true, let token = object["id"] as? String else { return }
        let response = object["response"]
        runtimeReplies.removeValue(forKey: token)?(response)
    }
}

final class OrbitSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>"
        let url = urlSchemeTask.request.url ?? URL(string: "orbit://new-tab")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8",
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data(html.utf8))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
