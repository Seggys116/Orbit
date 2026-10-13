import AppKit
import WebKit

final class OrbitWebView: WKWebView {
    weak var menuOwner: WebKitWebContents?

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            menuOwner?.openContextMenu(with: event)
        }
    }
}

@MainActor
final class WebKitWebContents: NSObject, WebContents, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKWebExtensionTab {
    let id = UUID()
    let session: EngineSession
    weak var delegate: WebContentsDelegate?
    private(set) var navigationState = NavigationState()
    private(set) var mediaState = MediaState.idle
    private(set) var isClosed = false
    var zoomFactor: Double { webView.pageZoom }

    private let engine: WebKitEngine
    private let webKitSession: WebKitSession
    let webView: OrbitWebView
    private let scriptBridge: WebKitScriptBridge
    private var lastStatusCode = 0
    private var preferredScheme: ContentColorScheme?
    private var contentRuleList: WKContentRuleList?
    private lazy var webStorePrivateBridge = WebStorePrivateBridge()

    var view: NSView { webView }

    init(
        engine: WebKitEngine,
        session: WebKitSession,
        initialURL: URL?,
        configuration supplied: WKWebViewConfiguration? = nil,
        installBridge: Bool = true
    ) {
        self.engine = engine
        self.webKitSession = session
        self.session = session
        let bridge = WebKitScriptBridge()
        self.scriptBridge = bridge
        let configuration: WKWebViewConfiguration
        if let supplied {
            configuration = supplied
            if installBridge {
                supplied.userContentController.add(bridge, name: "orbit")
            }
        } else {
            configuration = engine.makeConfiguration(session: session, bridge: bridge)
        }
        let view = OrbitWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.isInspectable = true
        if let agent = session.userAgent { view.customUserAgent = agent }
        self.webView = view
        super.init()
        view.menuOwner = self
        bridge.owner = self
        view.navigationDelegate = self
        view.uiDelegate = self
        if let initialURL {
            navigationState.url = initialURL
        }
    }

    func reinstallScripts() {
        engine.installScripts(on: webView.configuration.userContentController)
    }

    func applyContentRuleList(_ list: WKContentRuleList?) {
        let content = webView.configuration.userContentController
        content.removeAllContentRuleLists()
        contentRuleList = list
        if let list { content.add(list) }
    }

