//  Owns one OrbitWebContentsHost and mirrors its navigation state; unimplemented
//  paths throw EngineError(.notImplemented) or no-op with a log line.

import AppKit
import Foundation
import OSLog

@MainActor
final class ChromiumWebContents: WebContents {

    let id = UUID()
    let session: EngineSession
    weak var delegate: WebContentsDelegate?

    private(set) var navigationState: NavigationState = .empty
    private(set) var mediaState: MediaState = .idle
    private(set) var zoomFactor: Double = 1.0
    private(set) var isClosed = false

    private let bridge = OrbitChromiumBridge.shared
    private lazy var webStorePrivateBridge = WebStorePrivateBridge()
    private let handle: UnsafeMutableRawPointer
    private let hostView: NSView
    private var devTools: DevToolsSession?

    // nil until the browser has reported a Picture-in-Picture edge for this
    // tab at all; after that it is the only source of truth for
    // MediaState.isPictureInPictureActive.
    private var nativePictureInPictureActive: Bool?

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "ChromiumWebContents")

    init(session: EngineSession, initialURL: URL?) throws {
        self.session = session
        self.handle = try bridge.makeWebContentsHandle()
        guard let view = bridge.nativeView(handle) else {
            bridge.destroyWebContents(handle)
            throw EngineError(
                code: .engineUnavailable,
                underlyingDescription: "OrbitWebContentsGetNativeView returned NULL"
            )
        }
        self.hostView = view
        installCallbacks()

        if let initialURL {
            load(initialURL)
        }
    }

    /// Wraps a handle content:: already built (an adopted extension window.open()).
    /// Does not call makeWebContentsHandle() or load(_:): it's already mid-navigation.
    init(adopting handle: UnsafeMutableRawPointer, session: EngineSession) throws {
        self.session = session
        self.handle = handle
        guard let view = bridge.nativeView(handle) else {
            bridge.destroyWebContents(handle)
            throw EngineError(
                code: .engineUnavailable,
                underlyingDescription: "OrbitWebContentsGetNativeView returned NULL"
            )
        }
        self.hostView = view
        installCallbacks()
    }

    private func installCallbacks() {
        var callbacks = OrbitWebContentsCallbacksLayout()
        callbacks.navigationStateChanged = ChromiumWebContents.navigationStateChangedTrampoline
        callbacks.loadProgressChanged = ChromiumWebContents.loadProgressChangedTrampoline
        callbacks.titleChanged = ChromiumWebContents.titleChangedTrampoline
        callbacks.didCommit = ChromiumWebContents.didCommitTrampoline
        callbacks.didFinish = ChromiumWebContents.didFinishTrampoline
        callbacks.didFail = ChromiumWebContents.didFailTrampoline
        callbacks.didReceiveScriptMessage = ChromiumWebContents.didReceiveScriptMessageTrampoline
        callbacks.findResultChanged = ChromiumWebContents.findResultChangedTrampoline
        callbacks.zoomFactorChanged = ChromiumWebContents.zoomFactorChangedTrampoline
        callbacks.preferredSizeChanged = ChromiumWebContents.preferredSizeChangedTrampoline
        callbacks.willBeginDownload = ChromiumWebContents.willBeginDownloadTrampoline
        callbacks.downloadProgressChanged = ChromiumWebContents.downloadProgressChangedTrampoline
        callbacks.requestPermission = ChromiumWebContents.requestPermissionTrampoline
        callbacks.nativeExtensionRequest = ChromiumWebContents.nativeExtensionRequestTrampoline
        callbacks.devtoolsClosed = ChromiumWebContents.devtoolsClosedTrampoline
        callbacks.devtoolsDockedChanged = ChromiumWebContents.devtoolsDockedChangedTrampoline
        callbacks.devtoolsInspectedPageBounds = ChromiumWebContents.devtoolsInspectedPageBoundsTrampoline
        callbacks.devtoolsCloseRequested = ChromiumWebContents.devtoolsCloseRequestedTrampoline
        callbacks.devtoolsBringToFront = ChromiumWebContents.devtoolsBringToFrontTrampoline
        callbacks.showContextMenu = ChromiumWebContents.showContextMenuTrampoline
        callbacks.pictureInPictureChanged = ChromiumWebContents.pictureInPictureChangedTrampoline
        callbacks.faviconChanged = ChromiumWebContents.faviconChangedTrampoline
        callbacks.activationRequested = ChromiumWebContents.activationRequestedTrampoline
        callbacks.pictureInPictureAvailableChanged = ChromiumWebContents.pictureInPictureAvailableChangedTrampoline
        // opaque is filled in last so no callback sees a half-built struct.
        // Retained, not unretained: the engine keeps calling back until close()
        // destroys it, so dropping this without closing it would dangle.
        callbacks.opaque = Unmanaged.passRetained(self).toOpaque()
        bridge.setCallbacks(handle, callbacks)

        // Seeds the state for a handle that already has a candidate the moment
        // callbacks attach (an adopted window.open() handle) -- otherwise there is
        // nothing to trigger the "changed" edge that picture_in_picture_available_changed
        // reports.
        mediaState.isPictureInPictureAvailable = bridge.hasPictureInPictureCandidate(handle)

        // Registered before anything can navigate, so a certificate error on
        // this tab's very first load already resolves to an instance.
        ChromiumWebContents.contentsByHandle[handle] = WeakContentsBox(self)
        _ = ChromiumWebContents.installCertificateErrorCallbackOnce
        _ = ChromiumWebContents.installNewContentRequestCallbackOnce
    }

    var view: NSView { hostView }

    // Module-internal, not private: OrbitChromiumTabsBridge needs the raw handle;
    // the one place the Chromium/non-Chromium distinction leaks out of WebContents.
    var chromiumHandle: UnsafeMutableRawPointer { handle }

    // MARK: - Navigation

    func load(_ url: URL) {
        guard !isClosed else { return }
        bridge.loadURL(handle, url.absoluteString)
    }

    func loadHTML(_ html: String, baseURL: URL?) {
        guard !isClosed else { return }
        bridge.loadHTML(handle, html: html, baseURL: baseURL?.absoluteString ?? "")
    }

    func reload(ignoringCache: Bool) {
        guard !isClosed else { return }
        bridge.reload(handle, bypassCache: ignoringCache)
    }

    func stopLoading() {
        guard !isClosed else { return }
        bridge.stop(handle)
    }

    func goBack() {
        guard !isClosed else { return }
        bridge.goBack(handle)
    }

    func goForward() {
        guard !isClosed else { return }
        bridge.goForward(handle)
    }

    func go(offset: Int) {
        guard !isClosed else { return }
        bridge.goToOffset(handle, offset)
    }

    func sessionHistory() -> [SessionHistoryEntry] {
        let json = bridge.sessionHistoryJSON(handle)
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["id"] as? Int,
                  let urlString = entry["url"] as? String,
                  let url = URL(string: urlString),
                  let title = entry["title"] as? String,
                  let offset = entry["offset"] as? Int
            else { return nil }
            return SessionHistoryEntry(id: id, url: url, title: title, offset: offset)
        }
    }

    func extensionContextMenuGroups() -> [ExtensionContextMenuGroup] {
        guard !isClosed else { return [] }
        return ExtensionContextMenuGroup.decode(json: bridge.extensionContextMenuJSON(handle))
    }

    func performExtensionContextMenuItem(_ id: ExtensionContextMenuItemID) {
        guard !isClosed else { return }
        bridge.executeExtensionContextMenuItem(
            handle, extensionID: id.extensionID, uid: id.uid, stringUID: id.stringUID
        )
    }

    func currentCertificate() -> SiteCertificate? {
        nil
    }

    // MARK: - Scripting

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await evaluateJavaScript(script, inIsolatedWorld: false)
    }

    /// Not part of the `WebContents` protocol; opts into the isolated world
    /// (invisible to and unshadowable by the page).
    func evaluateJavaScript(_ script: String, inIsolatedWorld: Bool) async throws -> Any? {
        try await evaluateJavaScript(script, inIsolatedWorld: inIsolatedWorld, userGesture: false)
    }

    /// `userGesture` fakes a transient user activation for the script, which
    /// is the only way a test process can reach an API gated on one --
    /// chrome.permissions.request. No Orbit UI path passes true.
    func evaluateJavaScript(_ script: String, userGesture: Bool) async throws -> Any? {
        try await evaluateJavaScript(script, inIsolatedWorld: false, userGesture: userGesture)
    }

    func evaluateJavaScript(
        _ script: String, inIsolatedWorld: Bool, userGesture: Bool
    ) async throws -> Any? {
        guard !isClosed else {
            throw EngineError(code: .cancelled, underlyingDescription: "WebContents is closed")
        }
        let (success, resultJSON, errorMessage) = await bridge.evaluateJavaScript(
            handle, script: script, world: inIsolatedWorld ? 1 : 0, userGesture: userGesture
        )
        guard success else {
            throw EngineError(code: .engineUnavailable, underlyingDescription: errorMessage)
        }
        guard let resultJSON, !resultJSON.isEmpty, resultJSON != "null" else { return nil }
        guard let data = resultJSON.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func injectUserScript(_ script: UserScript) {
        guard !isClosed else { return }
        guard let data = try? JSONEncoder().encode(script), let json = String(data: data, encoding: .utf8) else {
            Self.logger.error("failed to encode UserScript \(script.id, privacy: .public) for injectUserScript")
            return
        }
        bridge.injectUserScript(handle, json: json)
    }

    // MARK: - Find in page

    func find(_ text: String, options: FindOptions) {
        guard !isClosed else { return }
        bridge.find(handle, text: text, forward: options.forward, matchCase: options.matchCase, findNext: options.findNext)
    }

    func stopFinding(clearSelection: Bool) {
        guard !isClosed else { return }
        // FindOptions has no "activate the current match" case to map to
        // blink::mojom::StopFindAction's third value, so this is Bool-shaped.
        bridge.stopFinding(handle, action: clearSelection ? 0 : 1)
    }

    // MARK: - Editing

    func cut() {
        guard !isClosed else { return }
        bridge.cut(handle)
    }

    func copy() {
        guard !isClosed else { return }
        bridge.copy(handle)
    }

    func paste() {
        guard !isClosed else { return }
        bridge.paste(handle)
    }

    func selectAll() {
        guard !isClosed else { return }
        bridge.selectAll(handle)
    }

    // MARK: - Zoom

    func setZoomFactor(_ factor: Double) {
        guard !isClosed else { return }
        bridge.setZoomFactor(handle, factor)
    }

    // MARK: - Content sizing

    func enableContentSizing(minimum: CGSize, maximum: CGSize) {
        guard !isClosed else { return }
        bridge.enableAutoResize(handle, minimum: minimum, maximum: maximum)
    }

    // MARK: - Colour scheme

    func setPreferredColorScheme(_ scheme: ContentColorScheme?) {
        Self.logger.notice("setPreferredColorScheme not implemented yet")
    }

    // MARK: - Media

    /// No native `OrbitWebContentsSetMuted` exists in the bridge, so this
    /// drives the page's own elements through the shared media-session
    /// observer's `__orbitDesiredMuted` flag, which also keeps enforcing it
    /// against later events and newly added elements.
    func setMuted(_ muted: Bool) {
        guard !isClosed else { return }
        mediaState.isMuted = muted
        Task { [weak self] in
            do {
                _ = try await self?.evaluateJavaScript(MediaSessionObserverScript.setDesiredMuted(muted))
            } catch {
                Self.logger.error("setMuted(\(muted, privacy: .public)) failed to reach the page: \(error, privacy: .public)")
            }
        }
    }

    func togglePictureInPicture() {
        guard !isClosed else { return }
        guard bridge.supportsPictureInPicture else {
            Self.logger.notice("togglePictureInPicture: this Orbit Framework build does not export OrbitWebContentsTogglePictureInPicture")
            return
        }
        if !bridge.togglePictureInPicture(handle) {
            Self.logger.notice("togglePictureInPicture: this page has no live video player, so nothing was toggled")
        }
    }

    /// content::WebContents::HasPictureInPictureVideo -- the browser's own
    /// answer, independent of `mediaState`.
    var hasPictureInPictureVideo: Bool {
        guard !isClosed else { return false }
        return bridge.hasPictureInPictureVideo(handle)
    }

    // MARK: - Presentation

    func setVisible(_ visible: Bool) {
        guard !isClosed else { return }
        bridge.setVisible(handle, visible)
    }

    func capturePreview(rect: CGRect?, size: CGSize) async -> NSImage? {
        guard !isClosed else { return nil }
        return await bridge.capturePreview(handle, rect: rect, size: size)
    }

    // No printing API/print-preview dialog at this layer; printing the whole
    // document to a PDF in Downloads is the honest version available.
    func print() {
        guard !isClosed else { return }
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            Self.logger.error("print: no Downloads directory available")
            return
        }
        let base = ChromiumWebContents.sanitizedFileName(
            from: navigationState.title.isEmpty ? (navigationState.url?.host ?? "page") : navigationState.title
        )
        let targetURL = ChromiumWebContents.uniqueFileURL(inDirectory: downloadsURL, baseName: base, pathExtension: "pdf")
        Task { [bridge, handle] in
            guard await bridge.printToPdf(handle, targetPath: targetURL.path) else {
                Self.logger.error("print: OrbitWebContentsPrintToPdf failed for \(targetURL.path, privacy: .public)")
                return
            }
        }
    }

    func savePage() {
        guard !isClosed else { return }
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            Self.logger.error("savePage: no Downloads directory available")
            return
        }
        let base = ChromiumWebContents.sanitizedFileName(
            from: navigationState.title.isEmpty ? (navigationState.url?.host ?? "page") : navigationState.title
        )
        let targetURL = ChromiumWebContents.uniqueFileURL(inDirectory: downloadsURL, baseName: base, pathExtension: "mhtml")
        bridge.savePage(handle, targetPath: targetURL.path)
    }

    // MARK: - Downloads

    // Browser-context-scoped, not tied to `handle`: a download outlives its tab,
    // so AppEnvironment broadcasts to every open tab and the rest are no-ops.
    func cancelDownload(id: UUID) {
        bridge.cancelDownload(id: id.uuidString)
    }

    // MARK: - Developer tools

    // One open inspector, docked into the tab's own pane or its own window;
    // neither is a tab surface, so the frontend is never registered as one.
    private final class DevToolsSession {
        let frontend: ChromiumWebContents
        var window: DevToolsWindowController?
        var isDocked = false

        init(frontend: ChromiumWebContents) {
            self.frontend = frontend
        }
    }

    func showDeveloperTools(inspectAt point: CGPoint?) {
        guard !isClosed else { return }

        // Before the frontend loads: it reads prefers-color-scheme as it boots,
        // and an inspector that opened light and corrected itself a frame later
        // is a visible flash.
        EngineAppearance.apply()

        if devTools != nil {
            if let point {
                bridge.inspectElementAt(handle, x: Int32(point.x.rounded()), y: Int32(point.y.rounded()))
            }
            revealDeveloperTools()
            return
        }

        guard let frontendHandle = bridge.openDevTools(
            handle,
            hasInspectPoint: point != nil,
            x: Int32(point?.x.rounded() ?? 0),
            y: Int32(point?.y.rounded() ?? 0)
        ) else {
            Self.logger.error("OrbitWebContentsOpenDevTools returned NULL for \(self.navigationState.url?.absoluteString ?? "<no url>", privacy: .public)")
            return
        }

        let frontendContents: ChromiumWebContents
        do {
            frontendContents = try ChromiumWebContents(adopting: frontendHandle, session: session)
        } catch {
            Self.logger.error("failed to wrap the DevTools frontend WebContents: \(String(describing: error), privacy: .public)")
            return
        }

        // Nothing presented here on purpose: presenting before devtools_docked_changed
        // would flash a window for an inspector about to dock.
        devTools = DevToolsSession(frontend: frontendContents)
    }

    func closeDeveloperTools() {
        tearDownDeveloperTools()
    }

    /// Diagnostic-only: proves the frontend actually attached, not just that a window exists.
    func devToolsStateJSON() -> String {
        bridge.devToolsStateJSON(handle)
    }

    /// The open inspector's own frontend WebContents, or nil when none is
    /// open, docked or undocked alike. Not a second reference to own -- this
    /// tab destroys it, per OrbitWebContentsOpenDevTools' contract.
    var developerToolsFrontend: ChromiumWebContents? {
        devTools?.frontend
    }

    /// Whether the open inspector is currently docked into this tab's pane.
    var isDeveloperToolsDocked: Bool {
        devTools?.isDocked ?? false
    }

    private func revealDeveloperTools() {
        guard let devTools else { return }
        if devTools.isDocked {
            devTools.frontend.focus()
        } else {
            devTools.window?.show()
        }
    }

    // devtools_docked_changed: the frontend's own Dock side menu, or the side
    // it had stored, replayed on load. The two surfaces are exclusive, and the
    // frontend's view moves between them rather than being rebuilt.
    private func handleDevToolsDockedChanged(_ isDocked: Bool) {
        guard let devTools, !isClosed else { return }
        devTools.isDocked = isDocked

        guard isDocked else {
            DevToolsDockState.shared.undock(self)
            if devTools.window == nil {
                let controller = DevToolsWindowController.open(
                    frontend: devTools.frontend, inspectedTitle: navigationState.title
                )
                controller.onClose = { [weak self] in self?.tearDownDeveloperTools() }
                devTools.window = controller
            }
            devTools.window?.show()
            return
        }

        devTools.window?.relinquishFrontend()
        devTools.window = nil
        DevToolsDockState.shared.dock(frontend: devTools.frontend, for: self)
    }

    // devtools_inspected_page_bounds: where the page goes on top of the docked
    // frontend. Meaningless while undocked, and the frontend does not send it
    // then either.
    private func handleDevToolsInspectedPageBounds(_ bounds: CGRect, hidesPage: Bool) {
        guard devTools != nil else { return }
        DevToolsDockState.shared.setInspectedPageBounds(bounds, hidesPage: hidesPage, for: self)
    }

    // devtools_closed fired: the inspector lost its DevToolsAgentHost for a
    // reason Swift did not ask for. Tear down the same way a user-initiated
    // close would.
    private func handleDevToolsClosed() {
        tearDownDeveloperTools()
    }

    // The inspector's own close button (devtools_close_requested), which is
    // the only close affordance a docked inspector has.
    private func handleDevToolsCloseRequested() {
        tearDownDeveloperTools()
    }

    private func handleDevToolsBringToFront() {
        revealDeveloperTools()
    }

    /// The one teardown path: drops the docked pane's claim first, then
    /// destroys the frontend handle, closing the inspector for good.
    private func tearDownDeveloperTools() {
        guard let session = devTools else { return }
        devTools = nil
        DevToolsDockState.shared.undock(self)
        // Explicit: a superview outlives its WebContents, so a frontend destroyed
        // while parented would leave a dead subview nothing ever removes.
        session.frontend.view.removeFromSuperview()
        if let window = session.window {
            window.onClose = nil
            window.close()
        } else {
            session.frontend.close()
        }
    }

    // MARK: - Focus

    func focus() {
        guard !isClosed else { return }
        bridge.focus(handle)
    }

    // MARK: - Lifetime

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // devtools_closed is never fired for this tab's own destruction (see
        // OrbitWebContentsCallbacks.devtools_closed's own comment) -- Swift
        // must proactively close the inspector rather than rely on it.
        tearDownDeveloperTools()
        // Before the handle stops being valid: nothing must be able to answer
        // a certificate error through it afterwards.
        ChromiumWebContents.contentsByHandle.removeValue(forKey: handle)
        bridge.destroyWebContents(handle)
        // Balances installCallbacks()'s passRetained, and only after the host
        // that holds that opaque pointer is gone.
        Unmanaged.passUnretained(self).release()
    }

    // MARK: - Callback handling

    private func applyNavigationState(_ mutate: (inout NavigationState) -> Void) {
        mutate(&navigationState)
        delegate?.webContentsDidChangeNavigationState(self)
    }

    private func handleNavigationStateChanged(isLoading: Bool, canGoBack: Bool, canGoForward: Bool, url: String?) {
        applyNavigationState { state in
            state.isLoading = isLoading
            state.canGoBack = canGoBack
            state.canGoForward = canGoForward
            if let url, let parsed = URL(string: url) {
                state.url = parsed
                state.security = ChromiumWebContents.securityLevel(for: parsed)
            }
        }
    }

    private func handleLoadProgressChanged(_ progress: Double) {
        applyNavigationState { $0.progress = progress }
    }

    private func handleTitleChanged(_ title: String) {
        applyNavigationState { $0.title = title }
        devTools?.window?.updateTitle(inspectedTitle: title)
        delegate?.webContents(self, didChangeTitle: title)
    }

    private func handleDidCommit(url: String, kind: NavigationKind) {
        guard let parsed = URL(string: url) else { return }
        applyNavigationState { state in
            state.url = parsed
            state.security = ChromiumWebContents.securityLevel(for: parsed)
        }
        delegate?.webContents(self, didCommitNavigationTo: parsed, kind: kind)
    }

    private func applyMediaState(_ updated: MediaState) {
        guard updated != mediaState else { return }
        mediaState = updated
        delegate?.webContents(self, didChangeMediaState: updated)
    }

    // OrbitWebContentsCallbacksLayout.pictureInPictureChanged: the browser's
    // own entered/left edge, which outranks the observer script's polled
    // reading from here on -- see handleScriptMessage.
    private func handlePictureInPictureChanged(_ isActive: Bool) {
        nativePictureInPictureActive = isActive
        var updated = mediaState
        updated.isPictureInPictureActive = isActive
        // A tab closed while still floating reports this from inside close();
        // record it, but never hand a half-destroyed tab to the delegate.
        guard !isClosed else {
            mediaState = updated
            return
        }
        applyMediaState(updated)
    }

    // OrbitWebContentsCallbacksLayout.pictureInPictureAvailableChanged: the
    // native, frame-agnostic answer to "would togglePictureInPicture() find
    // something to float right now" -- what canDrivePictureInPicture(for:)
    // gates on. Never derive this from the page-side hasVideo scan, which is
    // main-frame-only and misses an iframe-hosted player.
    private func handlePictureInPictureAvailableChanged(_ isAvailable: Bool) {
        var updated = mediaState
        updated.isPictureInPictureAvailable = isAvailable
        guard !isClosed else {
            mediaState = updated
            return
        }
        applyMediaState(updated)
    }

    // OrbitWebContentsCallbacksLayout.activationRequested: content:: asked
    // this tab's own WebContents to become active, e.g. the PiP window's
    // "back to tab" control. Distinct from picture_in_picture_changed --
    // that fires for both PiP buttons, this only for the one that means "go
    // to the tab".
    private func handleActivationRequested() {
        guard !isClosed else { return }
        delegate?.webContentsDidRequestActivation(self)
    }

    // `iconURL` can be a data: URL; the already-decoded image is what matters here.
    private func handleFaviconChanged(iconURL: String?, image: NSImage?) {
        guard !isClosed else { return }
        delegate?.webContents(self, didChangeFavicon: image, url: iconURL.flatMap(URL.init(string:)))
    }

    private func handleDidFinish(url: String, statusCode: Int) {
        guard let parsed = URL(string: url) else { return }
        delegate?.webContents(self, didFinishLoading: parsed, statusCode: statusCode)
    }

    // The one place every document-start *ObserverScript payload lands.
    private func handleScriptMessage(channel: String, json: String) {
        switch channel {
        case MediaSessionObserverScript.channelName:
            var updated = MediaSessionObserverScript.apply(payloadJSON: json, to: mediaState)
            // The script polls every 2s, so a payload posted before a native
            // transition can land after it and would otherwise undo it.
            if let nativePictureInPictureActive {
                updated.isPictureInPictureActive = nativePictureInPictureActive
            }
            applyMediaState(updated)

        case PageColorObserverScript.channelName:
            guard let reading = PageColorObserverScript.decode(payloadJSON: json) else { return }
            delegate?.webContents(self, didChangeThemeColor: reading.color)
            delegate?.webContents(self, didChangeDocumentColor: reading.documentColor)

        case LinkHoverObserverScript.channelName:
            delegate?.webContents(self, didHoverLink: LinkHoverObserverScript.decode(payloadJSON: json))

        default:
            break
        }
    }

    /// A native chrome.webstorePrivate call, re-wrapped into the payload shape
    /// WebStorePrivateBridge.handle(payload:contents:) expects.
    private static let malformedNativeExtensionRequestJSON =
        "{\"ok\":false,\"error\":{\"message\":\"Malformed request from the native extension bridge.\"}}"

    private func handleNativeExtensionRequest(requestID: String, method: String, argsJSON: String) {
        let argsArray = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [Any] ?? []
        let payload: [String: Any] = [
            "requestId": requestID, "api": "webstorePrivate", "method": method, "args": argsArray,
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8)
        else {
            bridge.respondToExtensionRequest(
                handle, requestID: requestID, resultJSON: Self.malformedNativeExtensionRequestJSON
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let resultJSON = await self.webStorePrivateBridge.handle(payload: payloadJSON, contents: self)?.resultJSON
                ?? Self.malformedNativeExtensionRequestJSON
            self.bridge.respondToExtensionRequest(self.handle, requestID: requestID, resultJSON: resultJSON)
        }
    }

    private func handleDidFail(url: String, errorCode: Int32, description: String) {
        let error = EngineError(
            code: ChromiumWebContents.engineErrorCode(forNetError: errorCode),
            url: URL(string: url),
            underlyingDescription: description
        )
        delegate?.webContents(self, didFailLoading: error)
    }

    private func handleFindResultChanged(activeMatchOrdinal: Int32, matchCount: Int32, isFinalUpdate: Bool) {
        delegate?.webContents(
            self,
            didUpdateFindResult: FindResult(
                activeMatchOrdinal: Int(activeMatchOrdinal), matchCount: Int(matchCount), isFinalUpdate: isFinalUpdate
            )
        )
    }

    private func handleZoomFactorChanged(_ factor: Double) {
        zoomFactor = factor
        delegate?.webContents(self, didChangeZoomFactor: factor)
    }

    private func handlePreferredSizeChanged(_ size: CGSize) {
        delegate?.webContents(self, didChangePreferredSize: size)
    }

    // Decodes into a ContextMenuContext and hands it to the delegate; this
    // layer never presents anything itself.
    private func handleShowContextMenu(
        pageURL: String, frameURL: String, linkURL: String, unfilteredLinkURL: String, sourceURL: String,
        titleText: String, selectionText: String, mediaType: Int32, isEditable: Bool,
        misspelledWord: String, dictionarySuggestionsJSON: String, x: Int32, y: Int32
    ) {
        let suggestions: [String] = {
            guard let data = dictionarySuggestionsJSON.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return [] }
            return raw
        }()
        let context = ContextMenuContext(
            pageURL: pageURL.isEmpty ? nil : URL(string: pageURL),
            frameURL: frameURL.isEmpty ? nil : URL(string: frameURL),
            linkURL: linkURL.isEmpty ? nil : URL(string: linkURL),
            unfilteredLinkURL: unfilteredLinkURL.isEmpty ? nil : URL(string: unfilteredLinkURL),
            sourceURL: sourceURL.isEmpty ? nil : URL(string: sourceURL),
            titleText: titleText.isEmpty ? nil : titleText,
            selectionText: selectionText.isEmpty ? nil : selectionText,
            mediaKind: ChromiumWebContents.mediaKind(from: mediaType),
            isEditable: isEditable,
            misspelledWord: misspelledWord.isEmpty ? nil : misspelledWord,
            dictionarySuggestions: suggestions,
            location: CGPoint(x: Int(x), y: Int(y))
        )
        _ = delegate?.webContents(self, showContextMenu: context)
    }

    // Mirrors blink::mojom::ContextMenuDataMediaType's declaration order --
    // see orbit_bridge_api.h's show_context_menu field comment.
    nonisolated private static func mediaKind(from raw: Int32) -> ContextMenuContext.MediaKind {
        switch raw {
        case 1: return .image
        case 2: return .video
        case 3: return .audio
        case 4: return .canvas
        case 5: return .file
        case 6: return .plugin
        default: return .none
        }
    }

    private func handleDownloadProgressChanged(downloadID: UUID, receivedBytes: Int64, totalBytes: Int64, state: Int32) {
        delegate?.webContents(
            self, download: downloadID,
            didUpdate: DownloadProgress(
                receivedBytes: receivedBytes, totalBytes: totalBytes,
                state: ChromiumWebContents.downloadState(from: state)
            )
        )
    }

    // MARK: - Save page

    private static func sanitizedFileName(from title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "page" : trimmed
    }

    private static func uniqueFileURL(inDirectory directory: URL, baseName: String, pathExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(pathExtension)
            counter += 1
        }
        return candidate
    }

    // MARK: - Mapping
    // Pure functions, called from both MainActor and non-isolated contexts.

    nonisolated private static func securityLevel(for url: URL) -> SecurityLevel {
        switch url.scheme?.lowercased() {
        case "file", "about", "orbit", "data": return .local
        default: return .unknown
        }
    }

    nonisolated private static func navigationKind(from raw: Int32) -> NavigationKind {
        switch raw {
        case 1: return .typed
        case 2: return .linkActivated
        case 3: return .formSubmitted
        case 4: return .backForward
        case 5: return .reload
        case 6: return .redirect
        case 7: return .restored
        default: return .other
        }
    }

    // Mirrors orbit_bridge_api.h's OrbitWebContentsCallbacks.download_progress_changed `state` comment.
    nonisolated private static func downloadState(from raw: Int32) -> DownloadState {
        switch raw {
        case 1: return .inProgress
        case 2: return .paused
        case 3: return .completed
        case 4: return .cancelled
        case 5: return .interrupted
        default: return .pending
        }
    }

    // net::Error values, see net/base/net_error_list.h.
    nonisolated private static func engineErrorCode(forNetError netError: Int32) -> EngineError.Code {
        switch netError {
        case -3: return .cancelled
        case -106: return .networkUnreachable
        case -105: return .hostNotFound
        case -102: return .connectionRefused
        case -118: return .connectionTimedOut
        case -310: return .tooManyRedirects
        case -6: return .fileNotFound
        case -20: return .blockedByPolicy
        case -302: return .unsupportedScheme
        default:
            if (-299...(-200)).contains(Int(netError)) { return .certificateInvalid }
            return .unknown
        }
    }

    // MARK: - C trampolines
    // No captures, so each is a plain C function pointer; the instance is
    // recovered from `opaque`. All fire on the main thread.

    private static let navigationStateChangedTrampoline: OrbitWebContentsCallbacksLayout.NavigationStateChanged = {
        opaque, isLoading, canGoBack, canGoForward, urlPtr in
        withInstance(opaque) { contents in
            contents.handleNavigationStateChanged(
                isLoading: isLoading != 0,
                canGoBack: canGoBack != 0,
                canGoForward: canGoForward != 0,
                url: urlPtr.map { String(cString: $0) }
            )
        }
    }

    private static let loadProgressChangedTrampoline: OrbitWebContentsCallbacksLayout.LoadProgressChanged = { opaque, progress in
        withInstance(opaque) { $0.handleLoadProgressChanged(progress) }
    }

    private static let titleChangedTrampoline: OrbitWebContentsCallbacksLayout.TitleChanged = { opaque, titlePtr in
        guard let titlePtr else { return }
        withInstance(opaque) { $0.handleTitleChanged(String(cString: titlePtr)) }
    }

    private static let didCommitTrampoline: OrbitWebContentsCallbacksLayout.DidCommit = { opaque, urlPtr, kind in
        guard let urlPtr else { return }
        withInstance(opaque) { $0.handleDidCommit(url: String(cString: urlPtr), kind: navigationKind(from: kind)) }
    }

    private static let didFinishTrampoline: OrbitWebContentsCallbacksLayout.DidFinish = { opaque, urlPtr, statusCode in
        guard let urlPtr else { return }
        withInstance(opaque) { $0.handleDidFinish(url: String(cString: urlPtr), statusCode: Int(statusCode)) }
    }

    private static let didFailTrampoline: OrbitWebContentsCallbacksLayout.DidFail = { opaque, urlPtr, errorCode, descriptionPtr in
        guard let urlPtr else { return }
        let description = descriptionPtr.map { String(cString: $0) } ?? ""
        withInstance(opaque) { $0.handleDidFail(url: String(cString: urlPtr), errorCode: errorCode, description: description) }
    }

    private static let didReceiveScriptMessageTrampoline: OrbitWebContentsCallbacksLayout.DidReceiveScriptMessage = {
        opaque, channelPtr, jsonPtr in
        guard let channelPtr, let jsonPtr else { return }
        withInstance(opaque) {
            $0.handleScriptMessage(channel: String(cString: channelPtr), json: String(cString: jsonPtr))
        }
    }

    private static let findResultChangedTrampoline: OrbitWebContentsCallbacksLayout.FindResultChanged = {
        opaque, activeMatchOrdinal, matchCount, isFinalUpdate in
        withInstance(opaque) {
            $0.handleFindResultChanged(
                activeMatchOrdinal: activeMatchOrdinal, matchCount: matchCount, isFinalUpdate: isFinalUpdate != 0
            )
        }
    }

    private static let zoomFactorChangedTrampoline: OrbitWebContentsCallbacksLayout.ZoomFactorChanged = { opaque, factor in
        withInstance(opaque) { $0.handleZoomFactorChanged(factor) }
    }

    private static let preferredSizeChangedTrampoline: OrbitWebContentsCallbacksLayout.PreferredSizeChanged = {
        opaque, width, height in
        withInstance(opaque) { $0.handlePreferredSizeChanged(CGSize(width: width, height: height)) }
    }

    // `callback` must fire exactly once, so this bypasses withInstance, whose
    // silent early return on a nil opaque would otherwise drop the call.
    private static let willBeginDownloadTrampoline: OrbitWebContentsCallbacksLayout.WillBeginDownload = {
        opaque, downloadIDPtr, suggestedNamePtr, mimeTypePtr, totalBytes, sourceURLPtr, callback, callbackOpaque in
        guard let opaque, let downloadIDPtr, let suggestedNamePtr, let sourceURLPtr,
              let downloadID = UUID(uuidString: String(cString: downloadIDPtr)),
              let sourceURL = URL(string: String(cString: sourceURLPtr))
        else {
            callback(callbackOpaque, nil)
            return
        }
        let suggestedName = String(cString: suggestedNamePtr)
        let mimeType = mimeTypePtr.map { String(cString: $0) } ?? ""
        MainActor.assumeIsolated {
            let contents = Unmanaged<ChromiumWebContents>.fromOpaque(opaque).takeUnretainedValue()
            Task { @MainActor in
                let destination = await contents.delegate?.webContents(
                    contents, willBeginDownload: suggestedName, mimeType: mimeType,
                    totalBytes: totalBytes, sourceURL: sourceURL, downloadID: downloadID
                )
                guard let destination else {
                    callback(callbackOpaque, nil)
                    return
                }
                destination.path.withCString { callback(callbackOpaque, $0) }
            }
        }
    }

    private static let downloadProgressChangedTrampoline: OrbitWebContentsCallbacksLayout.DownloadProgressChanged = {
        opaque, downloadIDPtr, receivedBytes, totalBytes, state in
        guard let downloadIDPtr, let downloadID = UUID(uuidString: String(cString: downloadIDPtr)) else { return }
        withInstance(opaque) {
            $0.handleDownloadProgressChanged(
                downloadID: downloadID, receivedBytes: receivedBytes, totalBytes: totalBytes, state: state
            )
        }
    }

    // Same "must call exactly once" reasoning as willBeginDownloadTrampoline.
    private static let requestPermissionTrampoline: OrbitWebContentsCallbacksLayout.RequestPermission = {
        opaque, kindsJSONPtr, originPtr, callback, callbackOpaque in
        guard let opaque, let kindsJSONPtr, let originPtr,
              let data = String(cString: kindsJSONPtr).data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let rawKinds = rawObject as? [String],
              let origin = URL(string: String(cString: originPtr))
        else {
            callback(callbackOpaque, 0)
            return
        }
        let kinds = Set(rawKinds.compactMap(PermissionKind.init(rawValue:)))
        guard !kinds.isEmpty else {
            callback(callbackOpaque, 0)
            return
        }
        MainActor.assumeIsolated {
            let contents = Unmanaged<ChromiumWebContents>.fromOpaque(opaque).takeUnretainedValue()
            Task { @MainActor in
                let decision = await contents.delegate?.webContents(
                    contents, requestsPermission: PermissionRequest(kinds: kinds, origin: origin)
                ) ?? .deny
                let raw: Int32
                switch decision {
                case .deny: raw = 0
                case .allow: raw = 1
                case .allowAlways: raw = 2
                case .denyAlways: raw = 3
                }
                callback(callbackOpaque, raw)
            }
        }
    }

    private static let nativeExtensionRequestTrampoline: OrbitWebContentsCallbacksLayout.NativeExtensionRequest = {
        opaque, requestIDPtr, methodPtr, argsJSONPtr in
        guard let requestIDPtr, let methodPtr, let argsJSONPtr else { return }
        withInstance(opaque) {
            $0.handleNativeExtensionRequest(
                requestID: String(cString: requestIDPtr), method: String(cString: methodPtr),
                argsJSON: String(cString: argsJSONPtr)
            )
        }
    }

    private static let devtoolsClosedTrampoline: OrbitWebContentsCallbacksLayout.DevToolsClosed = { opaque in
        withInstance(opaque) { $0.handleDevToolsClosed() }
    }

    private static let devtoolsDockedChangedTrampoline: OrbitWebContentsCallbacksLayout.DevToolsDockedChanged = {
        opaque, isDocked in
        withInstance(opaque) { $0.handleDevToolsDockedChanged(isDocked != 0) }
    }

    private static let devtoolsInspectedPageBoundsTrampoline: OrbitWebContentsCallbacksLayout.DevToolsInspectedPageBounds = {
        opaque, x, y, width, height, hidesPage in
        let bounds = CGRect(
            x: CGFloat(x), y: CGFloat(y), width: CGFloat(max(0, width)), height: CGFloat(max(0, height))
        )
        withInstance(opaque) { $0.handleDevToolsInspectedPageBounds(bounds, hidesPage: hidesPage != 0) }
    }

    private static let devtoolsCloseRequestedTrampoline: OrbitWebContentsCallbacksLayout.DevToolsCloseRequested = { opaque in
        withInstance(opaque) { $0.handleDevToolsCloseRequested() }
    }

    private static let devtoolsBringToFrontTrampoline: OrbitWebContentsCallbacksLayout.DevToolsBringToFront = { opaque in
        withInstance(opaque) { $0.handleDevToolsBringToFront() }
    }

    private static let showContextMenuTrampoline: OrbitWebContentsCallbacksLayout.ShowContextMenu = {
        opaque, pageURLPtr, frameURLPtr, linkURLPtr, unfilteredLinkURLPtr, sourceURLPtr, titleTextPtr,
        selectionTextPtr, mediaType, isEditable, misspelledWordPtr, dictionarySuggestionsJSONPtr, x, y in
        withInstance(opaque) {
            $0.handleShowContextMenu(
                pageURL: pageURLPtr.map { String(cString: $0) } ?? "",
                frameURL: frameURLPtr.map { String(cString: $0) } ?? "",
                linkURL: linkURLPtr.map { String(cString: $0) } ?? "",
                unfilteredLinkURL: unfilteredLinkURLPtr.map { String(cString: $0) } ?? "",
                sourceURL: sourceURLPtr.map { String(cString: $0) } ?? "",
                titleText: titleTextPtr.map { String(cString: $0) } ?? "",
                selectionText: selectionTextPtr.map { String(cString: $0) } ?? "",
                mediaType: mediaType,
                isEditable: isEditable != 0,
                misspelledWord: misspelledWordPtr.map { String(cString: $0) } ?? "",
                dictionarySuggestionsJSON: dictionarySuggestionsJSONPtr.map { String(cString: $0) } ?? "[]",
                x: x, y: y
            )
        }
    }

    private static let pictureInPictureChangedTrampoline: OrbitWebContentsCallbacksLayout.PictureInPictureChanged = {
        opaque, isActive in
        withInstance(opaque) { $0.handlePictureInPictureChanged(isActive != 0) }
    }

    private static let activationRequestedTrampoline: OrbitWebContentsCallbacksLayout.ActivationRequested = { opaque in
        withInstance(opaque) { $0.handleActivationRequested() }
    }

    private static let pictureInPictureAvailableChangedTrampoline:
        OrbitWebContentsCallbacksLayout.PictureInPictureAvailableChanged = { opaque, isAvailable in
        withInstance(opaque) { $0.handlePictureInPictureAvailableChanged(isAvailable != 0) }
    }

    // The pixels belong to the engine's stack for the duration of this call,
    // so the NSImage has to be built here rather than the pointer forwarded.
    private static let faviconChangedTrampoline: OrbitWebContentsCallbacksLayout.FaviconChanged = {
        opaque, iconURLPtr, rgba, width, height, stride in
        let iconURL = iconURLPtr.map { String(cString: $0) }
        let image: NSImage? = {
            guard let rgba, width > 0, height > 0, stride > 0 else { return nil }
            return OrbitChromiumBridge.makeImage(
                rgbaData: rgba, width: Int(width), height: Int(height), stride: Int(stride)
            )
        }()
        withInstance(opaque) { $0.handleFaviconChanged(iconURL: iconURL, image: image) }
    }

    // MARK: - Certificate errors

    // The certificate-error callback is process-wide and arrives with the tab's
    // handle, not a per-tab opaque. Weak: an outlived entry resolves to nil and refuses.
    private final class WeakContentsBox {
        weak var contents: ChromiumWebContents?
        init(_ contents: ChromiumWebContents) { self.contents = contents }
    }

    private static var contentsByHandle: [UnsafeMutableRawPointer: WeakContentsBox] = [:]

    private static let installCertificateErrorCallbackOnce: Void = {
        OrbitChromiumBridge.shared.setCertificateErrorCallback(
            ChromiumWebContents.certificateErrorTrampoline
        )
    }()

    // Every path must answer or deliberately leave the browser's own refusal
    // to stand — an unanswered request leaves content:: holding a live
    // URLRequest, which is a hang rather than a block.
    private static let certificateErrorTrampoline: OrbitChromiumBridge.CertificateErrorCallback = {
        _, handle, requestID, requestURLPtr, hostPtr, certError, errorNamePtr, issuerPtr, subjectPtr,
        validFrom, validUntil, overridable in
        guard let handle else { return }
        let host = hostPtr.map { String(cString: $0) } ?? ""
        let requestURL = requestURLPtr.map { String(cString: $0) } ?? ""
        let problem = CertificateProblem(
            host: host.isEmpty ? requestURL : host,
            issuer: issuerPtr.map { String(cString: $0) } ?? "",
            subject: subjectPtr.map { String(cString: $0) } ?? "",
            validFrom: validFrom > 0 ? Date(timeIntervalSince1970: validFrom) : nil,
            validUntil: validUntil > 0 ? Date(timeIntervalSince1970: validUntil) : nil,
            reason: CertificateProblemReason.describe(
                errorCode: Int(certError),
                engineName: errorNamePtr.map { String(cString: $0) } ?? ""
            ),
            errorCode: Int(certError),
            isOverridable: overridable != 0
        )
        MainActor.assumeIsolated {
            guard let contents = ChromiumWebContents.contentsByHandle[handle]?.contents,
                  !contents.isClosed,
                  let delegate = contents.delegate
            else {
                OrbitChromiumBridge.shared.respondToCertificateError(handle, requestID: requestID, allow: false)
                return
            }
            Task { @MainActor in
                let allow = await delegate.webContents(contents, allowCertificateProblem: problem)
                // Answering through a destroyed handle would dereference freed
                // memory; ~OrbitWebContentsHost has already refused everything
                // it still owed by the time isClosed is true.
                guard !contents.isClosed else { return }
                OrbitChromiumBridge.shared.respondToCertificateError(
                    handle, requestID: requestID, allow: allow && problem.isOverridable
                )
            }
        }
    }

    private static let installNewContentRequestCallbackOnce: Void = {
        OrbitChromiumBridge.shared.setNewContentRequestCallback(
            ChromiumWebContents.newContentRequestTrampoline
        )
    }()

    // Process-wide: `handle` must stay unwrapped until an owner commits, since an
    // eagerly-built ChromiumWebContents around a then-deleted handle strands its retain.
    private static let newContentRequestTrampoline: OrbitChromiumBridge.NewContentRequestCallback = {
        _, sourcePtr, handlePtr, urlPtr, disposition, userGesture in
        guard let sourcePtr else { return 0 }
        let urlString = urlPtr.map { String(cString: $0) } ?? ""
        return MainActor.assumeIsolated {
            guard let source = ChromiumWebContents.contentsByHandle[sourcePtr]?.contents,
                  !source.isClosed,
                  let delegate = source.delegate,
                  let url = URL(string: urlString.isEmpty ? "about:blank" : urlString)
            else { return 0 }

            let request = NewContentRequest(
                url: url,
                disposition: NewContentDisposition(chromiumWindowOpenDisposition: disposition),
                isUserGesture: userGesture != 0
            )

            guard let handlePtr else {
                return delegate.webContents(source, requestsNewContent: request) ? 1 : 0
            }

            let session = source.session
            let pending = PendingWebContents(request: request) {
                try? ChromiumWebContents(adopting: handlePtr, session: session)
            }
            let accepted = delegate.webContents(source, requestsAdoptionOf: pending)
            // isAdopted, not `accepted`, is told to content::: adopt() already
            // handed off or destroyed the handle, so deleting it again is a double free.
            if accepted && !pending.isAdopted {
                ChromiumWebContents.logger.error(
                    "requestsAdoptionOf accepted without calling adopt(); refusing the new window"
                )
            }
            return pending.isAdopted ? 1 : 0
        }
    }

    // nonisolated so @convention(c) trampolines can call it directly; `body`'s
    // @MainActor annotation lets closures call main-actor methods like handleDidCommit.
    nonisolated private static func withInstance(
        _ opaque: UnsafeMutableRawPointer?,
        _ body: @MainActor (ChromiumWebContents) -> Void
    ) {
        guard let opaque else { return }
        MainActor.assumeIsolated {
            body(Unmanaged<ChromiumWebContents>.fromOpaque(opaque).takeUnretainedValue())
        }
    }
}
