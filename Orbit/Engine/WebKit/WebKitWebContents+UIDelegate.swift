import AppKit
import Security
import WebKit

// WKUIDelegate and process-health surface that is not a navigation decision: page dialogs, the file chooser, window.close(), crashes and element fullscreen.
extension WebKitWebContents {

    // MARK: - JavaScript dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await presentDialog(.alert, message: message, defaultText: "", frame: frame)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await presentDialog(.confirm, message: message, defaultText: "", frame: frame).accepted
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let response = await presentDialog(.prompt, message: prompt, defaultText: defaultText ?? "", frame: frame)
        return response.accepted ? (response.promptText ?? "") : nil
    }

    // The onbeforeunload confirmation has no public WKUIDelegate hook. WebKit answers this private selector, and without it a page can never ask before it is left.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webViewRunBeforeUnloadPanel(
        _ webView: WKWebView,
        message: String,
        frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            let text = message.isEmpty
                ? "This page is asking you to confirm that you want to leave. Information you have entered may not be saved."
                : message
            completionHandler(await self.presentDialog(.beforeUnload, message: text, defaultText: "", frame: frame).accepted)
        }
    }

    private func presentDialog(
        _ kind: JavaScriptDialogKind,
        message: String,
        defaultText: String,
        frame: WKFrameInfo
    ) async -> JavaScriptDialogResponse {
        guard !isClosed, let delegate else {
            return JavaScriptDialogResponse(accepted: kind == .beforeUnload)
        }
        let request = JavaScriptDialogRequest(
            kind: kind,
            message: message,
            defaultPromptText: defaultText,
            origin: WebKitPermissionPolicy.url(for: frame.securityOrigin)
        )
        return await delegate.webContents(self, runJavaScriptDialog: request)
    }

    // MARK: - File chooser

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        guard !isClosed, let delegate else { return nil }
        let urls = await delegate.webContents(
            self,
            runOpenPanelAllowingMultiple: parameters.allowsMultipleSelection,
            allowsDirectories: parameters.allowsDirectories,
            acceptedTypes: Self.acceptedTypes(of: parameters)
        )
        return urls.isEmpty ? nil : urls
    }

    // The accept= list (MIME types and dotted extensions) is only exposed through these private accessors.
    private static func acceptedTypes(of parameters: WKOpenPanelParameters) -> [String] {
        var types: [String] = []
        for key in ["_acceptedMIMETypes", "_acceptedFileExtensions"] where parameters.responds(to: NSSelectorFromString(key)) {
            let values = (parameters.value(forKey: key) as? [String]) ?? []
            types += key == "_acceptedFileExtensions"
                ? values.map { $0.hasPrefix(".") ? $0 : "." + $0 }
                : values
        }
        return types
    }

    // MARK: - window.close()

    func webViewDidClose(_ webView: WKWebView) {
        guard !isClosed else { return }
        delegate?.webContentsDidRequestClose(self)
    }

    // MARK: - Process health

    @objc(webViewWebContentProcessDidTerminate:)
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        navigationState.isLoading = false
        navigationState.progress = 0
        let wasFullscreen = extras.isElementFullscreen
        extras.isElementFullscreen = false
        mediaState = MediaState(isMuted: mediaState.isMuted)
        // A dead process will not finish the exit animation. Drop the restore so it cannot keep setting frames.
        PaneFrameRestore.arm(self, false)
        delegate?.webContentsDidChangeNavigationState(self)
        delegate?.webContents(self, didChangeMediaState: mediaState)
        if wasFullscreen { delegate?.webContents(self, didChangeFullscreen: false) }
        delegate?.webContentsDidCrash(self)
    }

    /// WebKit calls this in preference to the unadorned terminate callback when it is present.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        webViewWebContentProcessDidTerminate(webView)
    }

    // MARK: - Element fullscreen

    func fullscreenStateDidChange() {
        guard !isClosed else { return }
        // The transitions count as fullscreen: the pane must not take the view back while WebKit is moving it.
        let isFullscreen = webView.fullscreenState != .notInFullscreen
        guard extras.isElementFullscreen != isFullscreen else { return }
        let wasFullscreen = extras.isElementFullscreen
        extras.isElementFullscreen = isFullscreen
        mediaState.isFullscreen = isFullscreen
        delegate?.webContents(self, didChangeFullscreen: isFullscreen)
        delegate?.webContents(self, didChangeMediaState: mediaState)
        if isFullscreen {
            PaneFrameRestore.arm(self, false)
        } else if wasFullscreen {
            // WebKit sizes the page to the window after this callback, and again once the view is back in the pane.
            PaneFrameRestore.arm(self, true)
            restoreHostedLayout()
            PaneFrameRestore.scheduleExitRetries(self)
            focus()
        }
    }

    // WebKit swaps a placeholder for the web view while it is fullscreen and puts it back on exit.
    // It then sizes the page to the window it came from, so the pane's own frame and resizing are re-asserted.
    func restoreHostedLayout() {
        let key = ObjectIdentifier(self)
        guard !PaneFrameRestore.isApplying(key) else { return }
        // A docked inspector owns the split. Touching the mask here would make the page cover it on the next resize.
        guard !isDeveloperToolsDocked else { return }
        guard let container = extras.hostContainer else { return }
        guard webView.fullscreenState == .notInFullscreen else { return }
        if webView.superview !== container {
            performInspectorReparent { container.addSubview(webView) }
        }
        let fillsPane = webView.translatesAutoresizingMaskIntoConstraints && webView.autoresizingMask == [.width, .height]
        if !fillsPane {
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
        }
        let target = container.bounds
        guard !Self.framesMatch(webView.frame, target) else { return }
        PaneFrameRestore.beginApplying(key)
        webView.frame = target
        PaneFrameRestore.endApplying(key)
    }

    private static func framesMatch(_ frame: NSRect, _ target: NSRect) -> Bool {
        abs(frame.origin.x - target.origin.x) < 0.5
            && abs(frame.origin.y - target.origin.y) < 0.5
            && abs(frame.size.width - target.size.width) < 0.5
            && abs(frame.size.height - target.size.height) < 0.5
    }

    // MARK: - Observation

    func observeWebView() {
        let view = webView
        extras.observations = [
            view.observe(\.fullscreenState) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.fullscreenStateDidChange() }
            },
            view.observe(\.superview) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, PaneFrameRestore.isArmed(self) else { return }
                    self.restoreHostedLayout()
                    PaneFrameRestore.noteHostReparented(self)
                }
            },
            view.observe(\.hasOnlySecureContent) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshSecurity() }
            },
            view.observe(\.serverTrust) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshSecurity() }
            },
            view.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.noteDocumentTitle() }
            },
        ]
        // The frame watcher exists only while an exit is being put back. A permanent one
        // runs on every resize and fights a docked inspector for the page frame.
        // Replacing the web view clears the pane, so an in-flight exit has nothing to restore.
        if PaneFrameRestore.isArmed(self) {
            if extras.hostContainer == nil {
                PaneFrameRestore.arm(self, false)
            } else {
                PaneFrameRestore.observeFrame(of: self)
            }
        }
        observeMediaSurfaces()
    }
}

