import AppKit
import Foundation
import WebKit

struct PendingTabMove {
    var window: WebKitExtensionWindow
    var index: Int
}

struct WeakEnvironment {
    weak var value: AppEnvironment?
    init(_ value: AppEnvironment) { self.value = value }
}

// One extension window per Orbit window. A standard Orbit window shares its AppEnvironment with
// every other standard window, so the environment, not the NSWindow, is the window's identity.
extension WebKitEngine {

    // MARK: - Owner and window lookup

    /// The Orbit window a tab lives in: its delegate once adopted, the registering window before that.
    func ownerEnvironment(of contents: WebKitWebContents) -> AppEnvironment? {
        if let environment = contents.delegate as? AppEnvironment { return environment }
        return environmentHintsByTab[contents.id]?.value
    }

    /// The first window. A tab no Orbit window owns, such as a probe page, belongs to it.
    func primaryExtensionWindow() -> WebKitExtensionWindow {
        if let existing = extensionWindows.first(where: \.isDefault) { return existing }
        let window = makeExtensionWindow(environment: nil)
        window.isDefault = true
        extensionWindows.insert(window, at: 0)
        extensionController.didOpenWindow(window)
        return window
    }

    func extensionWindow(for environment: AppEnvironment) -> WebKitExtensionWindow {
        defer { installTabQueryConformance() }
        if let existing = extensionWindows.first(where: { $0.environment === environment }) { return existing }
        discardClosedExtensionWindows()
        // The first standard environment takes the placeholder, so the window that was announced
        // at start-up is the one the user's first window turns out to be.
        if !environment.isWindowScoped,
           let placeholder = extensionWindows.first(where: { $0.isDefault && $0.environment == nil }) {
            placeholder.environment = environment
            return placeholder
        }
        return openExtensionWindow(environment: environment)
    }

    func extensionWindow(of contents: WebKitWebContents) -> WebKitExtensionWindow {
        if let environment = ownerEnvironment(of: contents) { return extensionWindow(for: environment) }
        return primaryExtensionWindow()
    }

    private func makeExtensionWindow(environment: AppEnvironment?) -> WebKitExtensionWindow {
        let window = WebKitExtensionWindow(number: nextExtensionWindowNumber)
        nextExtensionWindowNumber += 1
        window.engine = self
        window.environment = environment
        return window
    }

    func openExtensionWindow(environment: AppEnvironment?) -> WebKitExtensionWindow {
        let window = makeExtensionWindow(environment: environment)
        extensionWindows.append(window)
        extensionController.didOpenWindow(window)
        return window
    }

    /// A window whose environment has been released is gone, and so is a headless one with nothing
    /// in it that is not the first; tell WebKit so it stops listing them.
    func discardClosedExtensionWindows() {
        let stale = extensionWindows.filter { window in
            guard !window.isDefault, !window.isSynthetic else { return false }
            if window.closesWithEnvironment {
                guard let environment = window.environment else { return true }
                return !environment.isWindowScoped
            }
            guard let environment = window.environment else { return window.hasHadEnvironment }
            return !environment.isWindowScoped && window.nsWindow == nil && extensionTabs(in: window).isEmpty
        }
        for window in stale {
            extensionWindows.removeAll { $0 === window }
            if focusedExtensionWindow === window { focusedExtensionWindow = nil }
            extensionController.didCloseWindow(window)
        }
    }

    // MARK: - Window lifecycle

    func noteWindowOpened(environment: AppEnvironment) {
        _ = extensionWindow(for: environment)
    }

    /// The shared environment keeps its window: its tabs outlive any one NSWindow.
    /// A window-scoped environment has already cleared `isWindowScoped` by the time this runs
    /// (`disposeWindowSession`), so the flag recorded when it was bound is what identifies it.
    func noteWindowClosed(environment: AppEnvironment) {
        guard let window = extensionWindows.first(where: { $0.environment === environment }),
              window.closesWithEnvironment
        else { return }
        extensionWindows.removeAll { $0 === window }
        if focusedExtensionWindow === window { focusedExtensionWindow = nil }
        extensionController.didCloseWindow(window)
    }

    /// `nil` means no Orbit window has focus.
    func noteWindowFocused(environment: AppEnvironment?) {
        let window = environment.map { extensionWindow(for: $0) }
        guard window !== focusedExtensionWindow else { return }
        if let window { promoteExtensionWindowToFront(window) }
        focusExtensionWindow(window)
    }

