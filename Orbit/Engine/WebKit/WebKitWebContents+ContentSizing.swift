import AppKit
import ObjectiveC
import WebKit

// Self-sizing for a contents that must be as large as its document: an extension action popup.
// The page measures its own natural size (never the host's, which only ever grows) and posts it
// through a handler of this class's own, so an extension page never gains the tab bridge.
@MainActor
final class WebKitContentSizing: NSObject, WKScriptMessageHandler {
    static let handlerName = "orbitContentSizing"

    private weak var contents: WebKitWebContents?
    private(set) var minimum: CGSize
    private(set) var maximum: CGSize
    /// Strong while the web view is alive. A weak table zeroes the controller during its own dealloc.
    private var attachedControllers: [WKUserContentController] = []
    private var scriptedControllers: [WKUserContentController] = []
    private var lastReported: CGSize?
    /// Limits baked into a user script. A later change injects another script so the next document clamps with the new box.
    private var injectedMinimum: CGSize?
    private var injectedMaximum: CGSize?
    /// Limits last pushed into the live document. A change forces one new report even when the natural size did not.
    private var pushedMinimum: CGSize?
    private var pushedMaximum: CGSize?

    init(contents: WebKitWebContents, minimum: CGSize, maximum: CGSize) {
        self.contents = contents
        self.minimum = minimum
        self.maximum = maximum
        super.init()
    }

    func update(minimum: CGSize, maximum: CGSize) {
        self.minimum = minimum
        self.maximum = maximum
        lastReported = nil
    }

    /// Wires the web view up once per user content controller: a controller takes a handler name once.
    func attach(to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if !attachedControllers.contains(where: { $0 === controller }) {
            controller.add(self, name: Self.handlerName)
            attachedControllers.append(controller)
        }
        if !scriptedControllers.contains(where: { $0 === controller }) || injectedMinimum != minimum || injectedMaximum != maximum {
            addScript(to: controller)
            if !scriptedControllers.contains(where: { $0 === controller }) {
                scriptedControllers.append(controller)
            }
        }
        // Page zoom would scale the measured size and size the host wrong.
        webView.pageZoom = 1
        measure()
    }

    func addScript(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: Self.source(minimum: minimum, maximum: maximum),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        injectedMinimum = minimum
        injectedMaximum = maximum
    }

