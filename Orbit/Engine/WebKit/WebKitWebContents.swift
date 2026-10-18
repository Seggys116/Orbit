import AppKit
import OSLog
import Security
import WebKit

enum WebKitMediaPreferences {
    // Picture-in-picture's public flag is iOS-only. WebGL stays explicitly on.
    static func enable(_ configuration: WKWebViewConfiguration) {
        setTrue(configuration.preferences, "_setAllowsPictureInPictureMediaPlayback:")
        setTrue(configuration.preferences, "_setWebGLEnabled:")
        setTrue(configuration.preferences, "_setNotificationsEnabled:")
        configuration.preferences.isElementFullscreenEnabled = true
    }

    private static func setTrue(_ object: NSObject, _ name: String) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return }
        let implementation = object.method(for: selector)
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Function.self)(object, selector, true)
    }
}

final class OrbitWebView: WKWebView {
    weak var menuOwner: WebKitWebContents?
    /// The view stays in a windowless pane container, but WebKit stops painting unless it
    /// believes the view is in a window. While this is set, `window` reports an off-screen window.
    var keepsCompositingWithoutWindow = false
    private var reportingCompositingWindow = false
    /// Set once the view has been in a real window. Leaving that window leaves the last frame behind.
    fileprivate var hasJoinedRealWindow = false
    fileprivate var snapshotIsStale = false

    private static let compositingWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: -20000, y: -20000, width: 800, height: 600), display: false)
        window.orderFrontRegardless()
        return window
    }()

    /// While the command bar owns the keyboard, WebKit must not take it back.
    /// A page that is already first responder stays there until the presenter moves it.
    var suppressesFirstResponder = false

    var isInRealWindow: Bool { super.window != nil }

    override func becomeFirstResponder() -> Bool {
        if suppressesFirstResponder { return false }
        return super.becomeFirstResponder()
    }

    override var window: NSWindow? {
        if keepsCompositingWithoutWindow, super.window == nil {
            return Self.compositingWindow
        }
        return super.window
    }

    override func viewDidMoveToWindow() {
        if !reportingCompositingWindow {
            if super.window == nil {
                if hasJoinedRealWindow { snapshotIsStale = true }
                keepsCompositingWithoutWindow = false
            } else {
                hasJoinedRealWindow = true
                snapshotIsStale = false
            }
        }
        super.viewDidMoveToWindow()
    }

    override func removeFromSuperview() {
        if refusesExternalReparent { return }
        super.removeFromSuperview()
    }

    override func removeFromSuperviewWithoutNeedingDisplay() {
        if refusesExternalReparent { return }
        super.removeFromSuperviewWithoutNeedingDisplay()
    }

    /// An undocked inspector's attach removes the page from its window and the next script
    /// dies with `removedFromContainer`. Orbit's own moves opt out of the lock.
    private var refusesExternalReparent: Bool {
        guard let owner = menuOwner else { return false }
        if owner.intentionalInspectorReparentCount > 0 { return false }
        return owner.inspectorReparentLock
    }

    /// `createWebArchiveData` never calls back unless the view is actually in a window.
    func attachForArchivingIfNeeded() {
        guard super.window == nil else { return }
        keepsCompositingWithoutWindow = false
        guard let host = Self.compositingWindow.contentView else { return }
        frame = NSRect(origin: .zero, size: host.bounds.size)
        host.addSubview(self)
    }

    /// `_killWebContentProcess` only calls `terminate()`, which does not tell the navigation
    /// delegate. The reset variant asks the process to exit and reports that exit.
    @objc(_killWebContentProcess)
    func killWebContentProcess() {
        let reset = NSSelectorFromString("_killWebContentProcessAndResetState")
        let selector = responds(to: reset) ? reset : NSSelectorFromString("_killWebContentProcess")
        let implementation = class_getMethodImplementation(WKWebView.self, selector)
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(implementation, to: Function.self)(self, selector)
    }

    func declareVisible(_ visible: Bool) {
        // An off-screen stand-in is still occluded. Painting has to be allowed explicitly.
        setWindowOcclusionDetectionEnabled(!visible)
        if visible, !isInRealWindow {
            snapshotIsStale = false
            keepsCompositingWithoutWindow = true
            reportingCompositingWindow = true
            viewDidMoveToWindow()
            reportingCompositingWindow = false
        } else if !visible, !isInRealWindow {
            if hasJoinedRealWindow { snapshotIsStale = true }
            keepsCompositingWithoutWindow = false
            reportingCompositingWindow = true
            viewDidMoveToWindow()
            reportingCompositingWindow = false
        }
    }

    private func setWindowOcclusionDetectionEnabled(_ enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard responds(to: selector) else { return }
        let implementation = method(for: selector)
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Function.self)(self, selector, enabled)
    }

    // The click still goes to WebKit so the page sees its contextmenu event; Orbit's menu replaces WebKit's.
    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { menuOwner?.willForwardContextClick(event) }
        super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            MainActor.assumeIsolated { menuOwner?.willForwardContextClick(event) }
        }
        super.mouseDown(with: event)
    }
}

extension WKWebView {
    /// The embedder's own script, including `window.open` and fullscreen, runs with transient activation.
    func evaluateJavaScript(_ script: String, withUserGesture userGesture: Bool) async throws -> Any? {
        guard userGesture else { return try await evaluateJavaScript(script) }
        let selector = NSSelectorFromString("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:")
        guard responds(to: selector) else { return try await evaluateJavaScript(script) }
        return try await withCheckedThrowingContinuation { continuation in
            let handler: @convention(block) (Any?, NSError?) -> Void = { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
            let implementation = method(for: selector)
            typealias Function = @convention(c) (
                AnyObject, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, ObjCBool,
                @convention(block) (Any?, NSError?) -> Void
            ) -> Void
            unsafeBitCast(implementation, to: Function.self)(
                self, selector, script as NSString, nil, nil, WKContentWorld.page, ObjCBool(true), handler
            )
        }
    }
}

@MainActor
enum WebKitLiveContents {
    private static var contents: [WeakWebContents] = []

    static func track(_ contents: WebKitWebContents) {
        self.contents.removeAll { $0.value == nil || $0.value?.isClosed == true }
        guard !self.contents.contains(where: { $0.value === contents }) else { return }
        self.contents.append(WeakWebContents(contents))
    }