    /// With no real NSWindow tracking focus (a headless host), the window that just got a tab is the
    /// one in front, as the only window used to be. A window-scoped window never takes focus this way.
    func focusIfNoWindowHasFocus(_ window: WebKitExtensionWindow) {
        guard window !== focusedExtensionWindow, window.nsWindow == nil,
              window.environment?.isWindowScoped != true,
              focusedExtensionWindow?.nsWindow == nil
        else { return }
        promoteExtensionWindowToFront(window)
        focusExtensionWindow(window)
    }

    /// WebKit treats the first window from `openWindowsFor` as the focused one.
    func promoteExtensionWindowToFront(_ window: WebKitExtensionWindow) {
        guard let index = extensionWindows.firstIndex(where: { $0 === window }), index != 0 else { return }
        extensionWindows.remove(at: index)
        extensionWindows.insert(window, at: 0)
    }

    // MARK: - Tabs per window

    /// A window's tabs in the order chrome.tabs indexes them: sidebar order within its Orbit window.
    func extensionTabs(in window: WebKitExtensionWindow) -> [WebKitWebContents] {
        let registered = openTabs.filter { !$0.isExtensionPage }
        var result: [WebKitWebContents] = []
        if let environment = window.environment {
            let contents = environment.extensionTabContents()
            let unlisted = contents.unlisted.sorted { (numericID(for: $0) ?? 0) < (numericID(for: $1) ?? 0) }
            result = (contents.listed + unlisted).filter { tab in registered.contains { $0 === tab } }
            // Created for this window, not yet adopted into its tab map.
            for tab in registered where !result.contains(where: { $0 === tab }) && ownerEnvironment(of: tab) === environment {
                result.append(tab)
            }
        }
        if window.isDefault {
            for tab in registered where ownerEnvironment(of: tab) == nil { result.append(tab) }
        }
        return result
    }

    func extensionActiveTab(in window: WebKitExtensionWindow) -> (any WKWebExtensionTab)? {
        let tabs = extensionTabs(in: window)
        guard let fallback = tabs.last else {
            window.lastActiveTab = nil
            return nil
        }
        if let environment = window.environment,
           let active = environment.extensionActiveContents,
           tabs.contains(where: { $0 === active }) {
            window.lastActiveTab = active
            return active
        }
        if let last = window.lastActiveTab, tabs.contains(where: { $0 === last }) { return last }
        window.lastActiveTab = fallback
        return fallback
    }

    /// A live tab is about to change Orbit window (tear-off). The old window is recorded now,
    /// while this environment still lists the tab.
    func noteTabWillMove(_ contents: WebKitWebContents) {
        guard openTabs.contains(where: { $0 === contents }) else { return }
        let window = extensionWindow(of: contents)
        let index = extensionTabs(in: window).firstIndex { $0 === contents } ?? 0
        pendingTabMoves[contents.id] = PendingTabMove(window: window, index: index)
    }

    /// Reports the move once the tab has its new owner; a no-op for a tab that was not moving.
    /// A change of Orbit window is a close plus an open: WebKit has no cross-window move.
    /// The Orbit tab number is kept, so the tab is still the same tab.
    func completeTabMove(_ contents: WebKitWebContents) {
        guard let move = pendingTabMoves.removeValue(forKey: contents.id) else { return }
        environmentHintsByTab[contents.id] = nil
        if move.window.lastActiveTab === contents { move.window.lastActiveTab = nil }
        let owner = contents.delegate as? AppEnvironment
        let destination = owner.flatMap { environment in extensionWindows.first { $0.environment === environment } }
        if let destination, destination === move.window {
            noteTabLayoutChanged()
            extensionController.didMoveTab(contents, from: move.index, in: move.window)
            return
        }
        let storeTabID = owner?.tabID(for: contents)
        let keptNumber = numericID(for: contents)
        noteTabClosed(contents)
        if let storeTabID { bind(storeTabID: storeTabID, to: contents) }
        noteTabOpened(contents, reusingNumber: keptNumber)
        if let active = (contents.delegate as? AppEnvironment)?.extensionActiveContents, active === contents {
            noteActive(contents)
        }
    }

