import Foundation
import OSLog
import Security
import WebKit

private let engineLogger = Logger(subsystem: "com.orbit.browser", category: "WebKitEngine")

@MainActor
final class WebKitEngine: NSObject, BrowserEngine {
    static let kind: EngineKind = .webkit

    var capabilities: EngineCapabilities {
        [
            .extensions, .developerTools, .audioMuting, .pictureInPicture,
            .backgroundSnapshots, .printing, .downloadManager, .multipleProfiles,
            .userScripts, .contentBlocking, WebKitContentBlocking.countingCapability,
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
    /// Compiled once. `WKUserScript` copies its source, and the imported localStorage script is the whole database.
    private var compiledUserScripts: [UUID: (script: UserScript, compiled: WKUserScript)] = [:]
    /// Bumped when `start` schedules an import and again on shutdown, so a late read cannot install into a dead engine.
    private var importedLocalStorageGeneration = 0
    /// The Chromium profile under Application Support/Orbit is read once, before the first page load.
    private var chromiumSiteDataMigration: Task<Void, Never>?
    private var chromiumSiteDataMigrationInFlight = false
    private var acceptsChromiumMigration = true
    /// Never handed to a web view. Copies carry the scheme handlers, preferences, and extension controller.
    private lazy var configurationTemplate: WKWebViewConfiguration = makeConfigurationTemplate()
    private lazy var bootstrapUserScript = WKUserScript(
        source: Self.bootstrapSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
    private lazy var navigationUserScript = WebKitNavigationEventBridge.userScript
    private lazy var webRequestSocketUserScript = WebKitWebRequestSocketProbe.userScript
    private var loaded: [String: LoadedExtensionRecord] = [:]
    private var extensionLoadOrder: [String] = []
    /// Permissions known before `loadBackground` returns. The service worker calls
    /// chrome.* during that load, before the loaded-extension record exists.
    private var declaredPermissionsByExtension: [String: Set<String>] = [:]
    private(set) var openTabs: [WebKitWebContents] = []
    private var activeTab: WebKitWebContents?
    private var tabNumbers: [UUID: Int32] = [:]
    private var contentsIDByStoreTab: [UUID: UUID] = [:]
    private var nextTabNumber: Int32 = 1
    /// Bumped whenever the extension window's tab list changes, so the wrapper can
    /// tell whether an index it read from WebKit still names the tab Orbit meant.
    private var tabLayoutGeneration = 0
    /// One entry per Orbit window, in the order they opened.
    var extensionWindows: [WebKitExtensionWindow] = []
    var focusedExtensionWindow: WebKitExtensionWindow?
    weak var lastTabWindow: WebKitExtensionWindow?
    var nextExtensionWindowNumber = 1
    /// The window an Orbit window's tabs were created for, known before the tab has a delegate.
    weak var registeringEnvironment: AppEnvironment?
    var environmentHintsByTab: [UUID: WeakEnvironment] = [:]
    private var tabsClosingWithWindow: Set<UUID> = []
    var pendingTabMoves: [UUID: PendingTabMove] = [:]
    private var contentBlocker: ContentBlocker?
    let contentBlocking = WebKitContentBlocking()
    private var downloadObservers: [NSObjectProtocol] = []
    private var extensionPages: [WebKitWebContents] = []
    /// Web views the extensions own, with the owning extension's name: its pages, background page and offscreen document.
    var extensionWebViews: [(name: String, webView: WKWebView)] {
        var views: [(name: String, webView: WKWebView)] = []
        for page in extensionPages where !page.isClosed {
            if let record = page.webView.url.flatMap({ extensionRecord(for: $0) }) { views.append((record.extension.name, page.webView)) }
        }
        for record in loaded.values {
            if let background = record.context.orbitBackgroundWebView { views.append((record.extension.name, background)) }
            if let offscreen = services.system.offscreenWebView(for: record.extension.id) { views.append((record.extension.name, offscreen)) }
        }
        return views
    }
    /// Orbit's own Chrome behaviour on top of WebKit: permissions, lifecycle, event delivery, native messaging.
    private(set) lazy var services: WebKitExtensionServices = {
        let directory = EngineStorageDirectory.resolvedDirectory(for: storage)
            .appendingPathComponent("ExtensionState", isDirectory: true)
        let services = WebKitExtensionServices(stateDirectory: directory)
        services.engine = self
        return services
    }()
    private let navigationEventBridge = WebKitNavigationEventBridge()
    private let webRequestSocketProbe = WebKitWebRequestSocketProbe()
    let extensionController = WKWebExtensionController()
    /// The window the most recent tab was registered in, else the first window.
    var extensionWindow: WebKitExtensionWindow {
        if let lastTabWindow, extensionWindows.contains(where: { $0 === lastTabWindow }) { return lastTabWindow }
        return primaryExtensionWindow()
    }
    private let schemeHandler = OrbitSchemeHandler()
    private let chromeExtensionResources = ChromeExtensionSchemeHandler()
    private let pageResourceBridge = ChromeExtensionPageResourceBridge()

    init(storage: EngineStorage) {
        self.storage = storage
        super.init()
        chromeExtensionResources.engine = self
        pageResourceBridge.engine = self
        navigationEventBridge.engine = self
        webRequestSocketProbe.engine = self
        extensionController.delegate = self
        observeDownloadEvents()
    }

    private func observeDownloadEvents() {
        let center = NotificationCenter.default
        downloadObservers.append(center.addObserver(forName: .orbitDownloadCreated, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let item = note.userInfo?["item"] as? DownloadItem else { return }
                self?.broadcastChromeEvent(namespace: "downloads", event: "onCreated", payload: ChromeExtensionAPI.extensionDownloadObject(item))
            }
        })
        downloadObservers.append(center.addObserver(forName: .orbitDownloadChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let delta = note.userInfo?["delta"] else { return }
                self?.broadcastChromeEvent(namespace: "downloads", event: "onChanged", payload: delta)
            }
        })
        downloadObservers.append(center.addObserver(forName: .orbitDownloadErased, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let id = note.userInfo?["id"] else { return }
                self?.broadcastChromeEvent(namespace: "downloads", event: "onErased", payload: id)
            }
        })
        downloadObservers.append(center.addObserver(forName: .orbitBookmarkCreated, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let id = note.userInfo?["id"] as? String ?? ""
                let node = note.userInfo?["node"] ?? [:]
                self?.broadcastChromeEvent(namespace: "bookmarks", event: "onCreated", args: [id, node])
            }
        })
        downloadObservers.append(center.addObserver(forName: .orbitBookmarkRemoved, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let id = note.userInfo?["id"] as? String ?? ""
                let info = note.userInfo?["info"] ?? [:]
                self?.broadcastChromeEvent(namespace: "bookmarks", event: "onRemoved", args: [id, info])
            }
        })
        downloadObservers.append(center.addObserver(forName: .orbitBookmarkChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let id = note.userInfo?["id"] as? String ?? ""
                let info = note.userInfo?["info"] ?? [:]
                self?.broadcastChromeEvent(namespace: "bookmarks", event: "onChanged", args: [id, info])
            }
        })
        downloadObservers.append(center.addObserver(forName: .orbitBookmarkMoved, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let id = note.userInfo?["id"] as? String ?? ""
                let info = note.userInfo?["info"] ?? [:]
                self?.broadcastChromeEvent(namespace: "bookmarks", event: "onMoved", args: [id, info])
            }
        })
    }

    /// Delivered only to extensions holding the namespace's permission, never to every port.
    private func broadcastChromeEvent(namespace: String, event: String, payload: Any? = nil, args: [Any]? = nil) {
        let arguments = args ?? [payload ?? NSNull()]
        services.broadcast(namespace: namespace, event: event, args: arguments, permission: namespace)
    }

    /// Extension pages hear Orbit's events in their own world as well as on their port; the wrapper drops the repeat.
    func deliverChromeEventToExtensionPages(_ message: [String: Any], extensionID: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = """
        (function(){if(typeof globalThis.__orbitDeliverChromeEvent==="function"){globalThis.__orbitDeliverChromeEvent(\(json));}})()
        """
        for page in extensionPages where !page.isClosed {
            guard let url = page.webView.url, extensionRecord(for: url)?.extension.id == extensionID else { continue }
            page.webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    /// Hook for WebKitWebContents' provisional main-frame navigation: webNavigation.onBeforeNavigate.
    func noteMainFrameNavigationStarted(_ contents: WebKitWebContents, url: URL, navigationType: WKNavigationType, browserInitiated: Bool) {
        guard !contents.isExtensionPage, numericID(for: contents) != nil else { return }
        services.wakeForContentScripts(matching: url)
        services.navigationStarted(contents, url: url, navigationType: navigationType, browserInitiated: browserInitiated)
    }

    /// Hook for WebKitWebContents' failed main-frame navigation: webNavigation.onErrorOccurred.
    func noteMainFrameNavigationFailed(_ contents: WebKitWebContents, url: URL, error: Error) {
        guard !contents.isExtensionPage, numericID(for: contents) != nil else { return }
        services.navigationFailed(contents, url: url, error: error)
    }

    /// Hook for WebKitWebContents' authentication challenges: extensions holding
    /// webRequestAuthProvider answer first. `nil` means none did, so WebKit's default applies.
    func extensionAuthenticationDecision(
        for challenge: URLAuthenticationChallenge,
        in contents: WebKitWebContents
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
        guard !contents.isExtensionPage else { return nil }
        return await services.authenticationDecision(for: challenge, in: contents)
    }

    fileprivate func receiveWebRequestSocket(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let contents = openTabs.first(where: { $0.webView === message.webView }),
              !contents.isExtensionPage,
              let kind = body["kind"] as? String,
              let type = body["type"] as? String,
              type == "websocket" || type == "webtransport",
              let urlString = body["url"] as? String,
              let url = URL(string: urlString),
              let rawID = body["id"]
        else { return }
        let requestID = "\(contents.id.uuidString)-\(rawID)"
        services.reportSocketWebRequest(kind: kind, requestID: requestID, url: url, type: type, contents: contents)
    }

    fileprivate func receiveNavigationMessage(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let contents = openTabs.first(where: { $0.webView === message.webView }),
              !contents.isExtensionPage
        else { return }
        services.navigationDocumentEvent(contents, body: body)
    }

    func webAccessibleFile(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "chrome-extension",
              let host = url.host?.lowercased(),
              let directory = loaded[host]?.extension.directory
        else { return nil }
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.isEmpty, !relative.contains(".."),
              Self.resourceIsWebAccessible(relative, directory: directory)
        else { return nil }
        let file = directory.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return file
    }

    /// What the chrome-extension scheme serves for a request, per Chrome: web_accessible_resources (and its
    /// `matches`) gates what a web page may load; the extension's own documents may load any of its files.
    func extensionResourceFile(for url: URL, initiator: URL?) -> URL? {
        guard url.scheme?.lowercased() == "chrome-extension",
              let host = url.host?.lowercased(),
              let directory = loaded[host]?.extension.directory
        else { return nil }
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.isEmpty, !relative.contains("..") else { return nil }
        let file = directory.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        guard let initiator else {
            return Self.resourceIsWebAccessible(relative, directory: directory) ? file : nil
        }
        if let record = extensionRecord(for: initiator), record.extension.id == host { return file }
        return permitsWebInitiatedNavigation(to: url, from: initiator) ? file : nil
    }

    private static func resourceIsWebAccessible(_ relative: String, directory: URL) -> Bool {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let patterns: [String]
        if let objects = manifest["web_accessible_resources"] as? [[String: Any]] {
            patterns = objects.flatMap { $0["resources"] as? [String] ?? [] }
        } else {
            patterns = manifest["web_accessible_resources"] as? [String] ?? []
        }
        return patterns.contains { pattern in
            pattern == relative || (pattern.hasSuffix("/*") && relative.hasPrefix(String(pattern.dropLast(1))))
        }
    }

    /// Chrome's ExtensionNavigationThrottle for WebKitWebContents' main-frame policy decision: a web
    /// page may open an extension page only if web_accessible_resources lists it for that page's origin.
    func permitsWebInitiatedNavigation(to url: URL, from source: URL?) -> Bool {
        guard let record = extensionRecord(for: url) else { return true }
        guard let source, let scheme = source.scheme?.lowercased() else { return true }
        if scheme == "chrome-extension" || scheme == "webkit-extension" {
            return extensionRecord(for: source)?.extension.id == record.extension.id
        }
        if scheme == "about", source.absoluteString == "about:blank" { return true }
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.isEmpty, !relative.contains("..") else { return false }
        let manifestURL = record.extension.directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        func listed(_ resources: [String]) -> Bool {
            resources.contains { resource in
                let pattern = resource.hasPrefix("/") ? String(resource.dropFirst()) : resource
                if pattern == relative { return true }
                guard pattern.contains("*") else { return false }
                let expression = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
                return relative.range(of: expression, options: .regularExpression) != nil
            }
        }
        if let entries = manifest["web_accessible_resources"] as? [[String: Any]] {
            return entries.contains { entry in
                guard listed(entry["resources"] as? [String] ?? []) else { return false }
                let matches = (entry["matches"] as? [String] ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
                return matches.contains { $0.matches(source) }
            }
        }
        return listed(manifest["web_accessible_resources"] as? [String] ?? [])
    }

    var isMigratingChromiumSiteData: Bool { chromiumSiteDataMigrationInFlight }

    /// Returns once the Chromium profile has been copied, or immediately when there is nothing to copy.
    /// The first page load waits on this so a migrated login is present for that load.
    func preparePersistentSiteData() async {
        await chromiumSiteDataMigration?.value
    }

    func start() throws {
        scheduleChromiumProfileMigrationIfNeeded()
        if let directory = EngineStorageDirectory.directory(for: storage) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("webkit-profile")
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data("webkit".utf8).write(to: marker)
            }
            scheduleImportedLocalStorageInstall(in: directory)
        }
        services.startObserving()
        focusExtensionWindow(primaryExtensionWindow())
        ExtensionCommandRegistry.shared.dispatch = { [weak self] extensionID, name in
            self?.performCommand(extensionID: extensionID, name: name) ?? false
        }
    }

    /// Production only. A development or test run must not read the real Chromium profile or prompt for its key.
    private func scheduleChromiumProfileMigrationIfNeeded() {
        guard storage == .persistent, OrbitRuntimeScope.current.isProduction else { return }
        guard let discovery = ChromiumProfileMigration.discover(userDataDirectory: OrbitDataRoot.production.url) else { return }
        chromiumSiteDataMigrationInFlight = true
        chromiumSiteDataMigration = Task { @MainActor [weak self] in
            await self?.migrateChromiumProfile(discovery)
            self?.chromiumSiteDataMigrationInFlight = false
        }
    }

    private func migrateChromiumProfile(_ discovery: ChromiumProfileMigration.Discovery) async {
        guard acceptsChromiumMigration else { return }

        var cookieKeyError: ChromiumProfileMigration.KeychainError?
        var cookieKey: Data?
        if discovery.cookiesDatabase != nil {
            do {
                cookieKey = try ArcCookieDecryptor.derivedKey(fromPassword: try ChromiumProfileMigration.keychainPassword())
            } catch let error as ChromiumProfileMigration.KeychainError {
                cookieKeyError = error
            } catch {
                cookieKeyError = .unavailable(OSStatus(errSecParam))
            }
        }

        let localStorageDirectory = discovery.localStorageDirectory
        let cookiesDatabase = discovery.cookiesDatabase
        let keyForRead = cookieKey
        async let storedScript: ChromiumProfileMigration.LocalStorageImport? = Task.detached(priority: .userInitiated) {
            guard let localStorageDirectory else { return nil }
            return ChromiumProfileMigration.localStorageImport(in: localStorageDirectory)
        }.value
        async let storedJar: ArcCookieJar? = Task.detached(priority: .userInitiated) { () throws -> ArcCookieJar? in
            guard let cookiesDatabase, let keyForRead else { return nil }
            return try ChromiumProfileMigration.readJar(cookiesDatabase: cookiesDatabase, key: keyForRead)
        }.value

        let script = await storedScript
        let jarResult: Result<ArcCookieJar?, Error>
        do {
            jarResult = .success(try await storedJar)
        } catch {
            jarResult = .failure(error)
        }
        guard acceptsChromiumMigration else { return }

        if let script {
            installImportedLocalStorageScript(script.userScript)
        }

        var cookiesAccepted = 0
        var cookiesSkipped = 0
        var cookiesFailedToDecrypt = 0
        var cookiesUnreadable = false
        var retryLater = false

        if let cookieKeyError {
            if cookieKeyError.retriesOnNextLaunch {
                engineLogger.error("chromium cookie key was not available; migration will retry on the next launch")
                retryLater = true
            } else {
                cookiesUnreadable = true
                engineLogger.error("chromium cookies cannot be decrypted: \(String(describing: cookieKeyError), privacy: .public)")
            }
        }

        switch jarResult {
        case .failure(let error):
            cookiesUnreadable = true
            engineLogger.error("could not read the chromium cookie jar: \(String(describing: error), privacy: .public)")
        case .success(let jar):
            if let jar {
                cookiesFailedToDecrypt = jar.rowsFailedToDecrypt
                if jar.rowsRead > 0, jar.cookies.isEmpty, jar.rowsFailedToDecrypt == jar.rowsRead {
                    cookiesUnreadable = true
                } else if let session = defaultSession as? WebKitSession {
                    let existing = await cookieIdentities(in: session)
                    guard acceptsChromiumMigration else { return }
                    let importable = ChromiumProfileMigration.importableCookies(jar.cookies)
                    let incoming = ChromiumProfileMigration.cookiesToInstall(jar.cookies, alreadyPresent: existing)
                    cookiesSkipped = importable.count - incoming.count
                    cookiesAccepted = await session.setCookies(incoming.map(ArcImportCoordinator.engineCookie))
                    if !incoming.isEmpty, cookiesAccepted == 0 {
                        engineLogger.error("webkit accepted none of the chromium cookies; migration will retry on the next launch")
                        retryLater = true
                    }
                }
            }
        }

        guard acceptsChromiumMigration, !retryLater else { return }

        let record = ChromiumProfileMigration.Record(
            version: ChromiumProfileMigration.Record.currentVersion,
            migratedAt: Date(),
            cookiesAccepted: cookiesAccepted,
            cookiesSkipped: cookiesSkipped,
            cookiesFailedToDecrypt: cookiesFailedToDecrypt,
            cookiesUnreadable: cookiesUnreadable,
            localStorageOrigins: script?.originCount ?? 0,
            indexedDBOriginsLeftBehind: ChromiumProfileMigration.indexedDBOriginCount(in: discovery.indexedDBDirectory)
        )
        do {
            try ChromiumProfileMigration.write(record, to: discovery.markerURL)
        } catch {
            engineLogger.error("could not record the chromium site-data migration: \(String(describing: error), privacy: .public)")
        }
    }

    private func cookieIdentities(in session: WebKitSession) async -> Set<ChromiumProfileMigration.CookieIdentity> {
        let cookies = await session.dataStore.httpCookieStore.allCookies()
        return Set(cookies.map {
            ChromiumProfileMigration.CookieIdentity(name: $0.name, domain: $0.domain, path: $0.path)
        })
    }

    /// The database read stays off `start` so the first window can be created. The script is the same one
    /// `start` used to install synchronously: document-start, and only keys the page does not already have.
    private func scheduleImportedLocalStorageInstall(in directory: URL) {
        importedLocalStorageGeneration += 1
        let generation = importedLocalStorageGeneration
        let leveldb = directory.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
        Task { @MainActor [weak self] in
            // Synchronous file IO. On this actor it would stall the window that start() just unblocked.
            let source = await Task.detached(priority: .userInitiated) {
                WebKitEngine.importedLocalStorageSource(in: leveldb)
            }.value
            guard let self, self.importedLocalStorageGeneration == generation, let source else { return }
            self.installImportedLocalStorageScript(source)
        }
    }

    private func installImportedLocalStorageScript(_ source: String) {
        addUserScript(UserScript(
            kind: .javaScript,
            source: source,
            injectionTime: .documentStart,
            matchPatterns: ["<all_urls>"]
        ), session: defaultSession)
        // A document that committed during the read missed document-start. Filling only absent keys is the same import.
        for tab in openTabs where !tab.isClosed {
            guard let scheme = tab.webView.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            tab.webView.evaluateJavaScript(source, completionHandler: nil)
        }
    }

    /// Reads the staged Chromium database without opening it, so WebKit is not blocked and nothing is locked.
    private nonisolated static func importedLocalStorageSource(in leveldb: URL) -> String? {
        ChromiumProfileMigration.localStorageImport(in: leveldb)?.userScript
    }

    func shutdown() -> Bool {
        acceptsChromiumMigration = false
        chromiumSiteDataMigrationInFlight = false
        importedLocalStorageGeneration += 1
        let contexts = loaded.values.map(\.context)
        for id in loaded.keys { services.unregister(id, uninstalled: false) }
        loaded.removeAll()
        let tabs = openTabs
        openTabs.removeAll()
        tabLayoutGeneration += 1
        extensionPages.removeAll()
        activeTab = nil
        for tab in tabs {
            extensionController.didCloseTab(tab, windowIsClosing: true)
        }
        for window in extensionWindows { extensionController.didCloseWindow(window) }
        extensionWindows.removeAll()
        focusedExtensionWindow = nil
        environmentHintsByTab.removeAll()
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
        watchCookies(on: created)
        return created
    }

    private func watchCookies(on session: WebKitSession) {
        session.onCookieChanged = { [weak self] cookie, removed in
            self?.services.reportBrowserCookieChange(cookie, removed: removed)
        }
        session.startWatchingCookies()
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
        watchCookies(on: created)
        return created
    }

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        try makeWebContents(session: session, initialURL: initialURL, registersAsTab: true)
    }

    /// `registersAsTab` is false for an extension action popup. chrome.tabs must not list it.
    func makeWebContents(session: EngineSession, initialURL: URL?, registersAsTab: Bool) throws -> WebContents {
        let webKitSession = (session as? WebKitSession) ?? (defaultSession as! WebKitSession)
        let contents = WebKitWebContents(engine: self, session: webKitSession, initialURL: initialURL)
        if registersAsTab {
            if let registeringEnvironment { environmentHintsByTab[contents.id] = WeakEnvironment(registeringEnvironment) }
            noteTabOpened(contents)
        }
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
        compiledUserScripts[id] = nil
        for tab in openTabs { tab.reinstallScripts() }
    }

    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {
        contentBlocker = blocker
        await contentBlocking.apply(blocker)
        // Reinstalling scripts on the turn that just mutated the content controllers can
        // drop a web view that is mid-callback. The next turn is after WebKit has finished.
        let tabs = openTabs
        Task { @MainActor in
            for tab in tabs { tab.reinstallScripts() }
        }
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
        // Every failure before WebKit holds the extension is Orbit's own error, never a raw Cocoa one.
        let manifest: ChromeExtensionManifest
        do {
            manifest = try ChromeExtensionManifest.read(fromDirectory: directory)
        } catch {
            throw EngineError(code: .unknown, underlyingDescription: Self.loadFailureDescription(error))
        }
        let declaredPermissions = Set(manifest.permissions)
        let id = extensionID(for: directory, manifest: manifest)
        let webKitSession = (session as? WebKitSession) ?? (defaultSession as! WebKitSession)
        let webExtension: WKWebExtension
        do {
            try ChromeAPIWrapperScript.install(
                in: directory, configuration: services.wrapperConfiguration(forExtensionID: id, manifest: manifest)
            )
            webExtension = try await WKWebExtension(resourceBaseURL: directory)
        } catch {
            throw EngineError(code: .unknown, underlyingDescription: Self.loadFailureDescription(error))
        }
        if let error = webExtension.errors.first {
            throw EngineError(code: .unknown, underlyingDescription: error.localizedDescription)
        }
        declaredPermissionsByExtension[id] = declaredPermissions
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id
        context.isInspectable = true
        // Non-persistent stores are private tabs. Scripts inject only with this set, and WebKit
        // hides private windows and tabs from a context without it.
        context.hasAccessToPrivateData = ExtensionIncognitoAccess.isAllowed(extensionID: id, directory: directory)
        grant(webExtension, on: context)
        services.register(
            id: id, context: context, webExtension: webExtension, directory: directory,
            manifest: manifest, session: webKitSession, reason: reason
        )
        do {
            try extensionController.load(context)
            if webExtension.hasBackgroundContent {
                try await loadBackground(context)
            }
        } catch {
            declaredPermissionsByExtension[id] = nil
            services.unregister(id, uninstalled: false)
            try? extensionController.unload(context)
            if let engineError = error as? EngineError { throw engineError }
            throw EngineError(code: .unknown, underlyingDescription: Self.loadFailureDescription(error))
        }
        let loadedExtension = LoadedExtension(
            id: context.uniqueIdentifier,
            name: manifest.name,
            version: manifest.version,
            directory: directory,
            hasToolbarAction: manifest.hasToolbarAction,
            manifestVersion: manifest.manifestVersion,
            isEnabled: true,
            isActivated: true,
            idIsEngineAssigned: true
        )
        loaded[loadedExtension.id] = LoadedExtensionRecord(
            extension: loadedExtension, context: context, declaredPermissions: declaredPermissions
        )
        extensionLoadOrder.removeAll { $0 == loadedExtension.id }
        extensionLoadOrder.append(loadedExtension.id)
        if let commands = manifestCommands(in: directory) {
            ExtensionCommandRegistry.shared.register(extensionID: loadedExtension.id, manifestCommands: commands)
        }
        publishAction(for: context, tab: nil)
        return loadedExtension
    }

    private func loadBackground(_ context: WKWebExtensionContext) async throws {
        let finished = BackgroundLoad()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.loadBackgroundContent { error in
                for item in context.errors {
                    let ns = item as NSError
                    engineLogger.error("Extension error domain=\(ns.domain, privacy: .public) code=\(ns.code) \(ns.localizedDescription, privacy: .public)")
                }
                let description = error?.localizedDescription
                    ?? Self.loadFailureDescription(of: context)
                finished.finish(description.isEmpty ? nil : description, continuation)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let description = Self.loadFailureDescription(of: context)
                finished.finish(description.isEmpty ? "extension background did not finish loading" : description, continuation)
            }
        }
    }

    /// `context.errors` collects page runtime failures for the life of the context. Only the
    /// documented load codes mean the background did not start.
    private static func loadFailureDescription(of context: WKWebExtensionContext) -> String {
        context.errors.filter { error in
            let ns = error as NSError
            let isLoadFailure = ns.domain == WKWebExtensionContext.errorDomain
                && WKWebExtensionContext.Error.Code(rawValue: ns.code) != nil
            return isLoadFailure || ns.domain != WKWebExtensionContext.errorDomain
        }
        .map(\.localizedDescription).joined(separator: " | ")
    }

    func unloadExtension(id: String, session: EngineSession) {
        guard let record = loaded.removeValue(forKey: id) else { return }
        ExtensionCommandRegistry.shared.unregister(id)
        extensionLoadOrder.removeAll { $0 == id }
        declaredPermissionsByExtension[id] = nil
        services.unregister(id, uninstalled: false)
        let context = record.context
        try? extensionController.unload(context)
        // Unload finishes on a later turn. Reloading before that injects into the context that is leaving.
        let deadline = Date().addingTimeInterval(2)
        while context.isLoaded, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        extensionActionStates.remove(extensionID: id)
    }

    /// Also forgets Orbit's record of it, so installing it again is a fresh install.
    func uninstallExtension(id: String, session: EngineSession) {
        unloadExtension(id: id, session: session)
        services.unregister(id, uninstalled: true)
    }

    private static func loadFailureDescription(_ error: Error) -> String {
        if let engineError = error as? EngineError { return engineError.underlyingDescription }
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty { return described }
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? "The extension could not be loaded." : "The extension could not be loaded: \(text)"
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

    func loadedExtensionContext(id: String) -> (context: WKWebExtensionContext, baseDirectory: URL)? {
        loaded[id].map { ($0.context, $0.extension.directory) }
    }

    /// Every loaded extension in load order, for surfaces that ask each one in turn.
    func loadedExtensionContexts() -> [(id: String, name: String, context: WKWebExtensionContext)] {
        extensionLoadOrder.compactMap { id in loaded[id].map { (id, $0.extension.name, $0.context) } }
    }

    func resolvedExtensionURL(_ url: URL) -> URL {
        guard let record = extensionRecord(for: url),
              var components = URLComponents(url: record.context.baseURL, resolvingAgainstBaseURL: false)
        else { return url }
        let path = url.path.isEmpty ? "/" : (url.path.hasPrefix("/") ? url.path : "/" + url.path)
        components.path = path
        components.query = url.query
        components.fragment = url.fragment
        return components.url ?? url
    }

    func extensionWebViewConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard let configuration = extensionRecord(for: url)?.context.webViewConfiguration else { return nil }
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        ExtensionPageChrome.install(on: configuration.userContentController)
        return configuration
    }

    private func extensionRecord(for url: URL) -> LoadedExtensionRecord? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "chrome-extension" || scheme == "webkit-extension",
              let host = url.host?.lowercased()
        else { return nil }
        if let direct = loaded[host] { return direct }
        return loaded.values.first {
            $0.context.uniqueIdentifier.lowercased() == host
                || $0.context.baseURL.host?.lowercased() == host
        }
    }

    func makeConfiguration(session: WebKitSession, bridge: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = configurationByCopyingTemplate()
        // The data store and the content controller are per view. The bridge names this one tab.
        configuration.websiteDataStore = session.dataStore
        let content = WKUserContentController()
        content.add(bridge, name: "orbit")
        content.addScriptMessageHandler(pageResourceBridge, contentWorld: .page, name: "orbitExtensionResource")
        content.add(navigationEventBridge, name: WebKitNavigationEventBridge.handlerName)
        content.add(webRequestSocketProbe, name: WebKitWebRequestSocketProbe.handlerName)
        installScripts(on: content)
        contentBlocking.install(on: content)
        configuration.userContentController = content
        return configuration
    }

    /// Scheme handlers, the extension controller, and preference flags are the same for every view.
    /// A copy that still shares the template's preferences is discarded: closing developer tools writes that object.
    private func configurationByCopyingTemplate() -> WKWebViewConfiguration {
        let template = configurationTemplate
        guard let copy = template.copy() as? WKWebViewConfiguration,
              copy !== template,
              copy.preferences !== template.preferences
        else { return makeConfigurationTemplate() }
        if copy.urlSchemeHandler(forURLScheme: "orbit") == nil {
            copy.setURLSchemeHandler(schemeHandler, forURLScheme: "orbit")
        }
        if copy.urlSchemeHandler(forURLScheme: "chrome-extension") == nil {
            copy.setURLSchemeHandler(chromeExtensionResources, forURLScheme: "chrome-extension")
        }
        copy.applicationNameForUserAgent = WebKitProduct.applicationNameForUserAgent
        copy.preferences.setValue(true, forKey: "developerExtrasEnabled")
        copy.webExtensionController = extensionController
        copy.mediaTypesRequiringUserActionForPlayback = []
        WebKitMediaPreferences.enable(copy)
        return copy
    }

    private func makeConfigurationTemplate() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = WebKitProduct.applicationNameForUserAgent
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        WebKitMediaPreferences.enable(configuration)
        configuration.webExtensionController = extensionController
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "orbit")
        configuration.setURLSchemeHandler(chromeExtensionResources, forURLScheme: "chrome-extension")
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }

    func installScripts(on content: WKUserContentController) {
        content.removeAllUserScripts()
        content.addUserScript(bootstrapUserScript)
        content.addUserScript(navigationUserScript)
        content.addUserScript(webRequestSocketUserScript)
        for script in userScripts {
            content.addUserScript(compiledUserScript(for: script))
        }
    }

    private func compiledUserScript(for script: UserScript) -> WKUserScript {
        if let cached = compiledUserScripts[script.id], cached.script == script {
            return cached.compiled
        }
        let compiled = Self.userScript(script)
        compiledUserScripts[script.id] = (script, compiled)
        return compiled
    }

    func noteTabOpened(_ contents: WebKitWebContents, reusingNumber: Int32? = nil) {
        guard !contents.isExtensionPage else { return }
        guard !openTabs.contains(where: { $0 === contents }) else {
            completeTabMove(contents)
            return
        }
        // Registered before WebKit asks the tab for its window, so it never sees a window it was not told of.
        let window = extensionWindow(of: contents)
        if ownerEnvironment(of: contents) != nil {
            lastTabWindow = window
            focusIfNoWindowHasFocus(window)
        }
        openTabs.append(contents)
        if let reusingNumber {
            tabNumbers[contents.id] = reusingNumber
        } else {
            tabNumbers[contents.id] = nextTabNumber
            nextTabNumber += 1
        }
        tabLayoutGeneration += 1
        extensionController.didOpenTab(contents)
    }

    /// The popup was registered as a tab before its web view was swapped for the
    /// extension page. Close that registration so chrome.tabs stops returning it.
    func retireExtensionPage(_ contents: WebKitWebContents) {
        if openTabs.contains(where: { $0 === contents }) {
            openTabs.removeAll { $0 === contents }
            tabNumbers[contents.id] = nil
            tabLayoutGeneration += 1
            if activeTab === contents {
                activeTab = openTabs.last { !$0.isExtensionPage }
            }
            extensionController.didCloseTab(contents, windowIsClosing: false)
        }
        if !extensionPages.contains(where: { $0 === contents }) {
            extensionPages.append(contents)
        }
    }

    func noteTabClosed(_ contents: WebKitWebContents) {
        if openTabs.contains(where: { $0 === contents }) { tabLayoutGeneration += 1 }
        openTabs.removeAll { $0 === contents }
        extensionPages.removeAll { $0 === contents }
        tabNumbers[contents.id] = nil
        contentsIDByStoreTab = contentsIDByStoreTab.filter { $0.value != contents.id }
        if activeTab === contents { activeTab = openTabs.last }
        let windowIsClosing = tabsClosingWithWindow.remove(contents.id) != nil
        extensionController.didCloseTab(contents, windowIsClosing: windowIsClosing)
        environmentHintsByTab[contents.id] = nil
        for window in extensionWindows where window.lastActiveTab === contents { window.lastActiveTab = nil }
    }

    /// Called ahead of a tab's close when the whole window is going with it.
    func noteTabWillCloseWithWindow(_ contents: WebKitWebContents) {
        tabsClosingWithWindow.insert(contents.id)
    }

    func bind(storeTabID: UUID, to contents: WebKitWebContents) {
        contentsIDByStoreTab[storeTabID] = contents.id
    }

    /// A reorder, pin or close shifted indices without any one tab moving.
    func noteTabLayoutChanged() {
        tabLayoutGeneration += 1
    }

    func noteTabMoved(_ contents: WebKitWebContents, from index: Int) {
        tabLayoutGeneration += 1
        extensionController.didMoveTab(contents, from: index, in: extensionWindow(of: contents))
    }

    func setExtensionWindowState(_ state: WKWebExtension.WindowState) {
        extensionWindow.extensionWindowState = state
    }

    func setExtensionWindowState(named name: String) {
        switch name {
        case "minimized": setExtensionWindowState(.minimized)
        case "maximized": setExtensionWindowState(.maximized)
        case "fullscreen": setExtensionWindowState(.fullscreen)
        default: setExtensionWindowState(.normal)
        }
    }

    var extensionWindowStateName: String {
        switch extensionWindow.currentState {
        case .minimized: return "minimized"
        case .maximized: return "maximized"
        case .fullscreen: return "fullscreen"
        default: return "normal"
        }
    }

    func focusExtensionWindow(_ window: WebKitExtensionWindow?) {
        focusedExtensionWindow = window
        extensionController.didFocusWindow(window)
    }

    func openAdditionalExtensionWindow() -> WebKitExtensionWindow {
        let window = openExtensionWindow(environment: nil)
        window.isSynthetic = true
        return window
    }

    func closeExtensionWindow(_ window: WebKitExtensionWindow) {
        guard extensionWindows.contains(where: { $0 === window }) else { return }
        extensionWindows.removeAll { $0 === window }
        if focusedExtensionWindow === window { focusedExtensionWindow = nil }
        extensionController.didCloseWindow(window)
    }

    func noteActive(_ contents: WebKitWebContents) {
        guard !contents.isExtensionPage else { return }
        let window = extensionWindow(of: contents)
        let previous = window.lastActiveTab
        window.lastActiveTab = contents
        activeTab = contents
        if focusedExtensionWindow !== window {
            focusExtensionWindow(window)
        }
        guard previous !== contents else { return }
        extensionController.didActivateTab(contents, previousActiveTab: previous)
    }

    /// The focused window's active tab, else the one most recently activated anywhere.
    func browserActiveTab() -> WebKitWebContents? {
        let usable: (WebKitWebContents) -> Bool = { !$0.isClosed && !$0.isExtensionPage }
        if let focused = focusedExtensionWindow,
           let active = extensionActiveTab(in: focused) as? WebKitWebContents,
           usable(active) {
            return active
        }
        if let activeTab, usable(activeTab) { return activeTab }
        if let focused = focusedExtensionWindow,
           let tab = extensionTabs(in: focused).compactMap({ $0 as? WebKitWebContents }).last(where: usable) {
            return tab
        }
        return openTabs.last(where: usable)
    }

    func numericID(for tabID: UUID) -> Int32? {
        if let number = tabNumbers[tabID] { return number }
        if let contentsID = contentsIDByStoreTab[tabID] { return tabNumbers[contentsID] }
        return nil
    }

    /// Orbit's own tab number. Extensions never see it: at the JS boundary the
    /// wrapper swaps it for the id WebKit gave the tab in that extension's context.
    func numericID(for contents: WebKitWebContents) -> Int32? {
        tabNumbers[contents.id]
    }

    /// Every tab WebKit reports, across all extension windows.
    var extensionWindowTabs: [WebKitWebContents] {
        openTabs.filter { !$0.isExtensionPage }
    }

    /// Names a tab by its place in its extension window; the wrapper resolves it to a
    /// WebKit tab id with browser.tabs and checks `generation` to catch a layout change.
    func extensionTabReference(for contents: WebKitWebContents) -> [String: Any]? {
        let window = extensionWindow(of: contents)
        guard let number = tabNumbers[contents.id],
              let index = extensionTabs(in: window).firstIndex(where: { $0 === contents })
        else { return nil }
        var reference: [String: Any] = [
            "number": Int(number), "index": index, "generation": tabLayoutGeneration, "window": window.number,
        ]
        if let url = contents.navigationState.url ?? contents.webView.url {
            reference["url"] = url.absoluteString
        }
        return reference
    }

    func extensionTabReference(forTabID tabID: UUID) -> [String: Any]? {
        let contentsID: UUID? = tabNumbers[tabID] != nil ? tabID : contentsIDByStoreTab[tabID]
        guard let contentsID, let contents = openTabs.first(where: { $0.id == contentsID }) else { return nil }
        return extensionTabReference(for: contents)
    }

    /// A tabId argument: the wrapper replaces it with the WebKit id, or -1 when unresolved.
    func extensionTabIDValue(for contents: WebKitWebContents) -> Any {
        guard let reference = extensionTabReference(for: contents) else { return -1 }
        return ["__orbitTabID": reference]
    }

    /// Answers the wrapper's tab-id translation calls.
    private func tabReferenceReply(method: String, args: [Any]) -> Result<Any, Error> {
        switch method {
        case "pending":
            let rows: [[String: String]] = openTabs.compactMap { tab in
                guard tab.navigationState.isLoading,
                      let pending = tab.inFlightURL(),
                      let committed = tab.committedDocumentURL(),
                      pending != committed
                else { return nil }
                return ["url": committed.absoluteString, "pending": pending.absoluteString]
            }
            return .success(rows)
        case "locate":
            var reply: [String: Any] = ["generation": tabLayoutGeneration]
            if let number = Self.int32Argument(args.first),
               let contents = openTabs.first(where: { tabNumbers[$0.id] == number }),
               let reference = extensionTabReference(for: contents) {
                reply["reference"] = reference
            }
            return .success(reply)
        case "numberForURL":
            var found: [String: Any] = ["generation": tabLayoutGeneration]
            let url = args.first as? String ?? ""
            let matches = openTabs.filter {
                let current = ($0.navigationState.url ?? $0.webView.url)?.absoluteString ?? ""
                return !url.isEmpty && current == url
            }
            if matches.count == 1, let contents = matches.first, let number = tabNumbers[contents.id] {
                found["number"] = Int(number)
                found["window"] = extensionWindow(of: contents).number
            }
            return .success(found)
        case "active":
            var active: [String: Any] = ["generation": tabLayoutGeneration]
            if let contents = browserActiveTab(), let number = tabNumbers[contents.id] {
                active["number"] = Int(number)
                active["url"] = (contents.navigationState.url ?? contents.webView.url)?.absoluteString ?? ""
                active["window"] = extensionWindow(of: contents).number
            }
            return .success(active)
        case "numberAt":
            guard let index = (args.first as? NSNumber)?.intValue,
                  let generation = (args.dropFirst().first as? NSNumber)?.intValue
            else { return .failure(ChromeExtensionAPIError("numberAt needs an index and a generation.")) }
            var reply: [String: Any] = ["generation": tabLayoutGeneration]
            guard generation == tabLayoutGeneration else {
                reply["stale"] = true
                return .success(reply)
            }
            // The window the wrapper learned for this tab's windowId; without one, every window is a candidate.
            let knownWindow = ((args.dropFirst(3).first as? NSNumber)?.intValue).flatMap { $0 >= 0 ? $0 : nil }
            let windows = knownWindow.map { number in extensionWindows.filter { $0.number == number } } ?? extensionWindows
            let expected = (args.dropFirst(2).first as? String).flatMap { $0.isEmpty ? nil : $0 }
            var matches: [(window: WebKitExtensionWindow, tab: WebKitWebContents, number: Int32)] = []
            var sawStaleURL = false
            for window in windows {
                let tabs = extensionTabs(in: window)
                guard tabs.indices.contains(index), let number = tabNumbers[tabs[index].id] else { continue }
                // A navigation between browser.tabs.get and this call leaves the index valid but the URL behind.
                if let expected, let actual = (tabs[index].navigationState.url ?? tabs[index].webView.url)?.absoluteString,
                   actual != expected {
                    sawStaleURL = true
                    continue
                }
                matches.append((window, tabs[index], number))
            }
            guard matches.count == 1, let match = matches.first else {
                // Two windows with the same URL at one index cannot be told apart from here.
                if matches.count > 1 || sawStaleURL { reply["stale"] = true }
                return .success(reply)
            }
            reply["number"] = Int(match.number)
            reply["window"] = match.window.number
            return .success(reply)
        default:
            return .failure(ChromeExtensionAPIError("Unknown orbitTabs.\(method)"))
        }
    }

    func storeTabID(forNumericID id: Int32) -> UUID? {
        guard let contentsID = tabNumbers.first(where: { $0.value == id })?.key else { return nil }
        if let storeID = contentsIDByStoreTab.first(where: { $0.value == contentsID })?.key {
            return storeID
        }
        return contentsID
    }

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

    private func reloadRequestedByExtension(_ args: [Any]) {
        let tabID: Int32?
        let bypass: Bool
        if let number = Self.int32Argument(args.first), !(args.first is [String: Any]) {
            tabID = number
            bypass = (args.dropFirst().first as? [String: Any])?["bypassCache"] as? Bool ?? false
        } else if let props = args.first as? [String: Any] {
            tabID = nil
            bypass = props["bypassCache"] as? Bool ?? false
        } else {
            tabID = nil
            bypass = false
        }
        let target: WebKitWebContents?
        if let tabID {
            target = openTabs.first { !$0.isExtensionPage && numericID(for: $0) == tabID }
        } else {
            target = browserActiveTab()
        }
        target?.reload(ignoringCache: bypass)
    }

    func extensionResourceReply(for urlString: String, extensionID: String? = nil) -> [String: String] {
        guard let url = URL(string: urlString) else { return ["error": "bad url"] }
        let file: URL?
        if url.scheme?.lowercased() == "chrome-extension" {
            file = webAccessibleFile(for: url)
        } else if let extensionID, let directory = loaded[extensionID]?.extension.directory {
            let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            guard !relative.isEmpty, !relative.contains("..") else { return ["error": "bad path"] }
            file = directory.appendingPathComponent(relative)
        } else {
            file = nil
        }
        guard let file, let data = try? Data(contentsOf: file) else { return ["error": "not found"] }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "js": mime = "text/javascript"
        case "json": mime = "application/json"
        case "html": mime = "text/html"
        default: mime = "application/octet-stream"
        }
        return ["body": data.base64EncodedString(), "mime": mime]
    }

    private static func int32Argument(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber { return number.int32Value }
        if let number = value as? Int { return Int32(number) }
        return nil
    }

    func performChromeAPI(extensionID: String, namespace: String, method: String, args: [Any]) async -> Result<Any, Error> {
        if namespace == "tabs", method == "reload" {
            reloadRequestedByExtension(args)
            return .success(NSNull())
        }
        if namespace == "orbitTabs" {
            return tabReferenceReply(method: method, args: args)
        }
        if namespace == "runtime", method == "getResource" {
            return .success(extensionResourceReply(for: args.first as? String ?? "", extensionID: extensionID))
        }
        do {
            if let handled = try await performOrbitServiceCall(extensionID: extensionID, namespace: namespace, method: method, args: args) {
                return .success(handled)
            }
        } catch {
            return .failure(error)
        }
        ChromeExtensionAPI.remember(engine: self)
        let held = services.entry(extensionID) != nil
            ? services.grantedPermissions(extensionID)
            : (loaded[extensionID]?.declaredPermissions ?? declaredPermissionsByExtension[extensionID] ?? [])
        return await ChromeExtensionAPI.invoke(
            namespace: namespace,
            method: method,
            args: args,
            declaredPermissions: held,
            extensionID: extensionID,
            session: services.entry(extensionID)?.session,
            engine: self
        )
    }

    /// The wrapper's calls into Orbit-owned behaviour; `nil` leaves the call to ChromeExtensionAPI.
    private func performOrbitServiceCall(extensionID: String, namespace: String, method: String, args: [Any]) async throws -> Any? {
        switch (namespace, method) {
        case ("orbit", "raise"):
            // The wrapper's own failures reach runtime.lastError by failing a real reply.
            throw ChromeExtensionAPIError(args.first as? String ?? "Unknown error.")
        case ("permissions", "getAll"):
            return try services.permissionsGetAll(extensionID)
        case ("permissions", "contains"):
            return try services.permissionsContains(extensionID, details: args.first)
        case ("permissions", "request"):
            return try await services.permissionsRequest(extensionID, details: args.first)
        case ("permissions", "remove"):
            return try services.permissionsRemove(extensionID, details: args.first)
        case ("runtime", "takeLifecycleEvents"):
            return services.takeLifecycleEvents(extensionID)
        case ("webRequest", "registerAuthListener"):
            services.registerAuthListener(extensionID)
            return NSNull()
        case ("webRequest", "unregisterAuthListener"):
            services.unregisterAuthListener(extensionID, remaining: (args.first as? NSNumber)?.intValue ?? 0)
            return NSNull()
        case ("webRequest", "authResponse"):
            services.answerAuth(token: args.first as? String ?? "", response: args.dropFirst().first as? [String: Any] ?? [:])
            return NSNull()
        case ("declarativeNetRequest", "rememberRegexFilters"):
            let forget = (args.dropFirst(2).first as? [Any] ?? []).map { "\($0)" }
            services.rememberRegexFilters(
                extensionID, ruleset: args.first as? String ?? "dynamic",
                remembered: args.dropFirst().first as? [String: String] ?? [:], forget: forget
            )
            return NSNull()
        case ("declarativeNetRequest", "regexFilters"):
            return services.regexFilters(extensionID, ruleset: args.first as? String ?? "dynamic")
        case ("idle", _), ("power", _), ("offscreen", _), ("system.cpu", _), ("system.memory", _), ("system.display", _), ("system.storage", _):
            guard services.hasPermission(namespace, extensionID: extensionID) else {
                throw ChromeExtensionAPIError("Missing \(namespace) permission.")
            }
            return try await services.system.perform(namespace: namespace, method: method, args: args, extensionID: extensionID)
        default:
            return nil
        }
    }

    private func publishAction(for context: WKWebExtensionContext, tab: (any WKWebExtensionTab)?) {
        guard let action = context.action(for: tab) else { return }
        let id = context.uniqueIdentifier
        var state = ExtensionActionState(
            badgeText: action.badgeText,
            title: action.label,
            isEnabled: action.isEnabled
        )
        if let color = ChromeExtensionAPI.storedBadgeBackgroundColor(for: id) {
            state.badgeBackgroundColor = color
        }
        // WebKit's action object does not see badge, title, or enabled state that Orbit's own action methods stored.
        if let text = ChromeExtensionAPI.storedBadgeText(for: id) {
            state.badgeText = text
        }
        if let title = ChromeExtensionAPI.storedActionTitle(for: id) {
            state.title = title
        }
        if let enabled = ChromeExtensionAPI.storedActionIsEnabled(for: id) {
            state.isEnabled = enabled
        }
        if let override = ChromeExtensionAPI.actionPopupOverride(for: id) {
            state.popupURLString = override.isEmpty ? "" : "chrome-extension://\(id)/\(override)"
        }
        if ChromeExtensionAPI.storedIconWasSet(for: id) {
            state.iconPNG = ChromeExtensionAPI.storedIconPNG(for: id)
        }
        let existing = extensionActionStates.snapshots[id]
        var perTab = existing?.perTab ?? [:]
        var defaults = existing?.defaults ?? ExtensionActionState()
        if let contents = tab as? WebKitWebContents, let number = numericID(for: contents) {
            if let text = ChromeExtensionAPI.storedBadgeText(for: id, tabID: number) {
                state.badgeText = text
            }
            perTab[number] = state
        } else {
            defaults = state
        }
        extensionActionStates.apply(ExtensionActionSnapshot(extensionID: id, defaults: defaults, perTab: perTab))
    }

    @discardableResult
    private func performCommand(extensionID: String, name: String) -> Bool {
        let registered = ExtensionCommandRegistry.shared.commands(forExtension: extensionID)
        guard let command = registered.first(where: { $0.name == name }), command.isActive else { return false }
        if command.isAction {
            return ExtensionCommandRegistry.shared.environmentForActivation.activateExtensionAction(extensionID)
        }
        // A shortcut belongs to one extension; no other may hear it.
        services.deliver(namespace: "commands", event: "onCommand", args: [name, commandTabArgument()], to: extensionID)
        return true
    }

    private func commandTabArgument() -> [String: Any] {
        let environment = ExtensionCommandRegistry.shared.environmentForActivation
        guard let tabID = environment.activeTabID,
              let contents = environment.webContents[tabID] as? WebKitWebContents
        else { return [:] }
        var tab: [String: Any] = [
            "id": -1,
            "url": contents.navigationState.url?.absoluteString ?? "",
            "title": contents.navigationState.title,
            "active": true,
        ]
        if let reference = extensionTabReference(for: contents) ?? extensionTabReference(forTabID: tabID) {
            tab["__orbitTab"] = reference
        }
        return tab
    }

    private func manifestCommands(in directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return manifest["commands"] as? [String: Any]
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func userScript(_ script: UserScript) -> WKUserScript {
        let source: String
        if script.kind == .stylesheet {
            let encoded = JavaScriptLiteral.string(script.source)
            let injection = "(function(){var style=document.createElement('style');style.textContent=\(encoded);(document.head||document.documentElement).appendChild(style);})();"
            source = Self.scoped(injection, patterns: script.matchPatterns)
        } else {
            source = Self.scoped(script.source, patterns: script.matchPatterns)
        }
        return WKUserScript(
            source: source,
            injectionTime: script.injectionTime == .documentStart ? .atDocumentStart : .atDocumentEnd,
            forMainFrameOnly: !script.allFrames
        )
    }

    // A host-limited script must not run on every page.
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
    (function () {
      // High 10, High 4:2:2 and High 4:4:4 have no VideoToolbox profile. Advertising them
      // makes a player start a stream that dies at the first frame.
      function unsupported(type) {
        return /avc1\\.(6e|7a|f4)/i.test(String(type || ""));
      }
      var canPlay = HTMLMediaElement.prototype.canPlayType;
      HTMLMediaElement.prototype.canPlayType = function (type) {
        if (unsupported(type)) { return ""; }
        return canPlay.call(this, type);
      };
      if (window.MediaSource && typeof MediaSource.isTypeSupported === "function") {
        var mse = MediaSource.isTypeSupported.bind(MediaSource);
        MediaSource.isTypeSupported = function (type) {
          if (unsupported(type)) { return false; }
          return mse(type);
        };
      }
      // WebKit drops HTMLElement.click() when the element has no box. Chrome still runs the listeners.
      (function () {
        var proto = HTMLElement.prototype;
        if (!proto.click || proto.click.__orbitWrapped) { return; }
        var nativeClick = proto.click;
        function click() {
          if (this.getClientRects && this.getClientRects().length === 0) {
            this.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view: window }));
            return;
          }
          return nativeClick.call(this);
        }
        click.__orbitWrapped = true;
        proto.click = click;
      })();
      // WebKit leaves the [SecureContext] WebCodecs constructors on an opaque origin.
      if (!window.isSecureContext) {
        ["AudioDecoder", "AudioEncoder", "VideoDecoder", "VideoEncoder"].forEach(function (name) {
          try {
            Object.defineProperty(window, name, { configurable: true, writable: true, value: undefined });
          } catch (e) {}
        });
      }
    })();
    window.__orbitPostMessage = function(channel, json) {
      try { window.webkit.messageHandlers.orbit.postMessage({channel: channel, json: json}); } catch (e) {}
    };
    (function () {
      var proto = Document.prototype;
      var desc = Object.getOwnPropertyDescriptor(proto, "cookie");
      if (!desc || typeof desc.set !== "function" || desc.set.__orbitWrapped) { return; }
      var nativeSet = desc.set;
      function set(value) {
        nativeSet.call(this, value);
        try {
          window.__orbitPostMessage("cookie", JSON.stringify({ cookie: String(value), url: location.href }));
        } catch (e) {}
      }
      set.__orbitWrapped = true;
      try {
        Object.defineProperty(proto, "cookie", { configurable: true, enumerable: desc.enumerable, get: desc.get, set: set });
      } catch (e) {}
    })();
    (function () {
      function isExtension(url) {
        return typeof url === "string" && url.indexOf("chrome-extension://") === 0;
      }
      function decode(payload) {
        if (!payload || payload.error) { throw new Error(payload && payload.error || "missing"); }
        var binary = atob(payload.body || "");
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
        return new TextDecoder().decode(bytes);
      }
      function load(url) {
        return window.webkit.messageHandlers.orbitExtensionResource.postMessage(url).then(decode);
      }
      var origFetch = window.fetch;
      if (typeof origFetch === "function") {
        window.fetch = function (input, init) {
          var url = typeof input === "string" ? input : (input && input.url);
          if (!isExtension(url)) { return origFetch.apply(this, arguments); }
          return load(String(url)).then(function (text) {
            return new Response(text, { status: 200, headers: { "Content-Type": "text/javascript" } });
          });
        };
      }
      var origSet = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (this instanceof HTMLScriptElement && String(name).toLowerCase() === "src" && isExtension(value)) {
          var el = this;
          load(String(value)).then(function (text) {
            var blob = new Blob([text], { type: "text/javascript" });
            origSet.call(el, "src", URL.createObjectURL(blob));
          }, function () { origSet.call(el, name, value); });
          return;
        }
        return origSet.apply(this, arguments);
      };
    })();
    """

    private final class BackgroundLoad: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func finish(_ description: String?, _ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            let already = resumed
            resumed = true
            lock.unlock()
            guard !already else { return }
            if let description, !description.isEmpty {
                continuation.resume(throwing: EngineError(code: .unknown, underlyingDescription: description))
            } else {
                continuation.resume()
            }
        }
    }

    private struct LoadedExtensionRecord {
        var `extension`: LoadedExtension
        var context: WKWebExtensionContext
        var declaredPermissions: Set<String>
    }
}

extension WebKitEngine: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        discardClosedExtensionWindows()
        _ = primaryExtensionWindow()
        return extensionWindows
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        // With nothing focused, WebKit still wants the last focused window, as chrome.windows.getLastFocused does.
        focusedExtensionWindow ?? extensionWindow
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
        let extensionID = extensionContext.uniqueIdentifier
        // Orbit's reserved id carries only the wrapper's calls; every other id is a real native host.
        guard applicationIdentifier == WebKitExtensionTransport.applicationIdentifier,
              let object = message as? [String: Any], object["orbitChromeAPI"] as? Bool == true
        else {
            guard services.hasPermission("nativeMessaging", extensionID: extensionID) else {
                replyHandler(nil, ChromeExtensionAPIError(NativeMessagingHostError.forbidden.message))
                return
            }
            services.nativeMessaging.sendMessage(
                message, to: applicationIdentifier ?? "", extensionID: extensionID, replyHandler: replyHandler
            )
            return
        }
        let namespace = object["namespace"] as? String ?? ""
        let method = object["method"] as? String ?? ""
        let args = object["args"] as? [Any] ?? []
        Task { @MainActor in
            let result = await performChromeAPI(extensionID: extensionID, namespace: namespace, method: method, args: args)
            switch result {
            case .success(let value): replyHandler(value, nil)
            case .failure(let error):
                // orbit.raise must fail the native reply so WebKit sets lastError. Other failures stay Orbit's text.
                if namespace == "orbit", method == "raise" {
                    replyHandler(nil, error)
                    return
                }
                let message = (error as? ChromeExtensionAPIError)?.message ?? error.localizedDescription
                replyHandler(["__orbitError": message], nil)
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        openExtensionTab(using: configuration, completionHandler: completionHandler)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let id = extensionContext.uniqueIdentifier
        if port.applicationIdentifier == WebKitExtensionTransport.applicationIdentifier {
            services.attachEventPort(port, extensionID: id)
            completionHandler(nil)
            return
        }
        guard services.hasPermission("nativeMessaging", extensionID: id) else {
            completionHandler(ChromeExtensionAPIError(NativeMessagingHostError.forbidden.message))
            return
        }
        services.nativeMessaging.connect(port, extensionID: id, completionHandler: completionHandler)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        Task { @MainActor in
            completionHandler(await services.promptForPermissions(permissions, context: extensionContext), nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        Task { @MainActor in
            completionHandler(await services.promptForMatchPatterns(matchPatterns, context: extensionContext), nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        Task { @MainActor in
            completionHandler(await services.promptForURLs(urls, context: extensionContext), nil)
        }
    }

    /// chrome.runtime.openOptionsPage: the same options URL Orbit's own options controls open, in a tab of
    /// the frontmost window, reusing one already showing it as Chrome does.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let entry = services.entry(for: extensionContext),
              let url = ExtensionActionPopupSupport.optionsPageURL(
                extensionID: entry.id,
                isEnabled: true,
                manifestKey: entry.manifest.key,
                optionsPagePath: entry.manifest.optionsPagePath,
                sessionIsPersistent: entry.session.isPersistent,
                directory: entry.directory,
                idIsEngineAssigned: true
              )
        else {
            completionHandler(ChromeExtensionAPIError("Could not create an options page."))
            return
        }
        let environment = AppEnvironment.frontmost
        if let existing = environment.state.tabs.values.first(where: { $0.url == url }) {
            environment.activateTab(existing.id)
            completionHandler(nil)
            return
        }
        guard let spaceID = environment.activeSpace?.id else {
            completionHandler(ChromeExtensionAPIError("Could not create an options page."))
            return
        }
        _ = environment.openTab(url: url, in: spaceID)
        completionHandler(nil)
    }
}

/// Orbit's isolated-world observer of each tab's main-frame document: commit, DOMContentLoaded, load
/// and same-document navigations, as the document itself reports them.
final class WebKitNavigationEventBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "orbitNavigation"
    weak var engine: WebKitEngine?

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static let source = """
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) { return; }
      function post(kind, extra) {
        var body = { kind: kind, url: location.href };
        if (extra) { Object.keys(extra).forEach(function (key) { body[key] = extra[key]; }); }
        try { handler.postMessage(body); } catch (e) {}
      }
      var entries = performance.getEntriesByType ? performance.getEntriesByType("navigation") : [];
      post("commit", { navigationType: entries.length ? entries[0].type : "navigate" });
      document.addEventListener("DOMContentLoaded", function () { post("domContentLoaded"); }, { once: true });
      window.addEventListener("load", function () { post("load"); }, { once: true });
      window.addEventListener("pageshow", function (event) {
        if (!event.persisted) { return; }
        post("commit", { navigationType: "back_forward" });
        post("domContentLoaded");
        post("load");
      });
      var lastURL = location.href;
      function sameDocument() {
        var next = location.href;
        if (next === lastURL) { return; }
        var fragmentOnly = next.split("#")[0] === lastURL.split("#")[0];
        lastURL = next;
        post(fragmentOnly ? "fragment" : "historyState");
      }
      if (window.navigation && typeof window.navigation.addEventListener === "function") {
        window.navigation.addEventListener("currententrychange", sameDocument);
      } else {
        window.addEventListener("hashchange", sameDocument);
        window.addEventListener("popstate", sameDocument);
      }
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            engine?.receiveNavigationMessage(message)
        }
    }
}

