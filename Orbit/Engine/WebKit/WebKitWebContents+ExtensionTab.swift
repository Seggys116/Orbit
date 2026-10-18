import AppKit
import NaturalLanguage
import ObjectiveC
import WebKit

// WebKit asks the app, not the web view, about a tab: where it sits, whether it is pinned or muted,
// and what to do when an extension navigates, closes or duplicates it. Each answer and each verb goes
// through the same AppEnvironment path the sidebar uses, so the UI stays in step with the extension.
extension WebKitWebContents {

    /// The Orbit window that owns this tab, once it has been adopted into one.
    var ownerEnvironment: AppEnvironment? { delegate as? AppEnvironment }

    private func extensionFailure(_ message: String) -> NSError {
        NSError(domain: "com.orbit.extension.tab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Placement

    @objc(windowForWebExtensionContext:)
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        engine.extensionWindow(of: self)
    }

    @objc(indexInWindowForWebExtensionContext:)
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        engine.extensionTabs(in: engine.extensionWindow(of: self)).firstIndex { $0 === self } ?? NSNotFound
    }

    @objc(isSelectedForWebExtensionContext:)
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        (engine.extensionActiveTab(in: engine.extensionWindow(of: self)) as AnyObject?) === self
    }

    @objc(isPinnedForWebExtensionContext:)
    func isPinned(for context: WKWebExtensionContext) -> Bool {
        ownerEnvironment?.extensionTabIsPinned(self) ?? false
    }

    @objc(setPinned:forWebExtensionContext:completionHandler:)
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let environment = ownerEnvironment, environment.extensionSetPinned(self, pinned: pinned) else {
            completionHandler(extensionFailure("This tab cannot be pinned."))
            return
        }
        completionHandler(nil)
    }

    // MARK: - Audio

    @objc(isMutedForWebExtensionContext:)
    func isMuted(for context: WKWebExtensionContext) -> Bool {
        mediaState.isMuted
    }

    @objc(setMuted:forWebExtensionContext:completionHandler:)
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let environment = ownerEnvironment, environment.extensionSetMuted(self, muted: muted) {
            completionHandler(nil)
            return
        }
        setMuted(muted)
        completionHandler(nil)
    }

    @objc(isPlayingAudioForWebExtensionContext:)
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        mediaState.isAudible
    }

    // MARK: - Size and zoom

    @objc(sizeForWebExtensionContext:)
    func size(for context: WKWebExtensionContext) -> CGSize {
        webView.bounds.size
    }

    @objc(zoomFactorForWebExtensionContext:)
    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        webView.pageZoom
    }

    // Through setZoomFactor(_:), so the per-site zoom Orbit remembers follows what the extension set.
    @objc(setZoomFactor:forWebExtensionContext:completionHandler:)
    func setZoomFactor(_ factor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        let requested = factor > 0 ? factor : SiteZoomStore.defaultZoomFactor
        setZoomFactor(min(max(requested, ZoomStep.p25.rawValue), ZoomStep.p500.rawValue))
        completionHandler(nil)
    }

    // MARK: - Page facts

    @objc(detectWebpageLocaleForWebExtensionContext:completionHandler:)
    func detectWebpageLocale(for context: WKWebExtensionContext, completionHandler: @escaping (Locale?, Error?) -> Void) {
        let script = """
        (function () {
          var meta = document.querySelector('meta[http-equiv="content-language" i]');
          var declared = document.documentElement.getAttribute('lang') || (meta && meta.getAttribute('content')) || '';
          var text = document.body ? (document.body.innerText || '').slice(0, 4000) : '';
          return JSON.stringify({ lang: declared, text: text });
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                completionHandler(nil, error)
                return
            }
            let object = (result as? String)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let declared = (object?["lang"] as? String)?
                .split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if !declared.isEmpty {
                completionHandler(Locale(identifier: declared.replacingOccurrences(of: "-", with: "_")), nil)
                return
            }
            let text = object?["text"] as? String ?? ""
            if !text.isEmpty, let language = NLLanguageRecognizer.dominantLanguage(for: text) {
                completionHandler(Locale(identifier: language.rawValue), nil)
                return
            }
            completionHandler(nil, nil)
        }
    }

    @objc(takeSnapshotUsingConfiguration:forWebExtensionContext:completionHandler:)
    func takeSnapshot(
        using configuration: WKSnapshotConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (NSImage?, Error?) -> Void
    ) {
        webView.takeSnapshot(with: configuration) { image, error in
            completionHandler(image, error)
        }
    }

    // MARK: - Navigation

    @objc(loadURL:forWebExtensionContext:completionHandler:)
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let environment = ownerEnvironment, environment.extensionLoad(url, in: self) {
            completionHandler(nil)
            return
        }
        load(url)
        completionHandler(nil)
    }

    @objc(goBackForWebExtensionContext:completionHandler:)
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard webView.canGoBack else {
            completionHandler(extensionFailure("There is no previous page in this tab's history."))
            return
        }
        goBack()
        completionHandler(nil)
    }

    @objc(goForwardForWebExtensionContext:completionHandler:)
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard webView.canGoForward else {
            completionHandler(extensionFailure("There is no next page in this tab's history."))
            return
        }
        goForward()
        completionHandler(nil)
    }

    // MARK: - Tab verbs

    @objc(activateForWebExtensionContext:completionHandler:)
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let environment = ownerEnvironment, environment.extensionActivate(self) {
            completionHandler(nil)
            return
        }
        engine.noteActive(self)
        completionHandler(nil)
    }

    @objc(duplicateUsingConfiguration:forWebExtensionContext:completionHandler:)
    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        let requested = configuration.index
        guard let environment = ownerEnvironment,
              let copy = environment.extensionDuplicate(
                  self,
                  windowIndex: (0..<1_000_000).contains(requested) ? requested : nil,
                  active: configuration.shouldBeActive,
                  pinned: configuration.shouldBePinned,
                  muted: configuration.shouldBeMuted
              )
        else {
            completionHandler(nil, extensionFailure("This tab cannot be duplicated."))
            return
        }
        completionHandler(copy, nil)
    }

    @objc(closeForWebExtensionContext:completionHandler:)
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        ExtensionTabCloseGate.begin(self, completion: completionHandler)
    }

    @objc(pendingURLForWebExtensionContext:)
    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard navigationState.isLoading, let pending = inFlightURL() else { return nil }
        if let committed = committedDocumentURL(), pending == committed { return nil }
        return pending
    }

    func inFlightURL() -> URL? {
        if navigationState.isLoading, let requested = extras.requestedLoadURL { return requested }
        if let provisional = privateWebViewURL("_provisionalURL") { return provisional }
        return navigationState.url ?? webView.url
    }

    func committedDocumentURL() -> URL? {
        if let url = webView.backForwardList.currentItem?.url { return url }
        return privateWebViewURL("_committedURL")
    }

    func privateWebViewURL(_ name: String) -> URL? {
        let selector = NSSelectorFromString(name)
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? URL
    }

    // MARK: - chrome.contextMenus

    /// Items for the right-click's own gesture come from the menu WebKit proposed for it, which carries
    /// every context (link, selection, image, frame, editable). Without one, as for a toolbar menu,
    /// WebKit's tab-level list is all there is.
    func extensionContextMenuGroups() -> [ExtensionContextMenuGroup] {
        guard !isClosed else { return [] }
        if let groups = extras.extensionMenu?.groups, !groups.isEmpty { return groups }
        return engine.loadedExtensionContexts().compactMap { entry in
            let items = Self.contextMenuItems(from: entry.context.menuItems(for: self), extensionID: entry.id, path: [])
            return items.isEmpty ? nil : ExtensionContextMenuGroup(extensionID: entry.id, extensionName: entry.name, items: items)
        }
    }

    /// Called as WebKit hands over its proposed menu, while its items are still live.
    func captureExtensionMenu(from menu: NSMenu) -> WebKitExtensionContextMenuCapture.Snapshot? {
        let owners = engine.loadedExtensionContexts().map { entry in
            let web = entry.context.webExtension
            let titles = Self.flattenedTitles(entry.context.menuItems(for: self))
            return WebKitExtensionContextMenuCapture.Owner(
                id: entry.id,
                name: entry.name,
                wrapperTitles: Set([entry.name, web.displayName, web.displayShortName].compactMap { $0 }),
                tabTitles: Set(titles)
            )
        }
        let snapshot = WebKitExtensionContextMenuCapture.capture(from: menu, owners: owners)
        return snapshot.groups.isEmpty ? nil : snapshot
    }

    private static func flattenedTitles(_ items: [NSMenuItem]) -> [String] {
        items.flatMap { item in
            (item.isSeparatorItem ? [] : [item.title]) + flattenedTitles(item.submenu?.items ?? [])
        }
    }

    // The id is the item's place in the menu plus its title: WebKit builds the items afresh on every
    // call, so the click finds the same item again by position and checks the title still agrees.
    private static func contextMenuItems(from menuItems: [NSMenuItem], extensionID: String, path: [Int]) -> [ExtensionContextMenuItem] {
        menuItems.enumerated().compactMap { index, item in
            guard !item.isHidden else { return nil }
            let itemPath = path + [index]
            let stringUID = itemPath.map(String.init).joined(separator: ".") + "|" + item.title
            let id = ExtensionContextMenuItemID(extensionID: extensionID, stringUID: stringUID)
            if item.isSeparatorItem {
                return ExtensionContextMenuItem(id: id, title: "", type: .separator)
            }
            let children = item.submenu.map { contextMenuItems(from: $0.items, extensionID: extensionID, path: itemPath) } ?? []
            return ExtensionContextMenuItem(
                id: id,
                title: item.title,
                type: .normal,
                isChecked: item.state != .off,
                isEnabled: item.isEnabled,
                children: children
            )
        }
    }

    /// Fires the item's WebKit action, which raises `onClicked` with this tab and the click's info.
    func performExtensionContextMenuItem(_ id: ExtensionContextMenuItemID) {
        guard !isClosed else { return }
        if let item = extras.extensionMenu?.actions[id] {
            guard item.isEnabled, let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        guard let context = engine.loadedExtensionContext(id: id.extensionID)?.context else { return }
        let parts = id.stringUID.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let path = parts[0].split(separator: ".").compactMap { Int($0) }
        var level = context.menuItems(for: self)
        var target: NSMenuItem?
        for (depth, index) in path.enumerated() {
            guard level.indices.contains(index) else { return }
            if depth == path.count - 1 {
                target = level[index]
            } else {
                level = level[index].submenu?.items ?? []
            }
        }
        guard let item = target, item.isEnabled, item.title == String(parts[1]), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// Keeps a tab's WKWebView alive across `chrome.tabs.remove` until WebKit has left the close
/// callback. Deallocating on that stack trips WKWebView (`idle` -> `failed(deinit)`) and takes
/// the web process down with the content script that asked for the close.
@MainActor
private enum ExtensionTabCloseGate {
    private static var held: [ObjectIdentifier: WebKitWebContents] = [:]
    private static var scheduled: Set<ObjectIdentifier> = []

    static func begin(_ contents: WebKitWebContents, completion: @escaping (Error?) -> Void) {
        let key = ObjectIdentifier(contents)
        held[key] = contents
        guard scheduled.insert(key).inserted else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if !contents.isClosed {
            let closedBySidebar = contents.ownerEnvironment?.extensionClose(contents) ?? false
            if !closedBySidebar { contents.close() }
        }
        // The tab has left the sidebar and chrome.tabs. The WKWebView is still alive, so
        // this reply can be delivered. The view is destroyed only after that, off this stack.
        completion(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            DispatchQueue.main.async {
                if !contents.isClosed {
                    contents.teardown(notifyExtensionController: false)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    DispatchQueue.main.async {
                        scheduled.remove(key)
                        held.removeValue(forKey: key)
                    }
                }
            }
        }
    }
}