    static var all: [WebKitWebContents] {
        contents.compactMap { $0.value }.filter { !$0.isClosed }
    }
}

private final class WeakWebContents {
    weak var value: WebKitWebContents?
    init(_ value: WebKitWebContents) { self.value = value }
}

enum SVGFaviconRasterizer {
    static func image(from data: Data) -> NSImage? {
        guard let text = String(data: data, encoding: .utf8), text.contains("<svg") else { return nil }
        let size = svgSize(in: text)
        guard let fill = rgbFill(in: text) else { return nil }
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private static func svgSize(in text: String) -> NSSize {
        func number(_ name: String) -> Double? {
            guard let range = text.range(of: "\(name)=\"") else { return nil }
            let rest = text[range.upperBound...]
            let digits = rest.prefix { $0.isNumber || $0 == "." }
            return Double(digits)
        }
        let width = number("width") ?? 32
        let height = number("height") ?? 32
        return NSSize(width: width, height: height)
    }

    private static func rgbFill(in text: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let range = text.range(of: "rgb(") else { return nil }
        let rest = text[range.upperBound...]
        let parts = rest.prefix { $0 != ")" }.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        return (CGFloat(parts[0]) / 255, CGFloat(parts[1]) / 255, CGFloat(parts[2]) / 255)
    }
}

@MainActor
final class WebKitWebContents: NSObject, WebContents, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKWebExtensionTab {
    let id = UUID()
    let session: EngineSession
    weak var delegate: WebContentsDelegate?
    var navigationState = NavigationState()
    var mediaState = MediaState.idle
    private(set) var isClosed = false
    private var webViewReleased = false
    var zoomFactor: Double { webView.pageZoom }

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "WebKitWebContents")

    let engine: WebKitEngine
    let webKitSession: WebKitSession
    private(set) var webView: OrbitWebView
    private var extensionPageHost: String?
    var isExtensionPage: Bool { extensionPageHost != nil }
    private let scriptBridge: WebKitScriptBridge
    private var lastStatusCode = 0
    private var preferredScheme: ContentColorScheme?
    private lazy var webStorePrivateBridge = WebStorePrivateBridge()
    /// Which main-frame URLs get the Chrome identity; tests swap it to point at a local server.
    var chromeIdentityMatcher: (URL?) -> Bool = { WebKitProduct.usesChromeIdentity(for: $0) }
    /// showResources opens the window once. A later call dismisses it.
    private var inspectorResourcesPresented = false
    /// Close from the app must not undo itself. WebKit's attach path closes the separate inspector window; the page is put back in its host window without another detach.
    private(set) var inspectorCloseSuppressed = false
    var inspectorCloseGeneration = 0
    private var inspectorCloseObserver: NSObjectProtocol?
    private weak var inspectorObject: NSObject?
    /// The window a page with no dock pane must stay in. `show()` can attach and reparent the page out of it.
    private weak var undockedPageHostWindow: NSWindow?
    private var undockedPageHostObservations: [NSKeyValueObservation] = []
    private var undockedPageHostRestoreScheduled = false
    private var restoringUndockedPageHost = false
    /// While set, WebKit's attach cannot pull this page out of its window.
    var inspectorReparentLock = false
    /// Orbit is moving the page itself (dock, restore, close). Those moves are allowed.
    var intentionalInspectorReparentCount = 0
    let extras = WebKitContentsExtras()

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
        WebKitMediaPreferences.enable(configuration)
        let view = OrbitWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.isInspectable = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        session.attach(view)
        self.webView = view
        super.init()
        view.menuOwner = self
        bridge.owner = self
        view.navigationDelegate = self
        view.uiDelegate = self
        attachResourceLoadDelegate(view)
        WebKitContextMenuProbe.install(on: configuration.userContentController)
        Self.installIsolatedWorld(on: configuration.userContentController)
        observeWebView()
        WebKitLiveContents.track(self)
        setPreferredColorScheme(AppearanceSettings.shared.engineColorScheme)
        if let initialURL {
            navigationState.url = initialURL
        }
    }

    func reinstallScripts() {
        let controller = webView.configuration.userContentController
        engine.installScripts(on: controller)
        Self.installIsolatedWorld(on: controller)
        WebKitCosmeticScripts.reset(controller)
        contentSizing?.addScript(to: controller)
        if !isExtensionPage { WebKitContextMenuProbe.install(on: controller) }
    }

    func load(_ url: URL) {
        guard !isClosed else { return }
        let resolved = engine.resolvedExtensionURL(url)
        extras.browserInitiatedLoad = true
        extras.navigationFailureReported = false
        extras.requestedLoadURL = resolved
        adoptWebViewIfNeeded(for: resolved)
        navigationState.url = resolved
        navigationState.isLoading = true
        navigationState.progress = 0
        navigationState.security = Self.security(for: resolved)
        publishNavigation()
        if resolved.isFileURL {
            webView.loadFileURL(resolved, allowingReadAccessTo: resolved.deletingLastPathComponent())
        } else if let current = webView.url, Self.sameNavigationURL(current, resolved), webView.reload() != nil {
            // load() of the committed URL stays the same document, so nothing is requested again.
        } else {
            webView.load(URLRequest(url: resolved))
        }
    }

    /// Scheme, host, port, path, query and fragment. A fragment-only change is a different navigation.
    private static func sameNavigationURL(_ current: URL, _ requested: URL) -> Bool {
        guard current.scheme?.lowercased() == requested.scheme?.lowercased(),
              current.host?.lowercased() == requested.host?.lowercased(),
              current.port == requested.port,
              current.path == requested.path,
              current.query == requested.query
        else { return false }
        let currentFragment = current.fragment ?? ""
        let requestedFragment = requested.fragment ?? ""
        return currentFragment == requestedFragment
    }

    // An extension URL only loads in the web view WebKit built for that extension.
    private func adoptWebViewIfNeeded(for url: URL) {
        let host = Self.extensionHost(of: url)
        if let host {
            guard extensionPageHost != host, let configuration = engine.extensionWebViewConfiguration(for: url) else { return }
            replaceWebView(with: configuration, extensionHost: host)
        } else if extensionPageHost != nil {
            replaceWebView(with: engine.makeConfiguration(session: webKitSession, bridge: scriptBridge), extensionHost: nil)
        }
    }

    private func needsDifferentWebView(for url: URL) -> Bool {
        if let host = Self.extensionHost(of: url) {
            return extensionPageHost != host && engine.extensionWebViewConfiguration(for: url) != nil
        }
        return extensionPageHost != nil
    }