/// Page-world wrapper around `WebSocket` and `WebTransport`. WebKit's webRequest does not
/// report either handshake, so this posts them to the extension listeners that may see the URL.
final class WebKitWebRequestSocketProbe: NSObject, WKScriptMessageHandler {
    static let handlerName = "orbitWebRequestSocket"
    weak var engine: WebKitEngine?

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static let source = """
    (function () {
      if (window.__orbitWebRequestSocketProbe) { return; }
      window.__orbitWebRequestSocketProbe = true;
      if (location.protocol !== "http:" && location.protocol !== "https:") { return; }
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) { return; }
      var nextID = 1;
      function post(kind, id, url, type) {
        try { handler.postMessage({ kind: kind, id: id, url: String(url), type: type }); } catch (e) {}
      }
      function absoluteWebSocket(url) {
        try {
          var resolved = new URL(url, location.href);
          if (resolved.protocol === "http:") { resolved.protocol = "ws:"; }
          else if (resolved.protocol === "https:") { resolved.protocol = "wss:"; }
          return resolved.href;
        } catch (e) { return String(url); }
      }
      if (typeof WebSocket === "function") {
        var NativeWebSocket = WebSocket;
        function OrbitWebSocket(url, protocols) {
          var socket = protocols === undefined ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
          var id = nextID++;
          var absolute = absoluteWebSocket(url);
          var opened = false;
          post("before", id, absolute, "websocket");
          socket.addEventListener("open", function () {
            opened = true;
            post("open", id, absolute, "websocket");
          });
          socket.addEventListener("error", function () {
            if (!opened) { post("error", id, absolute, "websocket"); }
          });
          return socket;
        }
        OrbitWebSocket.prototype = NativeWebSocket.prototype;
        OrbitWebSocket.CONNECTING = NativeWebSocket.CONNECTING;
        OrbitWebSocket.OPEN = NativeWebSocket.OPEN;
        OrbitWebSocket.CLOSING = NativeWebSocket.CLOSING;
        OrbitWebSocket.CLOSED = NativeWebSocket.CLOSED;
        window.WebSocket = OrbitWebSocket;
      }
      if (typeof WebTransport === "function") {
        var NativeTransport = WebTransport;
        function OrbitWebTransport(url, options) {
          var transport = options === undefined ? new NativeTransport(url) : new NativeTransport(url, options);
          var id = nextID++;
          var absolute = String(url);
          try { absolute = new URL(url, location.href).href; } catch (e) {}
          post("before", id, absolute, "webtransport");
          if (transport.ready && typeof transport.ready.then === "function") {
            transport.ready.then(function () {
              post("open", id, absolute, "webtransport");
            }, function () {
              post("error", id, absolute, "webtransport");
            });
          }
          return transport;
        }
        OrbitWebTransport.prototype = NativeTransport.prototype;
        window.WebTransport = OrbitWebTransport;
      }
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            engine?.receiveWebRequestSocket(message)
        }
    }
}

final class ChromeExtensionPageResourceBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var engine: WebKitEngine?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let url = message.body as? String ?? ""
        let engine = engine
        Task { @MainActor in
            replyHandler(engine?.extensionResourceReply(for: url) ?? ["error": "unavailable"], nil)
        }
    }
}

final class ChromeExtensionSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var engine: WebKitEngine?
    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let token = ObjectIdentifier(urlSchemeTask)
        let requested = urlSchemeTask.request.url
        let initiator = MainActor.assumeIsolated { Self.initiatorURL(of: urlSchemeTask) }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped.contains(token) else { return }
            guard let url = requested,
                  let file = self.engine?.extensionResourceFile(for: url, initiator: initiator),
                  let data = try? Data(contentsOf: file)
            else {
                engineLogger.info("Refused chrome-extension request \(requested?.absoluteString ?? "nil", privacy: .public)")
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
                return
            }
            guard !self.stopped.contains(token) else { return }
            let mime = Self.mimeType(for: file)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime,
                "Access-Control-Allow-Origin": "*",
            ])!
            urlSchemeTask.didReceive(response)
            guard !self.stopped.contains(token) else { return }
            urlSchemeTask.didReceive(data)
            guard !self.stopped.contains(token) else { return }
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask))
    }

    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "txt": return "text/plain"
        case "wasm": return "application/wasm"
        case "xml": return "application/xml"
        default: return "application/octet-stream"
        }
    }

    // The requesting frame's origin is only exposed through this private accessor; without it the top-level page stands in.
    @MainActor
    private static func initiatorURL(of task: any WKURLSchemeTask) -> URL? {
        let selector = NSSelectorFromString("_frame")
        if let object = task as? NSObject, object.responds(to: selector),
           let frame = object.perform(selector)?.takeUnretainedValue() as? WKFrameInfo,
           !frame.securityOrigin.protocol.isEmpty,
           var components = URLComponents(url: WebKitPermissionPolicy.url(for: frame.securityOrigin), resolvingAgainstBaseURL: false),
           components.scheme != nil {
            components.path = "/"
            if let url = components.url { return url }
        }
        return task.request.mainDocumentURL
    }
}

/// Extension pages are not the background, so they do not load the chrome wrapper.
/// A hidden control's click() has no client rects, and tabs.reload must hit Orbit's tab.
private enum ExtensionPageChrome {
    private static let marker = "/* orbit-extension-page */"

    static func install(on controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        controller.addUserScript(WKUserScript(
            source: marker + "\n" + script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    private static let script = #"""
    (function () {
      // Popups do not load the background wrapper. WebKit drops click() on a display:none control; Chrome runs the listeners.
      var originalAddEventListener = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = function (type, listener, options) {
        if (type === "click" && typeof listener === "function") {
          var list = this.__orbitClickListeners || (this.__orbitClickListeners = []);
          list.push(listener);
        }
        return originalAddEventListener.apply(this, arguments);
      };
      function runClickListeners(el) {
        var list = el && el.__orbitClickListeners;
        if (!list) { return; }
        var event = new MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view: window });
        for (var i = 0; i < list.length; i++) {
          try { list[i].call(el, event); } catch (e) {}
        }
      }
      function installClick(proto) {
        if (!proto || !proto.click || proto.click.__orbitUnhides) { return; }
        var nativeClick = proto.click;
        function click() {
          var restore = [];
          if (this.getClientRects && this.getClientRects().length === 0) {
            var node = this;
            while (node && node.nodeType === 1) {
              if (getComputedStyle(node).display === "none") {
                restore.push([node, node.style.display]);
                node.style.setProperty("display", "block", "important");
              }
              node = node.parentElement;
            }
            if (document.body) { void document.body.offsetWidth; }
          }
          try {
            var result = nativeClick.call(this);
            if (restore.length) {
              runClickListeners(this);
              this.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view: window }));
            }
            return result;
          } finally {
            for (var i = 0; i < restore.length; i++) {
              restore[i][0].style.display = restore[i][1];
            }
          }
        }
        click.__orbitUnhides = true;
        try {
          Object.defineProperty(proto, "click", { configurable: true, writable: true, value: click });
        } catch (e) {
          try { proto.click = click; } catch (e2) {}
        }
      }
      if (typeof Element !== "undefined") { installClick(Element.prototype); }
      if (typeof HTMLElement !== "undefined") { installClick(HTMLElement.prototype); }
      var prototypePatched = typeof Element !== "undefined" && Element.prototype.click && Element.prototype.click.__orbitUnhides;
      if (!prototypePatched) {
        function arm(el) {
          if (!el || el.nodeType !== 1 || (el.click && el.click.__orbitUnhides)) { return; }
          var native = el.click;
          function click() {
            var restore = [];
            var node = this;
            while (node && node.nodeType === 1) {
              if (getComputedStyle(node).display === "none") {
                restore.push([node, node.style.display]);
                node.style.setProperty("display", "block", "important");
              }
              node = node.parentElement;
            }
            if (restore.length && document.body) { void document.body.offsetWidth; }
            try {
              var result = native.call(this);
              if (restore.length) {
                runClickListeners(this);
                this.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view: window }));
              }
              return result;
            } finally {
              for (var i = 0; i < restore.length; i++) { restore[i][0].style.display = restore[i][1]; }
            }
          }
          click.__orbitUnhides = true;
          try { Object.defineProperty(el, "click", { configurable: true, writable: true, value: click }); } catch (e) {}
        }
        function armTree(root) {
          if (!root || root.nodeType !== 1) { return; }
          arm(root);
          if (!root.querySelectorAll) { return; }
          var all = root.querySelectorAll("*");
          for (var i = 0; i < all.length; i++) { arm(all[i]); }
        }
        var armObserver = new MutationObserver(function (records) {
          for (var i = 0; i < records.length; i++) {
            var nodes = records[i].addedNodes;
            for (var n = 0; n < nodes.length; n++) { armTree(nodes[n]); }
          }
        });
        function startArming() {
          if (!document.documentElement) { return; }
          armObserver.observe(document.documentElement, { childList: true, subtree: true });
          armTree(document.documentElement);
        }
        if (document.documentElement) { startArming(); }
        else { document.addEventListener("DOMContentLoaded", startArming); }
      }
      var wrappedReload = function () {
        var args = Array.prototype.slice.call(arguments);
        var callback = null;
        if (args.length && typeof args[args.length - 1] === "function") { callback = args.pop(); }
        function finish() { if (typeof callback === "function") { callback(); } }
        var root = globalThis.chrome;
        try {
          root.runtime.sendMessage(
            { orbitChromeWrapper: true, namespace: "tabs", method: "reload", args: args },
            function () { finish(); }
          );
        } catch (e) { finish(); }
      };
      wrappedReload.__orbitPage = true;
      var timer = setInterval(function () {
        var root = globalThis.chrome;
        var tabs = root && root.tabs;
        if (!tabs || tabs.reload === wrappedReload) { return; }
        var hooked = false;
        try {
          Object.defineProperty(tabs, "reload", {
            configurable: true,
            enumerable: true,
            get: function () { return wrappedReload; },
            set: function () {}
          });
          hooked = tabs.reload === wrappedReload;
        } catch (e) {}
        if (!hooked) {
          try { tabs.reload = wrappedReload; hooked = tabs.reload === wrappedReload; } catch (e2) {}
        }
        if (!hooked && root.tabs === tabs) {
          try {
            root.tabs = new Proxy(tabs, {
              get: function (target, prop, receiver) {
                if (prop === "reload") { return wrappedReload; }
                return Reflect.get(target, prop, receiver);
              }
            });
          } catch (e3) {}
        }
      }, 20);
      window.addEventListener("pagehide", function () { clearInterval(timer); });
    })();
    """#
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