    func noteTabPropertiesChanged(_ contents: WebKitWebContents, _ properties: WKWebExtension.TabChangedProperties) {
        guard openTabs.contains(where: { $0 === contents }) else { return }
        extensionController.didChangeTabProperties(properties, for: contents)
    }

    // MARK: - Creating tabs

    func openExtensionTab(
        using configuration: WKWebExtension.TabConfiguration,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let window = (configuration.window as? WebKitExtensionWindow) ?? focusedExtensionWindow ?? primaryExtensionWindow()
        let requestedIndex = configuration.index
        let windowIndex = (0..<1_000_000).contains(requestedIndex) ? requestedIndex : nil
        if let environment = window.environment,
           let contents = environment.extensionOpenTab(
               url: configuration.url,
               windowIndex: windowIndex,
               active: configuration.shouldBeActive,
               pinned: configuration.shouldBePinned,
               muted: configuration.shouldBeMuted
           ) {
            completionHandler(contents, nil)
            return
        }
        // No Orbit window behind this one (a bare window): the tab still has to exist for the extension.
        let session = (defaultSession as? WebKitSession) ?? WebKitSession(identifier: "default", persistent: false, storageURL: nil)
        let contents = WebKitWebContents(engine: self, session: session, initialURL: configuration.url)
        noteTabOpened(contents)
        if let url = configuration.url { contents.load(url) }
        completionHandler(contents, nil)
    }

    // MARK: - Delegate: windows and the action popup

    @objc(webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        discardClosedExtensionWindows()
        let host = focusedExtensionWindow?.environment ?? extensionWindows.compactMap(\.environment).first
        guard let host else {
            completionHandler(nil, NSError(
                domain: "com.orbit.extension.window", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Orbit has no browser window to open another from."]
            ))
            return
        }
        let moving = configuration.tabs.compactMap { $0 as? WebKitWebContents }
        guard let environment = host.extensionOpenWindow(
            urls: configuration.tabURLs,
            movingTabs: moving,
            private: configuration.shouldBePrivate,
            focused: configuration.shouldBeFocused
        ) else {
            completionHandler(nil, NSError(
                domain: "com.orbit.extension.window", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Orbit could not open the window."]
            ))
            return
        }
        let window = extensionWindow(for: environment)
        let frame = configuration.frame
        if !frame.isNull, !(frame.origin.x.isNaN && frame.origin.y.isNaN && frame.size.width.isNaN && frame.size.height.isNaN) {
            window.setFrame(frame, for: extensionContext) { _ in }
        }
        if configuration.windowState != .normal {
            window.setWindowState(configuration.windowState, for: extensionContext) { _ in }
        }
        completionHandler(window, nil)
    }

    @objc(webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:)
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let associated = (action.associatedTab as? WebKitWebContents).flatMap(ownerEnvironment(of:))
        let environment = associated ?? focusedExtensionWindow?.environment ?? extensionWindows.compactMap(\.environment).first
        guard let environment, environment.activateExtensionAction(context.uniqueIdentifier) else {
            completionHandler(NSError(
                domain: "com.orbit.extension.window", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "There is no tab to show the popup for."]
            ))
            return
        }
        completionHandler(nil)
    }

    /// WebKit's tabs.query ignores currentWindow:false, title globs, groupId and windowType, and
    /// omits groupId / autoDiscardable. The background's own query is wrapped to apply them.
    func installTabQueryConformance() {
        let engineID = ObjectIdentifier(self)
        var installed = TabQueryConformance.installed[engineID] ?? []
        for entry in loadedExtensionContexts() where !installed.contains(entry.id) {
            guard let webView = entry.context.orbitBackgroundWebView else { continue }
            installed.insert(entry.id)
            TabQueryConformance.installed[engineID] = installed
            let extensionID = entry.id
            webView.evaluateJavaScript(TabQueryConformance.script) { result, error in
                let accepted = error == nil && (result as? Bool) == true
                guard !accepted else { return }
                Task { @MainActor in
                    TabQueryConformance.installed[engineID]?.remove(extensionID)
                }
            }
        }
    }
}

@MainActor
private enum TabQueryConformance {
    static var installed: [ObjectIdentifier: Set<String>] = [:]