    private static func extensionHost(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "chrome-extension" || scheme == "webkit-extension"
        else { return nil }
        let host = url.host?.lowercased() ?? ""
        return host.isEmpty ? nil : host
    }

    private func replaceWebView(with configuration: WKWebViewConfiguration, extensionHost: String?) {
        WebKitMediaPreferences.enable(configuration)
        let replacement = OrbitWebView(frame: webView.frame, configuration: configuration)
        replacement.menuOwner = self
        replacement.isInspectable = true
        replacement.navigationDelegate = self
        replacement.uiDelegate = self
        attachResourceLoadDelegate(replacement)
        webKitSession.attach(replacement)
        let old = webView
        if let superview = old.superview {
            replacement.translatesAutoresizingMaskIntoConstraints = old.translatesAutoresizingMaskIntoConstraints
            let constraints = superview.constraints.filter {
                ($0.firstItem as AnyObject?) === old || ($0.secondItem as AnyObject?) === old
            }
            NSLayoutConstraint.deactivate(constraints)
            superview.addSubview(replacement)
            NSLayoutConstraint.activate([
                replacement.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
                replacement.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
                replacement.topAnchor.constraint(equalTo: superview.topAnchor),
                replacement.bottomAnchor.constraint(equalTo: superview.bottomAnchor),
            ])
            old.removeFromSuperview()
        }
        old.navigationDelegate = nil
        old.uiDelegate = nil
        detachResourceLoadDelegate(old)
        old.stopLoading()
        webView = replacement
        extensionPageHost = extensionHost
        extras.hostContainer = nil
        observeWebView()
        contentSizing?.attach(to: replacement)
        if extensionHost == nil { WebKitContextMenuProbe.install(on: configuration.userContentController) }
        // didOpenTab ran before this view became an extension page, so WebKit
        // still lists the popup as a browser tab until it is closed.
        if extensionHost != nil {
            engine.retireExtensionPage(self)
        }
    }

    func loadHTML(_ html: String, baseURL: URL?) {
        guard !isClosed else { return }
        navigationState.isLoading = true
        publishNavigation()
        guard let baseURL else {
            // No base URL is an opaque origin. loadHTMLString(nil) is a unique
            // about:blank, which this WebKit treats as a secure context.
            let encoded = Data(html.utf8).base64EncodedString()
            if let url = URL(string: "data:text/html;base64,\(encoded)") {
                webView.load(URLRequest(url: url))
            }
            return
        }
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func reload(ignoringCache: Bool) {
        guard !isClosed else { return }
        if ignoringCache {
            // load() of the committed URL is FrameLoadType::Same and ignores the
            // reload cache policy. stopLoading() before it also cancels that load.
            reloadDocumentFromOrigin()
            return
        }
        extras.browserInitiatedLoad = true
        webView.reload()
    }

    func stopLoading() { webView.stopLoading() }
    func goBack() {
        extras.browserInitiatedLoad = true
        webView.goBack()
    }

    func goForward() {
        extras.browserInitiatedLoad = true
        webView.goForward()
    }

    func go(offset: Int) {
        guard let item = webView.backForwardList.item(at: offset) else { return }
        extras.browserInitiatedLoad = true
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

    // A script that ran but produced a value JSON cannot carry (a Window from `window.open`, a DOM
    // node, a function) did not fail. WebKit reports that as an error, so it is answered with nil,
    // as a script that returns nothing is. An exception thrown by the script still throws.
    private static func scriptResult(_ run: () async throws -> Any?) async throws -> Any? {
        do {
            return try await run()
        } catch let error as NSError
            where error.domain == WKErrorDomain && error.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue {
            return nil
        }
    }

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await Self.scriptResult { try await webView.evaluateJavaScript(script) }
    }

    func evaluateJavaScript(_ script: String, userGesture: Bool) async throws -> Any? {
        try await Self.scriptResult { try await webView.evaluateJavaScript(script, withUserGesture: userGesture) }
    }

    /// A named world stays empty until a script is installed in it. Without that, later
    /// evaluations do not share a global, so a value set in one call is gone in the next.
    private static let isolatedWorld = WKContentWorld.world(name: "orbit-isolated")
    private static let isolatedWorldSource = "/* orbit-isolated */"

    static func installIsolatedWorld(on controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: {
            $0.source == isolatedWorldSource && $0.injectionTime == .atDocumentStart
        }) else { return }
        controller.addUserScript(WKUserScript(
            source: isolatedWorldSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: isolatedWorld
        ))
    }

    func evaluateJavaScript(_ script: String, inIsolatedWorld: Bool) async throws -> Any? {
        if inIsolatedWorld {
            return try await Self.scriptResult {
                try await webView.evaluateJavaScript(script, in: nil, contentWorld: Self.isolatedWorld)
            }
        }
        return try await evaluateJavaScript(script)
    }

