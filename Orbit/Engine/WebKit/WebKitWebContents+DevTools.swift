import AppKit
import WebKit

/// A host whose pane can take the inspector next to the page: WebKit docks by moving the inspector view
/// beside the page view and resizing both by hand, so the page must be laid out by autoresizing, not constraints.
final class InspectorDockSideRelay: NSObject, WKScriptMessageHandler {
    weak var contents: WebKitWebContents?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let sideName = message.body as? String, let side = DevToolsDockSide(rawValue: sideName) else { return }
        let contents = contents
        if Thread.isMainThread {
            MainActor.assumeIsolated { contents?.noteInspectorDockSide(side) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { contents?.noteInspectorDockSide(side) } }
        }
    }
}

final class InspectorDockHost: NSView {
    weak var contents: WebKitWebContents?

    override func layout() {
        super.layout()
        guard let contents else { return }
        MainActor.assumeIsolated {
            if contents.isDeveloperToolsDocked {
                contents.relayoutDockedInspector()
            } else if contents.webView.superview === self {
                contents.webView.translatesAutoresizingMaskIntoConstraints = true
                let device = InspectorDeviceMode.shared.preset(for: contents) != .desktop
                contents.webView.autoresizingMask = device ? [] : [.width, .height]
                contents.webView.frame = contents.devicePageRect(in: bounds)
            }
        }
    }
}

@MainActor
protocol InspectorDockableContents: AnyObject {
    func embedForInspectorDocking(in container: NSView)
}

/// The Web Inspector's own page, whether it is docked in the pane or in WebKit's separate window.
@MainActor
final class WebKitInspectorFrontend {
    let webView: WKWebView
    var view: NSView { webView }

    init(webView: WKWebView) { self.webView = webView }

    @discardableResult
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }
}

/// Where the inspector opens. A side chosen in the inspector's own dock buttons is written back here.
@MainActor
enum DevToolsDockPreference {
    private static let key = "orbit.devTools.dockSide"

    static var current: DevToolsDockSide {
        get { OrbitDefaults.standard.string(forKey: key).flatMap(DevToolsDockSide.init(rawValue:)) ?? .right }
        set { OrbitDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// One open inspector's dock steering. `attach` on `_WKInspector` always docks to the bottom, and the
/// object has no `isAttached` property, so the side the frontend requests is applied by laying the two
/// views out in the pane after WebKit has parented the inspector view there.
/// WebKit's own `open` still presents an `NSWindow` first: it only skips that window when its
/// `inspectorStartsAttached` preference is already set, and a fresh inspector's is not.
@MainActor
private final class InspectorDockSession {
    var requested: DevToolsDockSide
    var task: Task<Void, Never>?
    /// The dock-button hook is installed. Stays false until Orbit has applied its own side, so the
    /// frontend's boot `requestSetDockSide` (WebKit just opened detached, so this is "undocked") is not
    /// stored as the user's choice.
    var hooked = false
    var wrapReady = false
    /// The side last passed to `InspectorFrontendHost.requestSetDockSide`, so WebKit's own attachment
    /// side tracks the pane. Nil until the first command.
    var commanded: DevToolsDockSide?
    var stopped = false
    var applyingLayout = false

    init(requested: DevToolsDockSide) { self.requested = requested }
}

@MainActor
private enum InspectorDockSteering {
    static var sessions: [ObjectIdentifier: InspectorDockSession] = [:]
    static var windows: [ObjectIdentifier: NSWindow] = [:]
    static var windowWatch: [NSObjectProtocol] = []
    static var reparentScheduled: Set<ObjectIdentifier> = []
    static var concealing: Set<ObjectIdentifier> = []
    static var closedFrontendWatch: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    /// Installed when a pane takes the page, which is before Developer Tools can open, so the
    /// notification runs inside WebKit's `makeKeyAndOrderFront` and the window can be hidden
    /// before AppKit paints it.
    static func installWindowWatch() {
        guard windowWatch.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            windowWatch.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { WebKitWebContents.inspectorWindowOrderedFront(window) }
            })
        }
    }
}

extension WebKitWebContents: InspectorDockableContents {

    // MARK: - Hosting