/// Fullscreen exit puts the web view back, then sizes it to the window rather than the pane.
/// Armed only across that exit, so a later fullscreen entry is not pulled back into the pane mid-transition.
@MainActor
enum PaneFrameRestore {
    private static var armed: [ObjectIdentifier: Bool] = [:]
    private static var applying: Set<ObjectIdentifier> = []
    private static var frameObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Web views whose frame notifications we turned on, so leaving the exit window turns them off again.
    private static var notificationsOwned: Set<ObjectIdentifier> = []
    private static var exitGeneration: [ObjectIdentifier: Int] = [:]
    private static var settleScheduled: Set<ObjectIdentifier> = []

    static func arm(_ contents: WebKitWebContents, _ on: Bool) {
        let key = ObjectIdentifier(contents)
        if on {
            armed[key] = true
            observeFrame(of: contents)
        } else {
            disarm(contents)
        }
    }

    static func isArmed(_ contents: WebKitWebContents) -> Bool {
        armed[ObjectIdentifier(contents)] == true
    }

    static func isApplying(_ key: ObjectIdentifier) -> Bool { applying.contains(key) }
    static func beginApplying(_ key: ObjectIdentifier) { applying.insert(key) }
    static func endApplying(_ key: ObjectIdentifier) { applying.remove(key) }

    /// WebKit writes the window frame after the fullscreen callback. A few beats cover that, then the
    /// watcher goes away: the autoresizing mask keeps the page with the pane, and a watcher that stays
    /// armed rewrites the frame on every later resize.
    static func scheduleExitRetries(_ contents: WebKitWebContents) {
        let key = ObjectIdentifier(contents)
        let generation = bump(key)
        settleScheduled.remove(key)
        for delay in [0.0, 0.05, 0.15, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak contents] in
                MainActor.assumeIsolated {
                    guard let contents, exitGeneration[key] == generation, isArmed(contents) else { return }
                    contents.restoreHostedLayout()
                }
            }
        }
        scheduleSettle(contents, generation: generation)
    }

    /// The view can land in the pane after the exit callback. Settle from that reparent, not from a second watcher.
    static func noteHostReparented(_ contents: WebKitWebContents) {
        let key = ObjectIdentifier(contents)
        guard isArmed(contents), let generation = exitGeneration[key] else { return }
        scheduleSettle(contents, generation: generation)
    }

    static func observeFrame(of contents: WebKitWebContents) {
        let key = ObjectIdentifier(contents)
        if let existing = frameObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(existing)
        }
        let view = contents.webView
        if !view.postsFrameChangedNotifications {
            view.postsFrameChangedNotifications = true
            notificationsOwned.insert(key)
        }
        frameObservers[key] = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak contents] _ in
            MainActor.assumeIsolated {
                guard let contents, isArmed(contents) else { return }
                contents.restoreHostedLayout()
            }
        }
    }

    static func stop(_ contents: WebKitWebContents) {
        let key = ObjectIdentifier(contents)
        disarm(contents)
        applying.remove(key)
        armed.removeValue(forKey: key)
        exitGeneration.removeValue(forKey: key)
    }

    private static func disarm(_ contents: WebKitWebContents) {
        let key = ObjectIdentifier(contents)
        armed[key] = false
        _ = bump(key)
        settleScheduled.remove(key)
        if let existing = frameObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(existing)
        }
        if notificationsOwned.remove(key) != nil {
            contents.webView.postsFrameChangedNotifications = false
        }
    }

    private static func bump(_ key: ObjectIdentifier) -> Int {
        let generation = (exitGeneration[key] ?? 0) + 1
        exitGeneration[key] = generation
        return generation
    }

    private static func scheduleSettle(_ contents: WebKitWebContents, generation: Int) {
        let key = ObjectIdentifier(contents)
        guard settleScheduled.insert(key).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak contents] in
            MainActor.assumeIsolated {
                guard exitGeneration[key] == generation else { return }
                settleScheduled.remove(key)
                guard let contents, isArmed(contents), contents.webView.fullscreenState == .notInFullscreen else { return }
                guard let container = contents.extras.hostContainer, contents.webView.superview === container else { return }
                contents.restoreHostedLayout()
                arm(contents, false)
            }
        }
    }
}