    var hasPictureInPictureVideo: Bool { mediaState.isPictureInPictureActive }
    var extensionTabHandle: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func injectUserScript(_ script: UserScript) {
        engine.addUserScript(script, session: session)
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
        case .dark:
            value = "dark"
            webView.appearance = NSAppearance(named: .darkAqua)
        case .light:
            value = "light"
            webView.appearance = NSAppearance(named: .aqua)
        case nil:
            value = "light dark"
            webView.appearance = nil
        }
        webView.evaluateJavaScript("document.documentElement.style.colorScheme='\(value)'", completionHandler: nil)
    }

    func setMuted(_ muted: Bool) {
        guard !isClosed else { return }
        applyMute(muted)
        mediaState.isMuted = muted
        if muted { mediaState.isAudible = false }
        delegate?.webContents(self, didChangeMediaState: mediaState)
    }

    func setVisible(_ visible: Bool) {
        (webView as? OrbitWebView)?.declareVisible(visible)
    }

    func togglePictureInPicture() {
        Task { [weak self] in
            _ = try? await self?.webView.evaluateJavaScript(PictureInPictureScript.source, withUserGesture: true)
        }
    }

    func capturePreview(rect: CGRect?, size: CGSize) async -> NSImage? {
        if let orbit = webView as? OrbitWebView, orbit.snapshotIsStale, !orbit.isInRealWindow, !orbit.keepsCompositingWithoutWindow {
            return nil
        }
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
            guard let self, !self.isClosed else { return }
            (self.webView as? OrbitWebView)?.attachForArchivingIfNeeded()
            let base = WebKitDownloads.sanitizedBaseName(
                from: self.navigationState.title.isEmpty ? (self.navigationState.url?.host ?? "page") : self.navigationState.title
            )
            var target = WebKitDownloads.downloadsDirectory.appendingPathComponent(base).appendingPathExtension("webarchive")
            do {
                let data = try await withCheckedThrowingContinuation { continuation in
                    self.webView.createWebArchiveData { continuation.resume(with: $0) }
                }
                // Named after the await, with no suspension before the write, so two saves cannot pick the same name.
                target = WebKitDownloads.uniqueFileURL(
                    inDirectory: WebKitDownloads.downloadsDirectory, baseName: base, pathExtension: "webarchive"
                )
                try data.write(to: target, options: .withoutOverwriting)
            } catch {
                Self.logger.error("savePage: \(target.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelDownload(id: UUID) {
        WebKitDownloads.shared.cancel(id: id)
    }

    func showDeveloperTools(inspectAt point: CGPoint?) {
        // perform(_:) does not invoke these void methods. show() connects and leaves the window hidden.
        webView.isInspectable = true
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        guard let inspector = webInspector() as? NSObject else { return }
        inspectorObject = inspector
        inspectorCloseGeneration += 1
        inspectorCloseSuppressed = false
        observeInspectorWindowClose()
        // WebKit ignores connect() until it has observed the inspectable flag on a later turn.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        let hostWindow = webView.window
        // show() attaches and reparents the page. A page with no pane has to stay put: taking
        // it out of its window while a script runs fails the script with removedFromContainer.
        if canDockInspector {
            inspectorReparentLock = false
            stopUndockedPageHostWatch()
        } else {
            inspectorReparentLock = true
            Self.voidMessage(inspector, "detach")
            undockedPageHostWindow = hostWindow
        }
        if !inspectorResourcesPresented {
            Self.voidMessage(inspector, "connect")
            Self.voidMessage(inspector, "show")
            Self.voidMessage(inspector, "showResources")
            if point != nil { Self.voidMessage(inspector, "showConsole") }
            inspectorResourcesPresented = true
        } else if !Self.inspectorWindowIsOnScreen() {
            // hide() cleared visibility and closed the NSWindow. show() opens a new one.
            // Detach again only before that show, while nothing is executing in the inspector.
            if !canDockInspector { Self.voidMessage(inspector, "detach") }
            Self.voidMessage(inspector, "show")
        }
        if !canDockInspector {
            watchUndockedPageHost()
            restoreUndockedPageHost()
        }
        if point != nil { armElementSelection() }
        applyDeveloperToolsDock(inspector)
        EngineAppearance.apply()
    }

    /// Drops the watch that keeps an undocked page in its host window. A pane that can dock
    /// the inspector owns the page from here on.
    func stopUndockedPageHostWatch() {
        undockedPageHostObservations.removeAll()
        undockedPageHostWindow = nil
        undockedPageHostRestoreScheduled = false
    }

    private func watchUndockedPageHost() {
        guard undockedPageHostObservations.isEmpty else { return }
        // `window` is not always KVO-compliant; superview changes whenever the page is reparented.
        // The restore is async: this fires inside removeFromSuperview, and setting contentView
        // there re-enters AppKit and fights the host that is adopting the page.
        undockedPageHostObservations.append(webView.observe(\.window, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleUndockedPageHostRestore() }
        })
        undockedPageHostObservations.append(webView.observe(\.superview, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleUndockedPageHostRestore() }
        })
    }

    private func scheduleUndockedPageHostRestore() {
        guard !undockedPageHostRestoreScheduled, !canDockInspector, undockedPageHostWindow != nil else { return }
        undockedPageHostRestoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.undockedPageHostRestoreScheduled = false
                self.restoreUndockedPageHost()
            }
        }
    }

    /// Puts the page back when it has left its host window. Does not detach: detach on an
    /// already-undocked inspector removes the page while a script is running in it.
    func restoreUndockedPageHost() {
        if canDockInspector {
            stopUndockedPageHostWatch()
            return
        }
        guard !isClosed, !restoringUndockedPageHost, let host = undockedPageHostWindow else { return }
        let current = webView.window
        if current === host { return }
        // A deliberate re-host sets the page as that window's content view (the test does this
        // between opens). Follow it.
        if let current, !Self.isInspectorWindow(current), current.contentView === webView {
            undockedPageHostWindow = current
            return
        }
        // The page is already in a window, including Web Inspector's own. Moving it now removes
        // it from that window mid-script (`removedFromContainer`).
        if current != nil { return }
        restoringUndockedPageHost = true
        defer { restoringUndockedPageHost = false }
        let bounds = host.contentView?.bounds ?? webView.frame
        performInspectorReparent {
            host.contentView = webView
            webView.frame = host.contentView?.bounds ?? bounds
        }
    }

    func performInspectorReparent(_ body: () -> Void) {
        intentionalInspectorReparentCount += 1
        body()
        intentionalInspectorReparentCount -= 1
    }

    private static func isInspectorWindow(_ window: NSWindow) -> Bool {
        window.title.hasPrefix("Web Inspector")
    }

    /// Selection becomes active only after the page process answers `StartElementSelection`.
    /// That answer needs a focused frame, so the page is focused after it is back in its window.
    /// `toggleElementSelection` sends Start while the flag is false and Stop while it is true;
    /// a second call before the reply cancels the first. One Start, then wait for the flag.
    private func armElementSelection() {
        guard !isClosed, let inspector = webInspector() as? NSObject else { return }
        if !canDockInspector { inspectorReparentLock = true }
        restoreUndockedPageHost()
        let connectDeadline = Date().addingTimeInterval(3)
        while !Self.boolMessage(inspector, "isConnected"), Date() < connectDeadline, !isClosed {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard !isClosed, Self.boolMessage(inspector, "isConnected") else { return }
        if Self.boolMessage(inspector, "isElementSelectionActive") { return }

        _ = focusInspectedPageForElementSelection()
        guard !isClosed, let window = webView.window else { return }
        window.makeKey()
        window.makeFirstResponder(webView)

        let started = Date()
        let deadline = started.addingTimeInterval(8)
        var didNativeToggle = false
        while Date() < deadline, !isClosed {
            if Self.boolMessage(inspector, "isElementSelectionActive") { return }
            let frontend = inspectorFrontendWebView
            let frontendReady = frontend.map { !$0.isLoading && $0.url != nil } ?? false
            // Start only once the frontend can receive it. A toggle before that is dropped,
            // and a second toggle sends Stop.
            if !didNativeToggle, frontendReady || Date() >= started.addingTimeInterval(2) {
                didNativeToggle = true
                window.makeKey()
                window.makeFirstResponder(webView)
                Self.voidMessage(inspector, "toggleElementSelection")
                if let frontend, frontendReady {
                    frontend.evaluateJavaScript(
                        "(function(){ if (typeof WI === 'undefined' || !WI.domManager) return false; WI.domManager.inspectModeEnabled = true; return !!WI.domManager.inspectModeEnabled; })()"
                    ) { _, _ in }
                }
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Makes the page first responder and focuses `document.body` once it is in a window.
    /// Returns whether the document reports focus, which is what gives WebKit a focused frame.
    private func focusInspectedPageForElementSelection() -> Bool {
        restoreUndockedPageHost()
        guard let window = webView.window else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeFirstResponder(webView)
        // One turn so the responder change is delivered before body.focus().
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        guard webView.window != nil else { return false }
        var done = false
        var hasFocus = false
        webView.evaluateJavaScript(
            "(function(){ var root = document.documentElement; if (root && !root.hasAttribute('tabindex')) root.setAttribute('tabindex', '-1'); if (window.focus) window.focus(); if (root && root.focus) root.focus(); return !!document.hasFocus(); })()"
        ) { result, error in
            hasFocus = error == nil && (result as? Bool == true)
            done = true
        }
        let deadline = Date().addingTimeInterval(1)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return hasFocus
    }

    func developerToolsAreOpen() -> Bool {
        if let inspector = webInspector(), Self.boolMessage(inspector, "isVisible") { return true }
        return NSApp.windows.contains { $0.isVisible && $0.title.hasPrefix("Web Inspector") }
    }

    func webInspector() -> AnyObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue()
    }

    static func voidMessage(_ object: AnyObject, _ name: String) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return }
        let implementation = object.method(for: selector)
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(implementation, to: Function.self)(object, selector)
    }

    static func boolMessage(_ object: AnyObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        let implementation = object.method(for: selector)
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Function.self)(object, selector)
    }

    func closeDeveloperTools() {
        // An in-flight Show reply can open the window after close(). Extras off makes that reply return.
        inspectorReparentLock = false
        inspectorCloseSuppressed = true
        inspectorResourcesPresented = false
        inspectorCloseGeneration += 1
        let generation = inspectorCloseGeneration
        webView.isInspectable = false
        webView.configuration.preferences.setValue(false, forKey: "developerExtrasEnabled")
        dismissInspectorWindows()
        scheduleHostedLayoutRestore()
        for delay in [0.05, 0.15, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.inspectorCloseSuppressed, self.inspectorCloseGeneration == generation else { return }
                    self.dismissInspectorWindows()
                }
            }
        }
    }

    private func dismissInspectorWindows() {
        if let inspector = inspectorObject ?? (webInspector() as? NSObject) {
            Self.voidMessage(inspector, "close")
        }
        for window in NSApp.windows where window.title.hasPrefix("Web Inspector") {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
    }

    private static func inspectorWindowIsOnScreen() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.title.hasPrefix("Web Inspector") }
    }

    private func observeInspectorWindowClose() {
        guard inspectorCloseObserver == nil else { return }
        inspectorCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow, window.title.hasPrefix("Web Inspector") else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Attach closes the separate inspector window and can take the page with it.
                    // Put the page back. Do not detach: the inspector is already undocked, and
                    // detach while a script is running removes the page from its window.
                    // An outside close of that window must stay closed.
                    guard let self, !self.inspectorCloseSuppressed, !self.canDockInspector else { return }
                    self.scheduleUndockedPageHostRestore()
                }
            }
        }
    }
    func setFocusSuppressed(_ suppressed: Bool) {
        webView.suppressesFirstResponder = suppressed
        if suppressed, let window = webView.window, window.firstResponder === webView {
            window.makeFirstResponder(nil)
        }
    }

    func focus() {
        guard !webView.suppressesFirstResponder else { return }
        webView.window?.makeFirstResponder(webView)
    }

    func close() {
        teardown(notifyExtensionController: true)
    }

    func teardown(notifyExtensionController: Bool) {
        guard !isClosed else { return }
        isClosed = true
        extras.tearDown()
        inspectorCloseSuppressed = true
        stopUndockedPageHostWatch()
        if let inspectorCloseObserver {
            NotificationCenter.default.removeObserver(inspectorCloseObserver)
            self.inspectorCloseObserver = nil
        }
        if notifyExtensionController { engine.noteTabClosed(self) }
        inspectorReparentLock = false
        destroyWebView()
    }

    private func destroyWebView() {
        contentSizing?.detach()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        detachResourceLoadDelegate(webView)
        webView.stopLoading()
        webView.removeFromSuperview()
        releaseWebView()
    }

    // A closed contents keeps a non-optional webView. WebKit will not remove a data store while its
    // view is alive, so the real view is swapped for an inert one. The swap waits until the next
    // turn: chrome.tabs.remove calls close() on WebKit's own callback stack, and deallocating the
    // WKWebView there trips idle -> failed(deinit).
    private func releaseWebView() {
        guard !webViewReleased else { return }
        webViewReleased = true
        let frame = webView.frame
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            self.webView = OrbitWebView(frame: frame, configuration: configuration)
        }
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
        case "cookie":
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["cookie"] as? String,
                  let page = URL(string: object["url"] as? String ?? ""),
                  let http = Self.httpCookie(fromDocumentAssignment: raw, page: page)
            else { return }
            engine.services.reportBrowserCookieChange(http, removed: false)
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
            engine.noteMainFrameNavigationStarted(
                self, url: url, navigationType: extras.mainFrameNavigationType, browserInitiated: extras.browserInitiatedLoad
            )
        }
        extras.browserInitiatedLoad = false
        publishNavigation()
        engine.extensionController.didChangeTabProperties(.URL, for: self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationState.canGoBack = webView.canGoBack
        navigationState.canGoForward = webView.canGoForward
        if let url = webView.url {
            navigationState.url = url
            navigationState.security = Self.security(for: url, mixedContent: !webView.hasOnlySecureContent)
            if engine.blockerDecision(url: url.absoluteString, documentURL: url.absoluteString, resourceType: .document) {
                webView.stopLoading()
                delegate?.webContents(self, didFailLoading: EngineError(code: .blockedByPolicy, url: url))
                return
            }
            if mediaState.isMuted { applyMute(true) }
            delegate?.webContents(self, didCommitNavigationTo: url, kind: .other)
        }
        publishNavigation()
        engine.extensionController.didChangeTabProperties(.URL, for: self)
        continueOriginReloadIfNeeded()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        extras.requestedLoadURL = nil
        navigationState.isLoading = false
        navigationState.progress = 1
        contentSizing?.measure()
        navigationState.title = webView.title ?? ""
        navigationState.canGoBack = webView.canGoBack
        navigationState.canGoForward = webView.canGoForward
        if let url = webView.url { navigationState.url = url }
        publishNavigation()
        if let url = webView.url {
            delegate?.webContents(self, didFinishLoading: url, statusCode: lastStatusCode == 0 ? 200 : lastStatusCode)
        }
        if !navigationState.title.isEmpty {
            delegate?.webContents(self, didChangeTitle: navigationState.title)
        }
        discoverFavicon()
        engine.extensionController.didChangeTabProperties([.URL, .title, .loading], for: self)
        continueOriginReloadIfNeeded()
    }

    func noteDocumentTitle() {
        let title = webView.title ?? ""
        guard title != navigationState.title else { return }
        navigationState.title = title
        if !title.isEmpty {
            delegate?.webContents(self, didChangeTitle: title)
        }
        guard !isClosed else { return }
        engine.extensionController.didChangeTabProperties(.title, for: self)
    }

    @objc(reloadFromOrigin:forWebExtensionContext:completionHandler:)
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        // tabs.reload() from a popup has no tab id. Chrome reloads the page, not the popup.
        let target = isExtensionPage ? (engine.browserActiveTab() ?? self) : self
        target.reload(ignoringCache: fromOrigin)
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteMainFrameFailure(error)
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteMainFrameFailure(error)
        fail(error)
    }

    private func noteMainFrameFailure(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        guard !extras.navigationFailureReported else { return }
        let failingURL = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        guard let url = failingURL ?? navigationState.url else { return }
        extras.navigationFailureReported = true
        engine.noteMainFrameNavigationFailed(self, url: url, error: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        if let http { lastStatusCode = http.statusCode }
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let isAttachment = disposition?.hasPrefix("attachment") == true
        decisionHandler(isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        WebKitDownloads.shared.adopt(download, owner: self, sourceURL: navigationResponse.response.url)
        settleAfterDownloadHandoff()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        WebKitDownloads.shared.adopt(download, owner: self, sourceURL: navigationAction.request.url)
        settleAfterDownloadHandoff()
    }

    // A navigation that became a download never commits, so nothing else clears the loading state.
    private func settleAfterDownloadHandoff() {
        navigationState.isLoading = false
        navigationState.progress = 1
        if let url = webView.url { navigationState.url = url }
        publishNavigation()
    }

    // Decides which identity one main-frame navigation sends; an explicit session override always wins.
    func chromeIdentityApplies(to url: URL?) -> Bool {
        webKitSession.userAgent == nil && chromeIdentityMatcher(url)
    }

    // The preferences variant supersedes the plain one, which keeps the policy logic below.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame ?? true {
            WebKitNavigationUserAgent.set(
                chromeIdentityApplies(to: navigationAction.request.url) ? WebKitProduct.webStoreUserAgent : nil,
                on: preferences
            )
        }
        self.webView(webView, decidePolicyFor: navigationAction) { policy in
            decisionHandler(policy, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        installCosmeticStyleSheet(for: url)
        if navigationAction.targetFrame?.isMainFrame ?? true { extras.trustDecisions.removeAll() }
        // Cmd-click, middle-click and Shift-click arrive as a plain link navigation. Nothing is built yet, so the delegate opens the tab.
        if navigationAction.navigationType == .linkActivated, url.scheme?.lowercased() != "javascript",
           let disposition = NewContentDisposition.forLinkClick(
               modifiers: navigationAction.modifierFlags, buttonNumber: navigationAction.buttonNumber
           ),
           delegate?.webContents(self, requestsNewContent: NewContentRequest(url: url, disposition: disposition, isUserGesture: true)) == true {
            decisionHandler(.cancel)
            return
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if mainFrame { extras.mainFrameNavigationType = navigationAction.navigationType }
        if mainFrame, needsDifferentWebView(for: url) {
            if !isExtensionPage,
               !engine.permitsWebInitiatedNavigation(to: url, from: navigationAction.sourceFrame.request.url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.cancel)
            load(url)
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

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        resolvePermission(WebKitPermissionPolicy.kinds(for: type), origin: WebKitPermissionPolicy.url(for: origin), decisionHandler: decisionHandler)
    }

    func resolvePermission(_ kinds: Set<PermissionKind>, origin: URL, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        Task { @MainActor in
            let granted = await WebKitPermissionPolicy.resolve(kinds: kinds, origin: origin, session: self.webKitSession) { request in
                guard let delegate = self.delegate else { return .deny }
                return await delegate.webContents(self, requestsPermission: request)
            }
            decisionHandler(granted ? .grant : .deny)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let request = NewContentRequest(
            url: navigationAction.request.url ?? URL(string: "about:blank")!,
            disposition: NewContentDisposition.forNewWindow(
                modifiers: navigationAction.modifierFlags,
                buttonNumber: navigationAction.buttonNumber,
                features: NewContentDisposition.WebKitWindowFeatures(windowFeatures)
            ),
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

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Once this delegate is implemented, WebKit treats performDefaultHandling on a
        // server-trust challenge as "no credential" and cancels the load. A certificate the
        // system already trusts has to be handed back, including after a redirect
        // (google.com to www.google.com) and for every other host the page loads (Apple's CDN).
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            Task { @MainActor in
                if let decision = await self.engine.extensionAuthenticationDecision(for: challenge, in: self) {
                    completionHandler(decision.0, decision.1)
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            }
            return
        }
        let documentURLs = [navigationState.url, inFlightURL(), privateWebViewURL("_provisionalURL")]
        if let problem = Self.certificateProblem(from: challenge) {
            guard Self.challengeIsForMainDocument(challenge.protectionSpace, documentURLs: documentURLs) else {
                // An untrusted stylesheet or script fails on its own. It does not replace the page with an interstitial.
                completionHandler(.performDefaultHandling, nil)
                return
            }
            Task { @MainActor in
                let allow = await self.trustDecision(for: challenge.protectionSpace, problem: problem)
                if allow {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
            return
        }
        completionHandler(Self.untroubledServerTrustDisposition, URLCredential(trust: trust))
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? {
        let title = navigationState.title.isEmpty ? (webView.title ?? "") : navigationState.title
        return title.isEmpty ? nil : title
    }
    func url(for context: WKWebExtensionContext) -> URL? {
        // A navigation that has not committed keeps the last document here. The new address is pendingURL.
        if navigationState.isLoading, let committed = committedDocumentURL(),
           let pending = inFlightURL(), pending != committed {
            return committed
        }
        return navigationState.url ?? webView.url
    }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        guard let url = navigationState.url ?? webView.url else { return false }
        return context.grantedPermissionMatchPatterns.keys.contains { $0.matches(url) }
    }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    private func discoverFavicon() {
        let pageURL = webView.url
        webView.evaluateJavaScript(Self.faviconDiscoverySource) { [weak self] result, _ in
            guard let self, let text = result as? String,
                  let data = text.data(using: .utf8),
                  let hrefs = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return }
            self.fetchFirstDecodableFavicon(hrefs, pageURL: pageURL)
        }
    }

    private func fetchFirstDecodableFavicon(_ hrefs: [String], pageURL: URL?) {
        Task { @MainActor in
            for href in hrefs {
                guard let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                      let image = await Self.faviconImage(at: url)
                else { continue }
                delegate?.webContents(self, didChangeFavicon: image, url: url)
                return
            }
        }
    }

    private static let faviconDiscoverySource = """
    (function() {
      var hrefs = [];
      Array.prototype.forEach.call(document.querySelectorAll('link[rel]'), function(link) {
        if ((link.rel || '').toLowerCase().indexOf('icon') === -1) return;
        if (link.href) hrefs.push(link.href);
      });
      if (hrefs.length === 0) hrefs.push(new URL('/favicon.ico', location.href).href);
      return JSON.stringify(hrefs);
    })()
    """

    private static func faviconImage(at url: URL) async -> NSImage? {
        let data: Data?
        if url.scheme?.lowercased() == "data" {
            guard let comma = url.absoluteString.firstIndex(of: ",") else { return nil }
            data = Data(base64Encoded: String(url.absoluteString[url.absoluteString.index(after: comma)...]))
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data else { return nil }
        if let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 { return image }
        return SVGFaviconRasterizer.image(from: data)
    }

    static let untroubledServerTrustDisposition = URLSession.AuthChallengeDisposition.useCredential

    static func challengeIsForMainDocument(_ space: URLProtectionSpace, documentURLs: [URL?]) -> Bool {
        documentURLs.contains { candidate in
            guard let url = candidate, url.scheme == "https" || url.scheme == "wss" else { return false }
            return url.host?.caseInsensitiveCompare(space.host) == .orderedSame && (url.port ?? 443) == space.port
        }
    }

    private static func certificateProblem(from challenge: URLAuthenticationChallenge) -> CertificateProblem? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return nil }
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        let leaf = chain.first
        let subject = leaf.flatMap { distinguishedName($0, oid: kSecOIDX509V1SubjectName) } ?? challenge.protectionSpace.host
        let issuer = leaf.flatMap { distinguishedName($0, oid: kSecOIDX509V1IssuerName) } ?? ""
        let dates = leaf.flatMap(validityDates)
        let trusted = SecTrustEvaluateWithError(trust, nil)
        let expired = (dates?.until).map { $0 < Date() } ?? false
        let notYetValid = (dates?.from).map { $0 > Date() } ?? false
        let code = (!trusted || !(expired || notYetValid)) ? -202 : -201
        if trusted && !expired && !notYetValid { return nil }
        return CertificateProblem(
            host: challenge.protectionSpace.host,
            issuer: issuer,
            subject: subject,
            validFrom: dates?.from,
            validUntil: dates?.until,
            reason: CertificateProblemReason.describe(errorCode: trusted ? code : -202, engineName: ""),
            errorCode: trusted ? code : -202,
            isOverridable: true
        )
    }

    static func distinguishedName(_ certificate: SecCertificate, oid: CFString) -> String? {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any],
              let entry = values[oid as String] as? [String: Any],
              let parts = entry[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return nil }
        for part in parts {
            let label = (part[kSecPropertyKeyLabel as String] as? String) ?? ""
            if label == "2.5.4.3" || label == "CN" || label.localizedCaseInsensitiveContains("Common Name") {
                return part[kSecPropertyKeyValue as String] as? String
            }
        }
        return nil
    }

    static func validityDates(_ certificate: SecCertificate) -> (from: Date?, until: Date?)? {
        let oids = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, oids, nil) as? [String: Any] else { return nil }
        return (
            dateValue(values[kSecOIDX509V1ValidityNotBefore as String]),
            dateValue(values[kSecOIDX509V1ValidityNotAfter as String])
        )
    }

    private static func dateValue(_ entry: Any?) -> Date? {
        guard let entry = entry as? [String: Any] else { return nil }
        let value = entry[kSecPropertyKeyValue as String]
        if let date = value as? Date { return date }
        if let interval = value as? TimeInterval { return Date(timeIntervalSinceReferenceDate: interval) }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }

    private func publishNavigation() {
        delegate?.webContentsDidChangeNavigationState(self)
    }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        // WebKitErrorFrameLoadInterruptedByPolicyChange: the load became a download.
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            navigationState.isLoading = false
            publishNavigation()
            return
        }
        navigationState.isLoading = false
        publishNavigation()
        delegate?.webContents(self, didFailLoading: EngineError(
            code: Self.errorCode(nsError),
            url: navigationState.url,
            underlyingDescription: nsError.localizedDescription
        ))
    }

    static func security(for url: URL, mixedContent: Bool = false) -> SecurityLevel {
        switch url.scheme?.lowercased() {
        case "https": return mixedContent ? .mixedContent : .secure
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

/// Stored per-origin decisions answer a permission request first; only unresolved kinds reach the prompt.
@MainActor
enum WebKitPermissionPolicy {
    enum Verdict: Equatable {
        case grant
        case deny
        case prompt(Set<PermissionKind>)
    }

    static func kinds(for type: WKMediaCaptureType) -> Set<PermissionKind> {
        switch type {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
        @unknown default: return [.camera, .microphone]
        }
    }

    static func url(for origin: WKSecurityOrigin) -> URL {
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        return components.url ?? URL(string: "about:blank")!
    }

    static func verdict(kinds: Set<PermissionKind>, origin: URL, session: WebKitSession) -> Verdict {
        var unresolved: Set<PermissionKind> = []
        for kind in kinds {
            switch session.contentSetting(kind, for: origin) {
            case .block: return .deny
            case .allow: continue
            case .ask, .unsupported: unresolved.insert(kind)
            }
        }
        return unresolved.isEmpty ? .grant : .prompt(unresolved)
    }

    static func resolve(
        kinds: Set<PermissionKind>,
        origin: URL,
        session: WebKitSession,
        prompt: (PermissionRequest) async -> PermissionDecision
    ) async -> Bool {
        switch verdict(kinds: kinds, origin: origin, session: session) {
        case .grant: return true
        case .deny: return false
        case .prompt(let unresolved):
            let decision = await prompt(PermissionRequest(kinds: unresolved, origin: origin))
            switch decision {
            case .allow: return true
            case .deny: return false
            case .allowAlways:
                for kind in unresolved { session.setContentSetting(.allow, for: kind, url: origin) }
                return true
            case .denyAlways:
                for kind in unresolved { session.setContentSetting(.block, for: kind, url: origin) }
                return false
            }
        }
    }
}

extension WebKitWebContents {
    func attachResourceLoadDelegate(_ view: WKWebView) {
        let setter = NSSelectorFromString("_setResourceLoadDelegate:")
        guard view.responds(to: setter) else { return }
        view.perform(setter, with: self)
    }

    func detachResourceLoadDelegate(_ view: WKWebView) {
        let setter = NSSelectorFromString("_setResourceLoadDelegate:")
        guard view.responds(to: setter) else { return }
        view.perform(setter, with: nil)
    }

    /// WebKit calls these on the private resource-load delegate. They are the only place a
    /// subresource's status and headers are visible, which chrome.webRequest needs.
    @objc(webView:resourceLoad:didSendRequest:)
    func webView(_ webView: WKWebView, resourceLoad info: NSObject, didSendRequest request: URLRequest) {
        guard let url = request.url else { return }
        let key = Self.resourceLoadKey(info)
        let record = Self.httpRecord(info: info, url: url, method: request.httpMethod ?? "GET")
        extras.httpWebRequests[key] = record
        engine.services.reportHTTPWebRequest(
            events: ["onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders"],
            record: record,
            contents: self
        )
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func webView(_ webView: WKWebView, resourceLoad info: NSObject, didReceiveResponse response: URLResponse) {
        let key = Self.resourceLoadKey(info)
        var record = extras.httpWebRequests[key] ?? Self.httpRecord(
            info: info,
            url: response.url ?? URL(string: "about:blank")!,
            method: "GET"
        )
        Self.fillResponse(&record, response)
        extras.httpWebRequests[key] = record
        engine.services.reportHTTPWebRequest(
            events: ["onHeadersReceived", "onResponseStarted"],
            record: record,
            contents: self
        )
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func webView(
        _ webView: WKWebView,
        resourceLoad info: NSObject,
        didCompleteWithError error: Error?,
        response: URLResponse?
    ) {
        let key = Self.resourceLoadKey(info)
        var record = extras.httpWebRequests.removeValue(forKey: key) ?? Self.httpRecord(
            info: info,
            url: response?.url ?? URL(string: "about:blank")!,
            method: "GET"
        )
        if let response { Self.fillResponse(&record, response) }
        if let error, Self.isTopFrame(info) {
            noteMainFrameFailure(error)
            engine.services.reportHTTPWebRequest(
                events: ["onErrorOccurred"],
                record: record,
                contents: self,
                error: "net::ERR_FAILED"
            )
        } else {
            engine.services.reportHTTPWebRequest(events: ["onCompleted"], record: record, contents: self)
        }
    }

    /// `document.cookie = "name=value; path=/"` is one assignment, not a cookie store snapshot.
    private static func httpCookie(fromDocumentAssignment raw: String, page: URL) -> HTTPCookie? {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let first = parts.first, let eq = first.firstIndex(of: "=") else { return nil }
        let name = String(first[..<eq])
        guard !name.isEmpty else { return nil }
        let value = String(first[first.index(after: eq)...])
        var domain = page.host ?? ""
        var path = "/"
        var expires: Date?
        var secure = false
        for attribute in parts.dropFirst() where !attribute.isEmpty {
            let bits = attribute.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let rawKey = bits.first else { continue }
            let key = rawKey.lowercased()
            let field = bits.count > 1 ? bits[1] : ""
            switch key {
            case "domain": domain = field
            case "path": path = field.isEmpty ? "/" : field
            case "secure": secure = true
            case "max-age":
                if let seconds = TimeInterval(field) { expires = Date().addingTimeInterval(seconds) }
            default: break
            }
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }

    private static func isTopFrame(_ info: NSObject) -> Bool {
        let parent = info.value(forKey: "parentFrame")
        return parent == nil || parent is NSNull
    }

    private static func resourceLoadKey(_ info: NSObject) -> UInt64 {
        (info.value(forKey: "resourceLoadID") as? NSNumber)?.uint64Value ?? 0
    }

    private static func httpRecord(info: NSObject, url: URL, method: String) -> WebKitContentsExtras.HTTPWebRequestRecord {
        let parent = info.value(forKey: "parentFrame")
        let isMainFrame = parent == nil || parent is NSNull
        let type = chromeResourceType(info, isMainFrame: isMainFrame)
        return WebKitContentsExtras.HTTPWebRequestRecord(
            requestID: String(resourceLoadKey(info)),
            url: url,
            method: method,
            type: type,
            frameID: isMainFrame ? 0 : 1,
            parentFrameID: isMainFrame ? -1 : 0,
            statusCode: nil,
            responseHeaders: []
        )
    }

    private static func fillResponse(_ record: inout WebKitContentsExtras.HTTPWebRequestRecord, _ response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        record.statusCode = http.statusCode
        if let url = response.url { record.url = url }
        record.responseHeaders = http.allHeaderFields.map { key, value in
            ["name": "\(key)", "value": "\(value)"]
        }
    }

    /// `_WKResourceLoadInfoResourceType` in declaration order. `other` is -1.
    private static func chromeResourceType(_ info: NSObject, isMainFrame: Bool) -> String {
        let raw = (info.value(forKey: "resourceType") as? NSNumber)?.intValue ?? -1
        switch raw {
        case 3: return isMainFrame ? "main_frame" : "sub_frame"
        case 10: return "script"
        case 11: return "stylesheet"
        case 4: return "image"
        case 6: return "font"
        case 8: return "object"
        case 5, 12: return "xmlhttprequest"
        case 1, 9: return "ping"
        case 2: return "csp_report"
        case 7: return "media"
        default: return "other"
        }
    }
}