    /// Asks the current document to measure itself now, for the load that just finished.
    func measure() {
        guard let contents, !contents.isClosed else { return }
        let force = pushedMinimum != minimum || pushedMaximum != maximum
        pushedMinimum = minimum
        pushedMaximum = maximum
        // One round trip: the live clamp and the measure see the same box. `force` clears the
        // page's duplicate suppression when the box changed but the document did not.
        let script = """
        window.__orbitContentSizingLimits={minW:\(Self.js(minimum.width)),minH:\(Self.js(minimum.height)),maxW:\(Self.js(maximum.width)),maxH:\(Self.js(maximum.height))};
        window.__orbitMeasureContent && window.__orbitMeasureContent(\(force));
        """
        contents.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func js(_ value: CGFloat) -> String {
        let number = Double(value)
        guard number.isFinite else { return "0" }
        return String(number)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let contents, !contents.isClosed, message.webView === contents.webView,
              let body = message.body as? [String: Any],
              let width = (body["width"] as? NSNumber)?.doubleValue,
              let height = (body["height"] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0
        else { return }
        let size = CGSize(
            width: min(max(width, minimum.width), maximum.width),
            height: min(max(height, minimum.height), maximum.height)
        )
        guard size != lastReported else { return }
        lastReported = size
        contents.delegate?.webContents(contents, didChangePreferredSize: size)
    }

    /// Drop the handler before the web view goes. The controller deallocates on the next turn.
    func detach() {
        for controller in attachedControllers {
            controller.removeScriptMessageHandler(forName: Self.handlerName)
        }
        attachedControllers.removeAll()
        scriptedControllers.removeAll()
        contents = nil
    }

    private static func source(minimum: CGSize, maximum: CGSize) -> String {
        """
        (function () {
          window.__orbitContentSizingLimits = { minW: \(Self.js(minimum.width)), minH: \(Self.js(minimum.height)), maxW: \(Self.js(maximum.width)), maxH: \(Self.js(maximum.height)) };
          if (window.__orbitContentSizing) { return; }
          window.__orbitContentSizing = true;
          var last = "";
          var timer = 0;
          var mutations = null;
          var watch = { subtree: true, childList: true, attributes: true, characterData: true };
          function save(element, names) {
            var saved = {};
            names.forEach(function (name) {
              saved[name] = [element.style.getPropertyValue(name), element.style.getPropertyPriority(name)];
            });
            return saved;
          }
          function restore(element, saved) {
            Object.keys(saved).forEach(function (name) {
              if (saved[name][0]) { element.style.setProperty(name, saved[name][0], saved[name][1]); }
              else { element.style.removeProperty(name); }
            });
          }
          function reconnect() {
            if (!mutations || !document.documentElement) { return; }
            mutations.observe(document.documentElement, watch);
            mutations.takeRecords();
          }
          // The natural width is the root's max-content width; the height is read at the width
          // that will be used, with viewport-relative heights set aside so a roomy host cannot hold the size up.
          // The observer is disconnected across the write: otherwise the style edits schedule another measure.
          function measure() {
            timer = 0;
            var root = document.documentElement, body = document.body;
            var box = window.__orbitContentSizingLimits;
            if (!root || !body || !box) { return; }
            if (mutations) { mutations.disconnect(); }
            var rootSaved = save(root, ["width", "height", "overflow", "min-height", "max-height"]);
            var bodySaved = save(body, ["width", "height", "overflow", "min-height", "max-height"]);
            var width = 0, height = 0;
            try {
              // overflow:hidden on the root keeps the border box at the 25×25 host, so a
              // popup with a real min-width is reported as the loading box and the bubble stays there.
              root.style.setProperty("overflow", "visible", "important");
              body.style.setProperty("overflow", "visible", "important");
              root.style.setProperty("min-height", "0", "important");
              body.style.setProperty("min-height", "0", "important");
              root.style.setProperty("max-height", "none", "important");
              body.style.setProperty("max-height", "none", "important");
              root.style.setProperty("width", "max-content", "important");
              body.style.setProperty("width", "max-content", "important");
              root.style.setProperty("height", "max-content", "important");
              body.style.setProperty("height", "max-content", "important");
              // root.scrollWidth stays the viewport: the initial containing block will not shrink.
              var natural = Math.ceil(Math.max(body.getBoundingClientRect().width, body.scrollWidth));
              width = Math.max(natural, box.minW);
              root.style.setProperty("width", width + "px", "important");
              body.style.setProperty("width", width + "px", "important");
              height = Math.max(Math.ceil(Math.max(body.getBoundingClientRect().height, body.scrollHeight)), box.minH);
            } finally {
              restore(root, rootSaved);
              restore(body, bodySaved);
              reconnect();
            }
            if (!(width > 0) || !(height > 0)) { return; }
            var key = width + "x" + height;
            if (key === last) { return; }
            last = key;
            try { window.webkit.messageHandlers.\(handlerName).postMessage({ width: width, height: height }); } catch (e) {}
          }
          function schedule() { if (!timer) { timer = setTimeout(measure, 16); } }
          window.__orbitMeasureContent = function (force) {
            if (timer) { clearTimeout(timer); timer = 0; }
            if (force) { last = ""; }
            measure();
          };
          function observe() {
            if (mutations || !document.documentElement) { return; }
            mutations = new MutationObserver(schedule);
            mutations.observe(document.documentElement, watch);
          }
          observe();
          document.addEventListener("DOMContentLoaded", function () { observe(); schedule(); });
          window.addEventListener("load", function () {
            schedule();
            [100, 400, 1200].forEach(function (delay) { setTimeout(schedule, delay); });
          }, true);
          // Resource loads do not bubble. Capture catches an image or frame that arrives after the
          // mutation observer has already seen the element. A resize observer is not used: the host
          // applies the size we report, and watching the document element measures that host back.
          document.addEventListener("load", schedule, true);
          ["transitionend", "animationend"].forEach(function (name) {
            document.addEventListener(name, schedule, true);
          });
          if (document.fonts && document.fonts.ready) { document.fonts.ready.then(schedule); }
        })();
        """
    }
}

private nonisolated(unsafe) var contentSizingKey: UInt8 = 0

extension WebKitWebContents {
    var contentSizing: WebKitContentSizing? {
        objc_getAssociatedObject(self, &contentSizingKey) as? WebKitContentSizing
    }

    /// The document's own size, clamped to `minimum`...`maximum`, reported through `didChangePreferredSize`.
    func enableContentSizing(minimum: CGSize, maximum: CGSize) {
        guard !isClosed else { return }
        if let existing = contentSizing {
            existing.update(minimum: minimum, maximum: maximum)
            existing.attach(to: webView)
            return
        }
        let sizing = WebKitContentSizing(contents: self, minimum: minimum, maximum: maximum)
        objc_setAssociatedObject(self, &contentSizingKey, sizing, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        sizing.attach(to: webView)
    }
}