    static let script = #"""
    (function () {
      function install(root) {
        var api = root && root.tabs;
        if (!api || typeof api.query !== "function") return false;
        if (api.query.__orbitConformance) return true;
        var original = api.query.bind(api);
        // Content-script matches are not host permissions. Without "tabs" or a
        // declared host permission, url and title must be absent, not empty strings.
        function detailsVisible() {
          try {
            var manifest = root.runtime && root.runtime.getManifest ? root.runtime.getManifest() : null;
            if (!manifest) return true;
            var names = [].concat(manifest.permissions || [], manifest.optional_permissions || []);
            if (names.indexOf("tabs") !== -1) return true;
            var hosts = [].concat(manifest.host_permissions || [], manifest.optional_host_permissions || []);
            return hosts.length > 0;
          } catch (e) { return true; }
        }
        function normalize(tab) {
          if (!tab || typeof tab !== "object") return tab;
          var copy = {};
          Object.keys(tab).forEach(function (key) { copy[key] = tab[key]; });
          ["id", "url", "pendingUrl", "title", "index", "windowId", "active", "pinned", "highlighted", "audible", "mutedInfo", "status", "favIconUrl", "incognito"].forEach(function (key) {
            if (copy[key] === undefined && tab[key] !== undefined) copy[key] = tab[key];
          });
          if (!detailsVisible()) {
            delete copy.url;
            delete copy.pendingUrl;
            delete copy.title;
            delete copy.favIconUrl;
          }
          if (copy.groupId == null) copy.groupId = -1;
          if (copy.autoDiscardable == null) copy.autoDiscardable = true;
          if (copy.discarded == null) copy.discarded = false;
          if (copy.frozen == null) copy.frozen = false;
          return copy;
        }
        function globMatch(text, pattern) {
          var source = "^" + String(pattern).replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$";
          return new RegExp(source).test(text || "");
        }
        function titleOK(tab, title) {
          if (title == null) return true;
          var patterns = Array.isArray(title) ? title : [title];
          return patterns.some(function (pattern) { return globMatch(tab && tab.title, pattern); });
        }
        function apply(tabs, query, currentId) {
          return (tabs || []).map(normalize).filter(function (tab) {
            if (!tab) return false;
            if (query.currentWindow === true) {
              if (currentId == null || tab.windowId !== currentId) return false;
            }
            if (query.currentWindow === false && currentId != null && tab.windowId === currentId) return false;
            if (query.groupId != null && tab.groupId !== query.groupId) return false;
            if (query.windowType != null && query.windowType !== "normal") return false;
            if (!titleOK(tab, query.title)) return false;
            return true;
          });
        }
        function stripped(query) {
          var next = {};
          Object.keys(query || {}).forEach(function (key) {
            if (key === "title" || key === "currentWindow" || key === "groupId" || key === "windowType") return;
            next[key] = query[key];
          });
          return next;
        }
        function finish(tabs, query, done) {
          var list = (tabs || []).map(normalize);
          var sent = false;
          function reply(currentId) {
            if (sent) return;
            sent = true;
            done(apply(list, query, currentId));
          }
          if (query.currentWindow == null) { reply(null); return; }
          var windows = root.windows;
          if (!windows || typeof windows.getCurrent !== "function") { reply(null); return; }
          try {
            var pending = windows.getCurrent(function (win) { reply(win && win.id); });
            if (pending && typeof pending.then === "function") {
              pending.then(function (win) { reply(win && win.id); }, function () { reply(null); });
            }
          } catch (e) { reply(null); }
        }
        function wrapped(query, callback) {
          var info = query || {};
          var next = stripped(info);
          if (typeof callback === "function") {
            var once = false;
            function accept(tabs) {
              if (once) return;
              once = true;
              finish(tabs, info, callback);
            }
            try { original(next, accept); }
            catch (e) { accept([]); }
            return;
          }
          try {
            var result = original(next);
            if (result && typeof result.then === "function") {
              return result.then(function (tabs) {
                return new Promise(function (resolve) { finish(tabs, info, resolve); });
              });
            }
            return (result || []).map(normalize);
          } catch (e) {
            return Promise.resolve([]);
          }
        }
        wrapped.__orbitConformance = true;
        api.query = wrapped;
        return true;
      }
      var chromeOK = install(globalThis.chrome);
      if (globalThis.browser && globalThis.browser !== globalThis.chrome) install(globalThis.browser);
      return chromeOK;
    })()
    """#
}
