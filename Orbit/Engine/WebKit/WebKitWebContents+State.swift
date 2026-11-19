import AppKit
import WebKit

/// Stored state for the WebKitWebContents extensions, which cannot declare properties of their own.
@MainActor
final class WebKitContentsExtras {
    var observations: [NSKeyValueObservation] = []

    var findGeneration = 0
    var findQuery = ""
    var findMatchCase = false
    var findOrdinal = 0
    var findCount = 0

    var pendingContextMenu: PendingContextMenu?
    /// WebKit's own menu for the right-click being shown, which already carries extension items; kept for the length of the gesture.
    var proposedContextMenu: NSMenu?
    /// The extension items read from that menu, kept until the next gesture so a click made after the menu closes still finds its NSMenuItem.
    var extensionMenu: WebKitExtensionContextMenuCapture.Snapshot?
    var contextMenuGeneration = 0

    var isElementFullscreen = false

    /// Awaited before each main-frame navigation decision; see `WebKitWebContents.setMainFrameNavigationHook`.
    var mainFrameNavigationHook: (@MainActor (URL) async -> Void)?
    var closeHook: (@MainActor () -> Void)?

    var mainFrameNavigationType: WKNavigationType = .other
    var browserInitiatedLoad = false
    /// A windowless reload goes via about:blank first. `load` of the committed URL is not a reload.
    var originReloadURL: URL?
    /// The URL `load` was asked for. WebKit does not expose a provisional URL until the
    /// response headers arrive, so a connection that never answers has no other pending address.
    var requestedLoadURL: URL?

    /// One answer per host for a main-frame navigation: WebKit repeats a failed trust challenge, and a refusal must not reopen the interstitial.
    var trustDecisions: [String: Task<Bool, Never>] = [:]

    /// A password prompt that is on screen, keyed by protection space. A second challenge for the same space waits for it instead of stacking another prompt.
    var credentialPrompts: [String: Task<HTTPCredentialResponse?, Never>] = [:]

    weak var hostContainer: NSView?
    var frameObserver: NSObjectProtocol?
    var inspectorFrontend: WebKitInspectorFrontend?
    var dockSideRelay: InspectorDockSideRelay?
    weak var dockRelayWebView: WKWebView?

    /// In-flight HTTP loads, keyed by WebKit's resource id, so onCompleted can repeat the headers from didReceiveResponse.
    var httpWebRequests: [UInt64: HTTPWebRequestRecord] = [:]
    /// One webNavigation.onErrorOccurred per navigation. The resource load and the navigation delegate both see the failure.
    var navigationFailureReported = false

    let passwords = WebKitPasswordsState()

    func tearDown() {
        observations.removeAll()
        pendingContextMenu = nil
        passwords.reset()
        httpWebRequests.removeAll()
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
    }

    struct HTTPWebRequestRecord {
        var requestID: String
        var url: URL
        var method: String
        var type: String
        var frameID: Int
        var parentFrameID: Int
        var statusCode: Int?
        var responseHeaders: [[String: String]]
    }

    /// The page-reported half of a right-click, waiting for WebKit's own menu request.
    struct PendingContextMenu {
        var location: CGPoint
        var info: [String: Any]?
        var menuRequested = false
        var generation: Int
    }
}

extension WebKitWebContents {
    /// True unless a pane in an on-screen window is showing this page. `OrbitWebView.window` cannot be used: it
    /// reports an off-screen compositing window while `keepsCompositingWithoutWindow` is set, so a hidden tab
    /// would look visible. Native check only, so it is safe to read on a timer.
    var isBackgrounded: Bool {
        guard let orbit = webView as? OrbitWebView else { return webView.window == nil }
        guard orbit.isInRealWindow, let window = orbit.window else { return true }
        // A pane keeps recently shown pages warm as hidden subviews; those are in a real window but not on screen.
        if orbit.isHiddenOrHasHiddenAncestor { return true }
        return !window.occlusionState.contains(.visible)
    }

    /// The tab is showing in the window the user is working in.
    var isInKeyWindow: Bool {
        !isBackgrounded && webView.window?.isKeyWindow == true
    }
}

/// Routes the isolated-world context menu messages to whichever web view posted them,
/// so a popup that shares its opener's user content controller still reports to itself.
@MainActor
final class WebKitContextMenuBridge: NSObject, WKScriptMessageHandler {
    static let shared = WebKitContextMenuBridge()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let owner = (message.webView as? OrbitWebView)?.menuOwner,
              let json = message.body as? String,
              let data = json.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        owner.contextMenuInfoArrived(info)
    }
}