    func embedForInspectorDocking(in container: NSView) {
        // Before any inspector can open: show() orders WebKit's window front, and this watch has to
        // already be in place so that order front can be undone before the window is drawn.
        InspectorDockSteering.installWindowWatch()
        // A pane owns the page now. The undocked-host watch would pull it back out of this container.
        stopUndockedPageHostWatch()
        inspectorReparentLock = false
        let dockHost = container.subviews.compactMap { $0 as? InspectorDockHost }.first ?? InspectorDockHost(frame: container.bounds)
        dockHost.contents = self
        if dockHost.superview !== container {
            dockHost.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(dockHost)
            NSLayoutConstraint.activate([
                dockHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                dockHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                dockHost.topAnchor.constraint(equalTo: container.topAnchor),
                dockHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        let view = webView
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = dockHost.bounds
        view.postsFrameChangedNotifications = true
        performInspectorReparent {
            dockHost.addSubview(view)
        }
        extras.hostContainer = dockHost
        dockHost.postsFrameChangedNotifications = true

        if let previous = extras.frameObserver { NotificationCenter.default.removeObserver(previous) }
        extras.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: dockHost, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutDockedInspector() }
        }

        // The inspector view stayed in the pane this page left: attach again so WebKit parents it
        // beside the page, then the steering loop lays that side out.
        if !inspectorCloseSuppressed, developerToolsAreOpen(), let session = dockSession, !session.stopped, session.requested != .undocked {
            reparentDockedInspectorIfNeeded()
            relayoutDockedInspector()
        }
    }

    /// True when the page sits in a pane that lays it out by hand, which is what lets the inspector dock.
    var canDockInspector: Bool {
        guard !isExtensionPage, let container = extras.hostContainer else { return false }
        return webView.superview === container && webView.window != nil
    }

    func scheduleHostedLayoutRestore() {
        stopDockSteering()
        // The docked frontend is a subview we added. WebKit's isVisible stays true after
        // close() until that view is gone, so waiting on it leaves the page shrunk.
        dropClosedFrontendFromPane()
        restorePageToFillContainer()
        watchClosedFrontend()
    }

    /// The frontend can be a view the inspector no longer reports, so the one Orbit cached is dropped too.
    private func dropClosedFrontendFromPane() {
        guard let container = extras.hostContainer else { return }
        for view in [inspectorFrontendWebView, extras.inspectorFrontend?.webView] {
            guard let view, view !== webView, view.superview === container else { continue }
            view.removeFromSuperview()
        }
    }

    /// WebKit parents the inspector view again while it tears down, so the pane is cleared on every
    /// reparent until the close has settled or a new inspector opens.
    private func watchClosedFrontend() {
        let key = ObjectIdentifier(self)
        let generation = inspectorCloseGeneration
        let views = [inspectorFrontendWebView, extras.inspectorFrontend?.webView].compactMap { $0 }
        var seen: [WKWebView] = []
        for view in views where !seen.contains(where: { $0 === view }) { seen.append(view) }
        InspectorDockSteering.closedFrontendWatch[key] = seen.map { view in
            view.observe(\.superview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard self.inspectorCloseGeneration == generation else {
                            InspectorDockSteering.closedFrontendWatch[key] = nil
                            return
                        }
                        guard !self.isClosed, self.inspectorCloseSuppressed else { return }
                        self.dropClosedFrontendFromPane()
                        self.restorePageToFillContainer()
                        self.restoreHostedLayout()
                    }
                }
            }
        }
        for delay in [0.1, 0.4, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed, self.inspectorCloseGeneration == generation else { return }
                    self.dropClosedFrontendFromPane()
                    self.restorePageToFillContainer()
                    self.restoreHostedLayout()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.inspectorCloseGeneration == generation else { return }
                InspectorDockSteering.closedFrontendWatch[key] = nil
            }
        }
    }

    // MARK: - State

    /// WebKit's inspector page, nil while no inspector exists.
    var inspectorFrontendWebView: WKWebView? {
        guard let inspector = webInspector() as? NSObject,
              inspector.responds(to: NSSelectorFromString("inspectorWebView"))
        else { return nil }
        return inspector.value(forKey: "inspectorWebView") as? WKWebView
    }

    var developerToolsFrontend: WebKitInspectorFrontend? {
        guard let view = inspectorFrontendWebView else {
            extras.inspectorFrontend = nil
            return nil
        }
        if let existing = extras.inspectorFrontend, existing.webView === view { return existing }
        let frontend = WebKitInspectorFrontend(webView: view)
        extras.inspectorFrontend = frontend
        return frontend
    }

    /// `_WKInspector` does not respond to `isAttached`. The inspector is docked when its page lives in
    /// this pane rather than in the separate Web Inspector window.
    var isDeveloperToolsDocked: Bool {
        guard developerToolsAreOpen(), let frontend = inspectorFrontendWebView, let container = extras.hostContainer else { return false }
        return frontend.window === container.window && frontend.isDescendant(of: container)
    }

    /// Read off the page's real frame inside its pane, since WebKit reports no side of its own.
    var developerToolsDockSide: DevToolsDockSide {
        guard developerToolsAreOpen(), isDeveloperToolsDocked, let container = extras.hostContainer,
              webView.superview === container
        else { return .undocked }
        return DevToolsDockState.inferredSide(pageBounds: webView.frame, in: container.bounds.size) ?? .bottom
    }

    func devToolsStateJSON() -> String {
        let inspector = webInspector()
        let open = developerToolsAreOpen()
        let frontend = inspectorFrontendWebView
        let loaded = frontend.map { !$0.isLoading && $0.url != nil } ?? false
        var state: [String: Any] = [
            "open": open,
            "docked": isDeveloperToolsDocked,
            "attached": inspector.map { Self.boolMessage($0, "isConnected") } ?? false,
            "dockDecided": loaded && (dockSession?.hooked == true),
            "responsesToFrontend": loaded ? 1 : 0,
            "dockSide": developerToolsDockSide.rawValue,
        ]
        if isDeveloperToolsDocked, let container = extras.hostContainer, webView.superview === container {
            let frame = webView.frame
            state["inspectedPageBounds"] = [
                "x": Int(frame.minX.rounded()),
                "y": Int((container.isFlipped ? frame.minY : container.bounds.height - frame.maxY).rounded()),
                "width": Int(frame.width.rounded()),
                "height": Int(frame.height.rounded()),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    // MARK: - Docking

    /// Opens docked to the stored side when a pane can take the inspector, otherwise in WebKit's own window.
    /// `show()` has already run and, unless WebKit was previously left attached, has ordered a separate
    /// window front. Hide that window and move the inspector into the pane before returning to the click
    /// that opened it; the steering loop finishes the job once the inspector page exists.
    func applyDeveloperToolsDock(_ inspector: NSObject) {
        InspectorDockSteering.installWindowWatch()
        let side = DevToolsDockPreference.current
        steerDock(side)
        guard side != .undocked else { return }
        embedInspectorBesideThePage()
    }

    /// Moves an open inspector to `side` and remembers it for the next one.
    func setDeveloperToolsDockSide(_ side: DevToolsDockSide) {
        DevToolsDockPreference.current = side
        guard developerToolsAreOpen(), webInspector() != nil else { return }
        steerDock(side)
    }

    /// A dock button in the inspector page. Arrives during that page's script call, before the test reads the preference back.
    /// The frontend also calls this while it boots, echoing the detached window WebKit just opened. That echo is not a choice:
    /// it is dropped until Orbit has applied the stored side and started accepting clicks.
    func noteInspectorDockSide(_ side: DevToolsDockSide) {
        guard let session = dockSession, !session.stopped, session.hooked else { return }
        guard side != session.requested else { return }
        DevToolsDockPreference.current = side
        session.requested = side
        session.commanded = nil
    }

    private var dockSession: InspectorDockSession? {
        InspectorDockSteering.sessions[ObjectIdentifier(self)]
    }

    private func steerDock(_ side: DevToolsDockSide) {
        let key = ObjectIdentifier(self)
        if let session = InspectorDockSteering.sessions[key], !session.stopped {
            session.requested = side
            session.commanded = nil
            return
        }
        let session = InspectorDockSession(requested: side)
        InspectorDockSteering.sessions[key] = session
        session.task = Task { @MainActor [weak self] in
            await self?.runDockSteering(session)
        }
    }

    private func stopDockSteering() {
        let key = ObjectIdentifier(self)
        guard let session = InspectorDockSteering.sessions.removeValue(forKey: key) else { return }
        session.stopped = true
        session.task?.cancel()
    }

    private func runDockSteering(_ session: InspectorDockSession) async {
        var seenOpen = false
        while !session.stopped, !Task.isCancelled, !isClosed {
            if developerToolsAreOpen() {
                seenOpen = true
                // Before any await: a window WebKit ordered front during `show()` is still on screen
                // until this moves the inspector into the pane.
                embedInspectorBesideThePage()
            } else if seenOpen {
                break
            } else {
                try? await Task.sleep(for: .milliseconds(80))
                continue
            }
            // A page with no pane keeps WebKit's own inspector window. Do not move the page
            // on this loop: a restore while the frontend is evaluating in the page removes it
            // from its window (`removedFromContainer`).
            if canDockInspector || isDeveloperToolsDocked {
                await installDockHookIfNeeded(session)
                await absorbFrontendDockRequest(session)
                await applyDockSide(session)
            } else {
                hostUndockedFrontendInWindow()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if dockSession === session { InspectorDockSteering.sessions[ObjectIdentifier(self)] = nil }
    }

    /// The inspector's dock buttons call `requestSetDockSide` on the global host. Wrapping that global is
    /// how a click in the frontend becomes the side Orbit remembers and lays out.
    private func installDockHookIfNeeded(_ session: InspectorDockSession) async {
        guard let frontend = developerToolsFrontend else { return }
        installDockSideRelay(on: frontend.webView)
        // A click in the inspector and Orbit's own command both call requestSetDockSide.
        // `__orbitSuppressDockEcho` keeps Orbit's command from being read back as a click.
        // The wrap is checked every pass: the inspector page reloads and drops an earlier assignment.
        let sideLiteral = JavaScriptLiteral.string(session.requested.rawValue)
        let clicksAccepted = session.hooked ? "true" : "false"
        let script = """
        (function() {
          window.__orbitDockSideLock = \(sideLiteral);
          if (\(clicksAccepted)) {
            window.__orbitDockClicksAccepted = true;
            window.__orbitDockLocked = false;
          } else if (!window.__orbitDockClicksAccepted) {
            window.__orbitDockLocked = true;
          }
          var host = (typeof InspectorFrontendHost !== 'undefined') ? InspectorFrontendHost : null;
          if (!host || typeof host.requestSetDockSide !== 'function') return 'wait';
          if (host.requestSetDockSide.__orbitWrapped) return 'ready';
          function remember(side) {
            if ((window.__orbitSuppressDockEcho || 0) > 0) return;
            try { window.__orbitRequestedDockSide = String(side); } catch (e) {}
            try { webkit.messageHandlers.orbitDockSide.postMessage(String(side)); } catch (e) {}
          }
          var orig = host.requestSetDockSide.bind(host);
          function wrapped(side) {
            var actual = String(side);
            // Boot traffic asks for the detached window WebKit just opened. Hold the stored side until
            // Orbit has applied it; a later call is a dock button and is remembered.
            if (window.__orbitDockLocked && window.__orbitDockSideLock && actual !== window.__orbitDockSideLock) {
              actual = window.__orbitDockSideLock;
            } else {
              remember(actual);
            }
            return orig(actual);
          }
          wrapped.__orbitWrapped = true;
          function assign(target) {
            try {
              Object.defineProperty(target, 'requestSetDockSide', { configurable: true, writable: true, value: wrapped });
            } catch (e) {
              try { target.requestSetDockSide = wrapped; } catch (e2) {}
            }
          }
          assign(host);
          try { var proto = Object.getPrototypeOf(host); if (proto) assign(proto); } catch (e) {}
          var live = false;
          try { live = !!(InspectorFrontendHost.requestSetDockSide && InspectorFrontendHost.requestSetDockSide.__orbitWrapped); } catch (e) { live = false; }
          if (!live) {
            var proxy = new Proxy(host, {
              get: function(target, prop) {
                if (prop === 'requestSetDockSide') return wrapped;
                try {
                  var value = target[prop];
                  return (typeof value === 'function') ? value.bind(target) : value;
                } catch (e) { return undefined; }
              },
              set: function(target, prop, value) {
                try { target[prop] = value; } catch (e) {}
                return true;
              }
            });
            try {
              Object.defineProperty(globalThis, 'InspectorFrontendHost', { configurable: true, value: proxy });
            } catch (e) {
              try { globalThis.InspectorFrontendHost = proxy; } catch (e2) {}
            }
            try { live = !!(InspectorFrontendHost.requestSetDockSide && InspectorFrontendHost.requestSetDockSide.__orbitWrapped); } catch (e) { live = false; }
          }
          if (!live) return 'wait';
          window.__orbitDockWrapped = true;
          return 'ready';
        })()
        """
        if let result = try? await frontend.evaluateJavaScript(script) as? String, result == "ready" {
            session.wrapReady = true
        }
    }

    private func installDockSideRelay(on frontend: WKWebView) {
        if extras.dockSideRelay == nil {
            let relay = InspectorDockSideRelay()
            relay.contents = self
            extras.dockSideRelay = relay
        }
        extras.dockSideRelay?.contents = self
        guard extras.dockRelayWebView !== frontend, let relay = extras.dockSideRelay else { return }
        frontend.configuration.userContentController.add(relay, name: "orbitDockSide")
        extras.dockRelayWebView = frontend
    }

    private func absorbFrontendDockRequest(_ session: InspectorDockSession) async {
        guard session.hooked, session.wrapReady, let frontend = developerToolsFrontend else { return }
        let script = """
        (function() {
          var side = window.__orbitRequestedDockSide || '';
          window.__orbitRequestedDockSide = '';
          return side;
        })()
        """
        guard let sideName = try? await frontend.evaluateJavaScript(script) as? String,
              let side = DevToolsDockSide(rawValue: sideName), side != session.requested else { return }
        session.requested = side
        DevToolsDockPreference.current = side
    }

    private func applyDockSide(_ session: InspectorDockSession) async {
        guard !session.stopped, developerToolsAreOpen(), let inspector = webInspector() as? NSObject else { return }
        let side = session.requested
        if side != .undocked {
            InspectorDockSteering.windows[ObjectIdentifier(self)]?.orderOut(nil)
            InspectorDockSteering.windows[ObjectIdentifier(self)] = nil
        }
        if side == .undocked || !canDockInspector {
            session.commanded = nil
            // Only pull a view we parented into the pane. Detach on a page that was never docked
            // takes WebKit's own inspector window apart while a script is running in it.
            if isDeveloperToolsDocked {
                undockInspector(inspector)
            }
            if session.wrapReady { await acceptFrontendDockClicks(session) }
            return
        }
        let wasDocked = isDeveloperToolsDocked
        reparentDockedInspectorIfNeeded()
        // WebKit's boot request detaches again after we have already told it the side. Ask once more.
        if !wasDocked { session.commanded = nil }
        guard !session.stopped, isDeveloperToolsDocked else { return }
        if session.commanded != side {
            await commandDockSide(side)
            guard !session.stopped else { return }
            session.commanded = side
        }
        layoutDockedInspector(side, session: session)
        concealOwnedInspectorWindows()
        if session.wrapReady { await acceptFrontendDockClicks(session) }
    }

    /// The stored side has been applied, so a dock button in the frontend is a real choice from here on.
    private func acceptFrontendDockClicks(_ session: InspectorDockSession) async {
        guard !session.hooked, session.wrapReady, developerToolsFrontend != nil else { return }
        if let frontend = developerToolsFrontend {
            _ = try? await frontend.evaluateJavaScript(
                "window.__orbitDockClicksAccepted = true; window.__orbitDockLocked = false; window.__orbitRequestedDockSide = '';"
            )
        }
        session.hooked = true
    }

    /// WebKit has ordered an inspector window forward. If this page should be docked, hide the window
    /// before AppKit paints it and move the inspector into the pane on the next turn. `attach` from
    /// inside `didBecomeKey` re-enters AppKit.
    fileprivate static func inspectorWindowOrderedFront(_ window: NSWindow) {
        guard window.isVisible || window.alphaValue > 0.01 else { return }
        for contents in WebKitLiveContents.all {
            guard window !== contents.webView.window, contents.wantsInspectorEmbedded else { continue }
            let holdsFrontend = contents.inspectorFrontendWebView?.window === window
            guard contents.ownsInspectorWindow(window) || holdsFrontend else { continue }
            contents.conceal(window)
            contents.scheduleInspectorEmbed()
        }
    }

    /// Docked when a pane can take the inspector and the stored side is not undocked. With no session yet
    /// (the window can appear inside `show()`, before steering starts) the stored preference decides.
    private var wantsInspectorEmbedded: Bool {
        guard !isClosed, !inspectorCloseSuppressed, !isExtensionPage, extras.hostContainer != nil else { return false }
        if let session = dockSession, !session.stopped {
            return session.requested != .undocked
        }
        guard DevToolsDockPreference.current != .undocked, developerToolsAreOpen() else { return false }
        return true
    }

    private func ownsInspectorWindow(_ window: NSWindow) -> Bool {
        guard window !== webView.window, window.title.hasPrefix("Web Inspector") else { return false }
        if let frontend = inspectorFrontendWebView {
            if frontend.window === window { return true }
            if let content = window.contentView, frontend.isDescendant(of: content) { return true }
        }
        if let url = navigationState.url?.absoluteString, !url.isEmpty, window.title.hasSuffix(url) {
            return true
        }
        return false
    }

    private func conceal(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard InspectorDockSteering.concealing.insert(key).inserted else { return }
        defer { InspectorDockSteering.concealing.remove(key) }
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0
        if window.isVisible { window.orderOut(nil) }
    }

    private func concealOwnedInspectorWindows() {
        guard wantsInspectorEmbedded else { return }
        for window in NSApp.windows where ownsInspectorWindow(window) {
            conceal(window)
        }
    }

    private func scheduleInspectorEmbed() {
        let key = ObjectIdentifier(self)
        guard InspectorDockSteering.reparentScheduled.insert(key).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                InspectorDockSteering.reparentScheduled.remove(key)
                self?.embedInspectorBesideThePage()
            }
        }
    }

    /// Puts the page back in its pane, parents the inspector beside it, and hides any window WebKit opened.
    private func embedInspectorBesideThePage() {
        guard wantsInspectorEmbedded else { return }
        keepPageInDockHost()
        inspectorReparentLock = true
        reparentDockedInspectorIfNeeded()
        let side = dockSession?.requested ?? DevToolsDockPreference.current
        if side != .undocked {
            layoutDockedInspector(side, session: dockSession)
        }
        concealOwnedInspectorWindows()
    }

    /// `show()` can pull the page into the inspector window before Orbit docks. The pane is the page's host.
    private func keepPageInDockHost() {
        guard let container = extras.hostContainer, !isExtensionPage else { return }
        guard webView.superview !== container else { return }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        performInspectorReparent {
            container.addSubview(webView)
            if inspectorFrontendWebView?.isDescendant(of: container) != true {
                webView.frame = container.bounds
            }
        }
    }

    /// `attach` puts the inspector view in the pane (WebKit's only attach is the bottom). Calling it
    /// again after the view is already there would reset that bottom layout over the side we just set.
    private func reparentDockedInspectorIfNeeded() {
        guard canDockInspector, let container = extras.hostContainer, let inspector = webInspector() as? NSObject,
              let frontend = inspectorFrontendWebView else { return }
        guard frontend.window !== container.window || !frontend.isDescendant(of: container) else { return }
        Self.voidMessage(inspector, "attach")
        guard frontend.window !== container.window || !frontend.isDescendant(of: container) else { return }
        frontend.removeFromSuperview()
        frontend.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(frontend, positioned: .below, relativeTo: webView)
    }

    private func inspectorWindowAwaitingFrontend() -> NSWindow? {
        NSApp.windows.first { $0 !== webView.window && $0.isVisible && $0.title.hasPrefix("Web Inspector") }
    }

    /// A page with no pane gets WebKit's own inspector window. Its frontend belongs in that window, not
    /// in the page's host window (WebKit attached it there) and not nowhere.
    private func hostUndockedFrontendInWindow() {
        guard !inspectorCloseSuppressed, !isClosed, developerToolsAreOpen(),
              let inspector = webInspector() as? NSObject, let frontend = inspectorFrontendWebView else { return }
        if let window = frontend.window, window.title.hasPrefix("Web Inspector") { return }
        let inPageWindow = webView.window != nil && frontend.window === webView.window
        let orphaned = frontend.window == nil && inspectorWindowAwaitingFrontend() != nil
        guard inPageWindow || orphaned else { return }
        undockInspector(inspector)
    }

    private func undockInspector(_ inspector: NSObject) {
        guard let frontend = inspectorFrontendWebView else { return }
        if frontend.superview != nil, frontend.window === webView.window {
            frontend.removeFromSuperview()
        }
        Self.voidMessage(inspector, "detach")
        Self.voidMessage(inspector, "show")
        if let window = frontend.window, window !== webView.window {
            // The dock path may have hidden WebKit's window without closing it. Bring that same window back.
            window.isExcludedFromWindowsMenu = false
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            InspectorDockSteering.windows[ObjectIdentifier(self)] = window
            restorePageToFillContainer()
            return
        }
        if frontend.window == nil || frontend.window === webView.window {
            let reused = inspectorWindowAwaitingFrontend()
            let window = reused ?? NSWindow(
                contentRect: NSRect(x: 240, y: 180, width: 900, height: 700),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            if reused == nil { window.title = "Web Inspector: \(navigationState.title)" }
            window.contentView = frontend
            window.isReleasedWhenClosed = false
            InspectorDockSteering.windows[ObjectIdentifier(self)] = window
            window.makeKeyAndOrderFront(nil)
        }
        restorePageToFillContainer()
    }

    private func commandDockSide(_ side: DevToolsDockSide) async {
        guard side != .undocked, let frontend = developerToolsFrontend else { return }
        let literal = JavaScriptLiteral.string(side.rawValue)
        _ = try? await frontend.evaluateJavaScript(
            "(function(){ if (typeof InspectorFrontendHost === 'undefined') { return false; } window.__orbitDockSideLock = \(literal); window.__orbitSuppressDockEcho = (window.__orbitSuppressDockEcho || 0) + 1; try { InspectorFrontendHost.requestSetDockSide(\(literal)); } finally { window.__orbitSuppressDockEcho--; } return true; })()"
        )
    }

    func relayoutDockedInspector() {
        guard !isClosed, developerToolsAreOpen(), canDockInspector, let session = dockSession, !session.stopped,
              !session.applyingLayout, session.requested != .undocked else { return }
        layoutDockedInspector(session.requested, session: session)
    }

    /// WebKit's attached-window constraints: 750×500 is the embedder default, clamped the way
    /// `constrainedAttachedWindowWidth` / `Height` clamp it (page keeps at least 320, inspector at least 250).
    private func layoutDockedInspector(_ side: DevToolsDockSide, session: InspectorDockSession?) {
        guard side != .undocked, let container = extras.hostContainer, let frontend = inspectorFrontendWebView,
              frontend.isDescendant(of: container), webView.superview === container else { return }
        let bounds = container.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        session?.applyingLayout = true
        defer { session?.applyingLayout = false }

        let pageFrame: NSRect
        let inspectorFrame: NSRect
        switch side {
        case .right:
            let width = dockedBreadth(preferred: 750, current: frontend.frame.width, total: bounds.width, minimum: 500, reserve: 320)
            inspectorFrame = NSRect(x: bounds.width - width, y: bounds.minY, width: width, height: bounds.height)
            pageFrame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width - width, height: bounds.height)
        case .left:
            let width = dockedBreadth(preferred: 750, current: frontend.frame.width, total: bounds.width, minimum: 500, reserve: 320)
            inspectorFrame = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
            pageFrame = NSRect(x: bounds.minX + width, y: bounds.minY, width: bounds.width - width, height: bounds.height)
        case .bottom:
            let height = dockedBreadth(preferred: 500, current: frontend.frame.height, total: bounds.height, minimum: 250, reserve: bounds.height * 0.25)
            inspectorFrame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
            pageFrame = NSRect(x: bounds.minX, y: bounds.minY + height, width: bounds.width, height: bounds.height - height)
        case .undocked:
            return
        }

        disableConstraints(on: webView, in: container)
        disableConstraints(on: frontend, in: container)
        webView.translatesAutoresizingMaskIntoConstraints = true
        frontend.translatesAutoresizingMaskIntoConstraints = true
        // Off while we own the split, so WebKit's frame observer does not snap the page back to the bottom dock.
        webView.postsFrameChangedNotifications = false
        frontend.postsFrameChangedNotifications = false
        let fittedPage = devicePageRect(in: pageFrame)
        if !framesMatch(webView.frame, fittedPage) { webView.frame = fittedPage }
        if !framesMatch(frontend.frame, inspectorFrame) { frontend.frame = inspectorFrame }
        let letterboxed = InspectorDeviceMode.shared.preset(for: self) != .desktop
        switch side {
        case .right:
            frontend.autoresizingMask = [.height, .minXMargin]
            webView.autoresizingMask = letterboxed ? [] : [.height, .maxXMargin]
        case .left:
            frontend.autoresizingMask = [.height, .maxXMargin]
            webView.autoresizingMask = letterboxed ? [] : [.height, .minXMargin]
        case .bottom:
            frontend.autoresizingMask = [.width, .maxYMargin]
            webView.autoresizingMask = letterboxed ? [] : [.width, .minYMargin]
        case .undocked:
            break
        }
    }

    /// `current` is kept when it is already a split (so a resize does not jump back to the default);
    /// `reserve` is the space the other view is not allowed to lose.
    private func dockedBreadth(preferred: CGFloat, current: CGFloat, total: CGFloat, minimum: CGFloat, reserve: CGFloat) -> CGFloat {
        let alreadySplit = current >= minimum && current <= total - min(reserve, total * 0.2)
        let chosen = alreadySplit ? current : preferred
        let ceiling = max(minimum, total - reserve)
        return min(max(minimum, chosen), ceiling)
    }

    private func restorePageToFillContainer() {
        guard let container = extras.hostContainer, webView.superview === container else { return }
        disableConstraints(on: webView, in: container)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.postsFrameChangedNotifications = false
        let fitted = devicePageRect(in: container.bounds)
        if !framesMatch(webView.frame, fitted) { webView.frame = fitted }
    }

    private func disableConstraints(on view: NSView, in container: NSView) {
        let affecting = container.constraints.filter { constraint in
            constraint.firstItem as AnyObject === view || constraint.secondItem as AnyObject === view
        }
        NSLayoutConstraint.deactivate(affecting)
    }

    func devicePageRect(in container: CGRect) -> CGRect {
        let mode = InspectorDeviceMode.shared
        let css = InspectorDeviceMode.cssSize(preset: mode.preset(for: self), responsiveWidth: mode.responsiveWidth(for: self))
        return InspectorDeviceMode.pageRect(cssSize: css, in: container)
    }

    private func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
}

/// Developer Mode screen sizes. The page's frame is the layout viewport, so a
/// chosen device is that size, centered in the pane. Desktop is the whole pane.
@MainActor
@Observable
final class InspectorDeviceMode {
    static let shared = InspectorDeviceMode()

    enum Preset: String, CaseIterable, Identifiable {
        case desktop
        case iPhone
        case iPad
        case responsive

        var id: String { rawValue }

        var title: String {
            switch self {
            case .desktop: return "Desktop"
            case .iPhone: return "iPhone"
            case .iPad: return "iPad"
            case .responsive: return "Responsive"
            }
        }

        static let devices: [Preset] = [.desktop, .iPhone, .iPad]
    }

    static let widths: [CGFloat] = [390, 768, 1024, 1280]

    private(set) var revision = 0
    private var presetByContents: [ObjectIdentifier: Preset] = [:]
    private var responsiveWidthByContents: [ObjectIdentifier: CGFloat] = [:]

    private init() {}

    func preset(for contents: WebKitWebContents) -> Preset {
        _ = revision
        return presetByContents[ObjectIdentifier(contents)] ?? .desktop
    }

    func responsiveWidth(for contents: WebKitWebContents) -> CGFloat {
        _ = revision
        return responsiveWidthByContents[ObjectIdentifier(contents)] ?? 768
    }

    func clearAll() {
        for contents in WebKitLiveContents.all {
            let key = ObjectIdentifier(contents)
            guard presetByContents.removeValue(forKey: key) != nil else { continue }
            applyUserAgent(for: .desktop, to: contents)
            contents.extras.hostContainer?.needsLayout = true
        }
        revision += 1
    }

    func setPreset(_ preset: Preset, for contents: WebKitWebContents) {
        let key = ObjectIdentifier(contents)
        if preset == .desktop {
            presetByContents.removeValue(forKey: key)
        } else {
            presetByContents[key] = preset
        }
        revision += 1
        applyUserAgent(for: preset, to: contents)
        contents.extras.hostContainer?.needsLayout = true
    }

    func setResponsiveWidth(_ width: CGFloat, for contents: WebKitWebContents) {
        responsiveWidthByContents[ObjectIdentifier(contents)] = min(1400, max(320, width))
        revision += 1
        contents.extras.hostContainer?.needsLayout = true
    }

    /// Nil means the web view's own identity. iPhone and iPad override it so the site can serve its mobile page; a responsive width keeps the desktop identity.
    static func userAgent(for preset: Preset) -> String? {
        switch preset {
        case .desktop, .responsive: return nil
        case .iPhone: return mobileUserAgent(platform: "iPhone; CPU iPhone OS 18_6 like Mac OS X")
        case .iPad: return mobileUserAgent(platform: "iPad; CPU OS 18_6 like Mac OS X")
        }
    }

    private static func mobileUserAgent(platform: String) -> String {
        let version = WebKitProduct.safariVersion ?? "18.6"
        return "Mozilla/5.0 (\(platform)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Mobile/15E148 Safari/604.1"
    }

    private func applyUserAgent(for preset: Preset, to contents: WebKitWebContents) {
        let resolved = Self.userAgent(for: preset) ?? contents.webKitSession.userAgent
        guard contents.webView.customUserAgent != resolved else { return }
        contents.webView.customUserAgent = resolved
        guard let url = contents.webView.url, url.scheme == "http" || url.scheme == "https" else { return }
        contents.reload(ignoringCache: false)
    }

    static func cssSize(preset: Preset, responsiveWidth: CGFloat) -> CGSize? {
        switch preset {
        case .desktop: return nil
        case .iPhone: return CGSize(width: 390, height: 844)
        case .iPad: return CGSize(width: 820, height: 1180)
        case .responsive:
            return CGSize(width: min(1400, max(320, responsiveWidth)), height: 0)
        }
    }

    /// The page rect inside `container`. Desktop is the whole container. A
    /// device is its CSS size, scaled down only when the pane is smaller.
    static func pageRect(cssSize: CGSize?, in container: CGRect) -> CGRect {
        guard let cssSize, cssSize.width > 1, container.width > 1, container.height > 1 else { return container }
        let height = cssSize.height > 1 ? cssSize.height : container.height
        let scale = min(1, container.width / cssSize.width, container.height / height)
        let fitted = CGSize(width: (cssSize.width * scale).rounded(.down), height: (height * scale).rounded(.down))
        return CGRect(
            x: (container.midX - fitted.width / 2).rounded(),
            y: (container.midY - fitted.height / 2).rounded(),
            width: fitted.width,
            height: fitted.height
        )
    }
}