    func load(_ url: URL) {
        guard !isClosed else { return }
        navigationState.url = url
        navigationState.isLoading = true
        navigationState.progress = 0
        navigationState.security = Self.security(for: url)
        publishNavigation()
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func loadHTML(_ html: String, baseURL: URL?) {
        guard !isClosed else { return }
        navigationState.isLoading = true
        publishNavigation()
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func reload(ignoringCache: Bool) {
        if ignoringCache { webView.reloadFromOrigin() } else { webView.reload() }
    }

    func stopLoading() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func go(offset: Int) {
        guard let item = webView.backForwardList.item(at: offset) else { return }
        webView.go(to: item)
    }

    func sessionHistory() -> [SessionHistoryEntry] {
        let list = webView.backForwardList
        var entries: [SessionHistoryEntry] = []
        for (index, item) in list.backList.enumerated() {
            entries.append(SessionHistoryEntry(id: index, url: item.url, title: item.title ?? "", offset: index - list.backList.count))
        }
        if let current = list.currentItem {
            entries.append(SessionHistoryEntry(id: entries.count, url: current.url, title: current.title ?? "", offset: 0))
        }
        for (index, item) in list.forwardList.enumerated() {
            entries.append(SessionHistoryEntry(id: entries.count, url: item.url, title: item.title ?? "", offset: index + 1))
        }
        return entries
    }

    func currentCertificate() -> SiteCertificate? { nil }

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func evaluateJavaScript(_ script: String, userGesture: Bool) async throws -> Any? {
        try await evaluateJavaScript(script)
    }

    func evaluateJavaScript(_ script: String, inIsolatedWorld: Bool) async throws -> Any? {
        if inIsolatedWorld {
            return try await webView.evaluateJavaScript(script, in: nil, in: WKContentWorld.world(name: "orbit-isolated"))
        }
        return try await evaluateJavaScript(script)
    }

    var developerToolsFrontend: WebKitWebContents? { nil }
    var isDeveloperToolsDocked: Bool { false }
    func devToolsStateJSON() -> String { #"{"open":false,"docked":false,"attached":false,"responsesToFrontend":0}"# }
    var hasPictureInPictureVideo: Bool { mediaState.hasVideo || mediaState.isPictureInPictureAvailable }
    var chromiumHandle: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func injectUserScript(_ script: UserScript) {
        engine.addUserScript(script, session: session)
    }

    func find(_ text: String, options: FindOptions) {
        let configuration = WKFindConfiguration()
        configuration.backwards = !options.forward
        configuration.caseSensitive = options.matchCase
        configuration.wraps = false
        webView.find(text, configuration: configuration) { [weak self] result in
            guard let self else { return }
            self.delegate?.webContents(self, didUpdateFindResult: FindResult(
                activeMatchOrdinal: result.matchFound ? 1 : 0,
                matchCount: result.matchFound ? 1 : 0,
                isFinalUpdate: true
            ))
        }
    }

    func stopFinding(clearSelection: Bool) {
        if clearSelection { webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil) }
    }

    func cut() { _ = NSApp.sendAction(#selector(NSText.cut(_:)), to: webView, from: nil) }
    func copy() { _ = NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: nil) }
    func paste() { _ = NSApp.sendAction(#selector(NSText.paste(_:)), to: webView, from: nil) }
    func selectAll() { _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: webView, from: nil) }

    func setZoomFactor(_ factor: Double) {
        webView.pageZoom = factor
        delegate?.webContents(self, didChangeZoomFactor: factor)
    }

    func setPreferredColorScheme(_ scheme: ContentColorScheme?) {
        preferredScheme = scheme
        let value: String
        switch scheme {
        case .dark: value = "dark"
        case .light: value = "light"
        case nil: value = "light dark"
        }
        webView.evaluateJavaScript("document.documentElement.style.colorScheme='\(value)'", completionHandler: nil)
    }

    func setMuted(_ muted: Bool) {
        webView.setAllMediaPlaybackSuspended(muted, completionHandler: nil)
        mediaState.isMuted = muted
        delegate?.webContents(self, didChangeMediaState: mediaState)
    }

    func togglePictureInPicture() {
        webView.evaluateJavaScript(
            "(function(){var v=document.querySelector('video');if(!v)return;if(document.pictureInPictureElement){document.exitPictureInPicture();}else{v.requestPictureInPicture();}})()",
            completionHandler: nil
        )
    }

    func capturePreview(rect: CGRect?, size: CGSize) async -> NSImage? {
        let configuration = WKSnapshotConfiguration()
        if let rect { configuration.rect = rect }
        configuration.snapshotWidth = NSNumber(value: Double(size.width))
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    func print() {
        let info = NSPrintInfo.shared
        webView.printOperation(with: info).run()
    }

    func savePage() {
        Task { [weak self] in
            guard let self, let data = try? await self.webView.pdf(configuration: WKPDFConfiguration()) else { return }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let url = downloads.appendingPathComponent("page.pdf")
            try? data.write(to: url)
        }
    }

    func cancelDownload(id: UUID) {}
    func showDeveloperTools(inspectAt point: CGPoint?) {
        // isInspectable only allows inspection. _WKInspector.show opens it.
        webView.isInspectable = true
        let inspectorSelector = NSSelectorFromString("_inspector")
        guard webView.responds(to: inspectorSelector),
              let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue()
        else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) { _ = inspector.perform(show) }
        if point != nil {
            let select = NSSelectorFromString("toggleElementSelection")
            if inspector.responds(to: select) { _ = inspector.perform(select) }
        }
    }

    // Right-click is Orbit's menu. WebKit's default menu has no Inspect item here.
    func openContextMenu(with event: NSEvent) {
        let local = webView.convert(event.locationInWindow, from: nil)
        let css = CGPoint(x: local.x, y: webView.bounds.height - local.y)
        openContextMenu(atCSS: css)
    }

    func openContextMenu(atCSS point: CGPoint) {
        let script = """
        (function(){
          var el = document.elementFromPoint(\(point.x), \(point.y));
          var link = el && el.closest ? el.closest('a') : null;
          var img = el && el.closest ? el.closest('img') : null;
          var editable = false;
          var node = el;
          while (node) {
            var tag = (node.tagName || '').toUpperCase();
            if (node.isContentEditable || tag === 'INPUT' || tag === 'TEXTAREA') { editable = true; break; }
            node = node.parentElement;
          }
          var selection = '';
          try { selection = String(window.getSelection ? window.getSelection() : ''); } catch (e) {}
          return JSON.stringify({
            href: link ? link.href : '',
            src: img ? (img.currentSrc || img.src || '') : '',
            selection: selection,
            editable: editable,
            page: String(location.href || '')
          });
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let context = Self.contextMenuContext(from: result, location: point)
                _ = self.delegate?.webContents(self, showContextMenu: context)
            }
        }
    }

    private static func contextMenuContext(from result: Any?, location: CGPoint) -> ContextMenuContext {
        let object = (result as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let href = object["href"] as? String ?? ""
        let src = object["src"] as? String ?? ""
        let selection = object["selection"] as? String ?? ""
        return ContextMenuContext(
            pageURL: URL(string: object["page"] as? String ?? ""),
            linkURL: href.isEmpty ? nil : URL(string: href),
            sourceURL: src.isEmpty ? nil : URL(string: src),
            selectionText: selection.isEmpty ? nil : selection,
            mediaKind: src.isEmpty ? .none : .image,
            isEditable: object["editable"] as? Bool ?? false,
            location: location
        )
    }
    func closeDeveloperTools() {}
    func focus() { webView.window?.makeFirstResponder(webView) }

    func close() {
        teardown(notifyExtensionController: true)
    }

    func teardown(notifyExtensionController: Bool) {
        guard !isClosed else { return }
        isClosed = true
        if notifyExtensionController { engine.noteTabClosed(self) }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let channel = body["channel"] as? String,
              let json = body["json"] as? String
        else { return }
        switch channel {
        case MediaSessionObserverScript.channelName:
            mediaState = MediaSessionObserverScript.apply(payloadJSON: json, to: mediaState)
            delegate?.webContents(self, didChangeMediaState: mediaState)
        case PageColorObserverScript.channelName:
            guard let reading = PageColorObserverScript.decode(payloadJSON: json) else { return }
            delegate?.webContents(self, didChangeThemeColor: reading.color)
            delegate?.webContents(self, didChangeDocumentColor: reading.documentColor)
        case LinkHoverObserverScript.channelName:
            delegate?.webContents(self, didHoverLink: LinkHoverObserverScript.decode(payloadJSON: json))
        case WebStorePrivateBridgeScript.channelName:
            let payload = json
            Task { [weak self] in
                guard let self, let result = await self.webStorePrivateBridge.handle(payload: payload, contents: self) else { return }
                let script = WebStorePrivateBridgeScript.responseScript(requestID: result.requestID, resultJSON: result.resultJSON)
                _ = try? await self.evaluateJavaScript(script)
            }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationState.isLoading = true
        navigationState.progress = 0.1
        if let url = webView.url {
            navigationState.url = url
            navigationState.security = Self.security(for: url)
        }
        publishNavigation()
        engine.extensionController.didChangeTabProperties(.URL, for: self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationState.canGoBack = webView.canGoBack
        navigationState.canGoForward = webView.canGoForward
        if let url = webView.url {
            navigationState.url = url
            navigationState.security = Self.security(for: url)
            if engine.blockerDecision(url: url.absoluteString, documentURL: url.absoluteString, resourceType: .document) {
                webView.stopLoading()
                delegate?.webContents(self, didFailLoading: EngineError(code: .blockedByPolicy, url: url))
                return
            }
            delegate?.webContents(self, didCommitNavigationTo: url, kind: .other)
        }
        publishNavigation()
        engine.extensionController.didChangeTabProperties(.URL, for: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationState.isLoading = false
        navigationState.progress = 1
        navigationState.title = webView.title ?? ""
        navigationState.canGoBack = webView.canGoBack
        navigationState.canGoForward = webView.canGoForward
        if let url = webView.url { navigationState.url = url }
        publishNavigation()
        if let url = webView.url {
            delegate?.webContents(self, didFinishLoading: url, statusCode: lastStatusCode == 0 ? 200 : lastStatusCode)
            let css = engine.cosmeticStyleSheet(for: url.absoluteString)
            if !css.isEmpty {
                let literal = JavaScriptLiteral.string(css)
                webView.evaluateJavaScript(
                    "(function(){var s=document.createElement('style');s.textContent=\(literal);(document.head||document.documentElement).appendChild(s);})()",
                    completionHandler: nil
                )
            }
        }
        if !navigationState.title.isEmpty {
            delegate?.webContents(self, didChangeTitle: navigationState.title)
        }
        engine.extensionController.didChangeTabProperties([.URL, .title, .loading], for: self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse { lastStatusCode = http.statusCode }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let kind: NavigationKind
        switch navigationAction.navigationType {
        case .linkActivated: kind = .linkActivated
        case .formSubmitted: kind = .formSubmitted
        case .backForward: kind = .backForward
        case .reload: kind = .reload
        case .formResubmitted: kind = .formSubmitted
        default: kind = .other
        }
        let allow = delegate?.webContents(
            self, shouldAllowNavigationTo: url, kind: kind, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true
        ) ?? true
        decisionHandler(allow ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let request = NewContentRequest(
            url: navigationAction.request.url ?? URL(string: "about:blank")!,
            disposition: .newForegroundTab,
            isUserGesture: navigationAction.navigationType == .linkActivated
        )
        let sharesController = configuration.userContentController === webView.configuration.userContentController
        let contents = WebKitWebContents(
            engine: engine,
            session: webKitSession,
            initialURL: request.url,
            configuration: configuration,
            installBridge: !sharesController
        )
        let pending = PendingWebContents(request: request) { contents }
        let accepted = delegate?.webContents(self, requestsAdoptionOf: pending) ?? false
        if accepted, pending.isAdopted { return contents.webView }
        contents.close()
        return nil
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { engine.extensionWindow }
    func title(for context: WKWebExtensionContext) -> String? { navigationState.title }
    func url(for context: WKWebExtensionContext) -> URL? { navigationState.url ?? webView.url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { false }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        guard let url = navigationState.url ?? webView.url else { return false }
        return context.grantedPermissionMatchPatterns.keys.contains { $0.matches(url) }
    }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    private func publishNavigation() {
        delegate?.webContentsDidChangeNavigationState(self)
    }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        navigationState.isLoading = false
        publishNavigation()
        delegate?.webContents(self, didFailLoading: EngineError(
            code: Self.errorCode(nsError),
            url: navigationState.url,
            underlyingDescription: nsError.localizedDescription
        ))
    }

    private static func security(for url: URL) -> SecurityLevel {
        switch url.scheme?.lowercased() {
        case "https": return .secure
        case "http": return .insecure
        case "file", "orbit", "about": return .local
        default: return .unknown
        }
    }

    private static func errorCode(_ error: NSError) -> EngineError.Code {
        switch error.code {
        case NSURLErrorCancelled: return .cancelled
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return .networkUnreachable
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .hostNotFound
        case NSURLErrorCannotConnectToHost: return .connectionRefused
        case NSURLErrorTimedOut: return .connectionTimedOut
        case NSURLErrorHTTPTooManyRedirects: return .tooManyRedirects
        case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed: return .certificateInvalid
        case NSURLErrorFileDoesNotExist: return .fileNotFound
        default: return .unknown
        }
    }
}

@MainActor
final class WebKitScriptBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WebKitWebContents?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}
