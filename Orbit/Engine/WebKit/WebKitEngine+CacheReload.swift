import AppKit
import Foundation
import WebKit

/// Which on-screen pages a cache clear must reload, and how.
///
/// `WKWebView.load` of the URL already committed is not a reload. WebKit records that
/// navigation as the same document (`FrameLoadType::Same`). The fetch cache mode is
/// switched to "reload" only for `FrameLoadType::ReloadFromOrigin`, so a same-document
/// load keeps the default mode and a still-fresh `Cache-Control` entry is painted again.
/// The data-store deletion can finish, the UI can say the cache was cleared, and the
/// document on screen never changes.
enum CacheReloadNavigation: Equatable {
    /// `WKWebView.reloadFromOrigin()`. The load stays a reload and is re-requested.
    case fromOrigin
    /// No committed document, so there is no same-document load to satisfy from cache.
    case unconditionalLoad
}

enum CacheReloadPlan {
    /// Panes on screen with `tabID`. A split shows every pane; anything else is one tab.
    /// Tabs outside that set are background tabs and stay where they are.
    static func visibleTabIDs(around tabID: TabID, splitTabIDs: [TabID]) -> [TabID] {
        if splitTabIDs.contains(tabID) { return splitTabIDs }
        return [tabID]
    }

    static func navigationAfterCacheWipe(hasCommittedDocument: Bool) -> CacheReloadNavigation {
        hasCommittedDocument ? .fromOrigin : .unconditionalLoad
    }
}

extension BrowserEngine {

    /// WebKit reloads from origin. Any other engine keeps the previous clear-then-reload.
    @MainActor
    func clearCacheAndReloadVisiblePages(_ pages: [any WebContents]) async {
        if let webKit = self as? WebKitEngine {
            await webKit.wipeHTTPCacheAndReloadFromOrigin(pages)
            return
        }
        var cleared: Set<ObjectIdentifier> = []
        for page in pages where !page.isClosed {
            guard cleared.insert(ObjectIdentifier(page.session)).inserted else { continue }
            await clearBrowsingData(.cache, session: page.session, since: nil)
        }
        for page in pages where !page.isClosed {
            page.reload(ignoringCache: true)
        }
    }
}

extension WebKitEngine {

    /// Wipes the HTTP cache for each page's session, then reloads those pages from origin.
    /// Sessions shared by a split are cleared once. Background tabs are not in `pages`.
    func wipeHTTPCacheAndReloadFromOrigin(_ pages: [any WebContents]) async {
        var cleared: Set<ObjectIdentifier> = []
        for page in pages where !page.isClosed {
            guard cleared.insert(ObjectIdentifier(page.session)).inserted else { continue }
            await clearBrowsingData(.cache, session: page.session, since: nil)
        }
        for page in pages where !page.isClosed {
            if let webKitPage = page as? WebKitWebContents {
                webKitPage.reloadDocumentFromOrigin()
            } else {
                page.reload(ignoringCache: true)
            }
        }
    }
}

/// Holds a windowless web view just long enough for WebKit to run a reload.
enum OffscreenWebViewHost {
    static let window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }()

    static func attach(_ view: NSView) {
        guard view.window == nil, let content = window.contentView else { return }
        for subview in content.subviews where subview !== view {
            subview.removeFromSuperview()
        }
        view.frame = content.bounds
        content.addSubview(view)
        window.orderBack(nil)
    }
}

extension WebKitWebContents {

    /// Re-requests the committed document. Does not call `reload(ignoringCache:)`, which
    /// loads the current URL and can be dropped: that load is same-document, and a
    /// `stopLoading()` issued just before it can cancel the navigation it starts.
    func reloadDocumentFromOrigin() {
        guard !isClosed else { return }
        let committed = webView.url != nil
        switch CacheReloadPlan.navigationAfterCacheWipe(hasCommittedDocument: committed) {
        case .fromOrigin:
            if webView.window == nil {
                reloadWindowlessFromOrigin()
                return
            }
            extras.browserInitiatedLoad = true
            if webView.reloadFromOrigin() == nil {
                extras.browserInitiatedLoad = false
            }
        case .unconditionalLoad:
            guard let url = navigationState.url else { return }
            extras.browserInitiatedLoad = true
            if url.isFileURL {
                load(url)
                return
            }
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 60
            )
            webView.load(request)
        }
    }

    /// `reloadFromOrigin` on a view with no window returns a navigation and never fetches.
    /// Leaving the committed document first makes the next load a real request.
    private func reloadWindowlessFromOrigin() {
        guard let url = navigationState.url ?? webView.url, !url.isFileURL else {
            if let url = navigationState.url { load(url) }
            return
        }
        extras.originReloadURL = url
        extras.browserInitiatedLoad = true
        OffscreenWebViewHost.attach(webView)
        guard let blank = URL(string: "about:blank"),
              webView.load(URLRequest(url: blank)) != nil
        else {
            extras.originReloadURL = nil
            loadIgnoringCache(url)
            return
        }
    }

    func continueOriginReloadIfNeeded() {
        guard let url = extras.originReloadURL else { return }
        let current = webView.url
        let blank = current == nil || current?.absoluteString == "about:blank" || current?.scheme == "about"
        guard blank else { return }
        extras.originReloadURL = nil
        loadIgnoringCache(url)
    }

    private func loadIgnoringCache(_ url: URL) {
        extras.browserInitiatedLoad = true
        webView.load(URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
        ))
    }
}
