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

    var mainFrameNavigationType: WKNavigationType = .other
    var browserInitiatedLoad = false
    /// A windowless reload goes via about:blank first. `load` of the committed URL is not a reload.
    var originReloadURL: URL?
    /// The URL `load` was asked for. WebKit does not expose a provisional URL until the
    /// response headers arrive, so a connection that never answers has no other pending address.
    var requestedLoadURL: URL?

    /// One answer per host for a main-frame navigation: WebKit repeats a failed trust challenge, and a refusal must not reopen the interstitial.
    var trustDecisions: [String: Task<Bool, Never>] = [:]

    weak var hostContainer: NSView?
    var frameObserver: NSObjectProtocol?
    var inspectorFrontend: WebKitInspectorFrontend?
    var dockSideRelay: InspectorDockSideRelay?
    weak var dockRelayWebView: WKWebView?

    /// In-flight HTTP loads, keyed by WebKit's resource id, so onCompleted can repeat the headers from didReceiveResponse.
    var httpWebRequests: [UInt64: HTTPWebRequestRecord] = [:]
    /// One webNavigation.onErrorOccurred per navigation. The resource load and the navigation delegate both see the failure.
    var navigationFailureReported = false

    func tearDown() {
        observations.removeAll()
        pendingContextMenu = nil
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
    /// True while no pane is showing this page, which is also what WebKit treats as hidden: `OrbitWebView.window`
    /// is nil unless the view sits in a real window or a host has declared it visible via `setVisible(true)`.
    /// Native check only, so it is safe to read on a timer.
    var isBackgrounded: Bool {
        webView.window == nil
    }

    /// A hidden page is still probed while media is playing, audible, floating or fullscreen: the mini
    /// player and the picture-in-picture panel read the probe. A hidden page with none of those only
    /// needs the page script's own play/pause events, which already report without this round trip.
    var hasLiveMediaToObserve: Bool {
        mediaState.isPlaying || mediaState.isAudible
            || mediaState.isPictureInPictureActive || mediaState.isFullscreen
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
