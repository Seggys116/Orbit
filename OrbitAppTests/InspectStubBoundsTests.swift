//  The early-capture stub runs in every page, with the inspector closed, for as long as the page lives. Its listener records must stay bounded and must not keep a page's closures alive; a page that adds listeners forever used to make every removal scan a list that only grew, and kept every once-only handler in memory.

import WebKit
import XCTest
@testable import Orbit

@MainActor
final class InspectStubBoundsTests: XCTestCase {

    private final class Loader: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private func run(_ script: String) async throws -> [String: Any] {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: OrbitInspectAgent.stubSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loader = Loader()
        web.navigationDelegate = loader
        await withCheckedContinuation { continuation in
            loader.continuation = continuation
            web.loadHTMLString("<html><body><p>page</p></body></html>", baseURL: URL(string: "https://example.test/"))
        }
        let value = try await web.callAsyncJavaScript("return " + script, arguments: [:], in: nil, contentWorld: .page)
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testListenerRecordsStayBoundedWhateverAPageAdds() async throws {
        let result = try await run("""
        (function () {
          var target = document.body;
          var list = function () { var l = window.__orbitInspectEarly.listeners.get(target); return l ? l.length : 0; };
          var out = {};
          var same = function () {};
          for (var i = 0; i < 50000; i++) target.addEventListener("click", same);
          out.afterReAdds = list();
          for (var j = 0; j < 20000; j++) { var f = function () {}; target.addEventListener("scroll", f); target.removeEventListener("scroll", f); }
          out.afterAddRemove = list();
          for (var k = 0; k < 20000; k++) { target.addEventListener("ping", function () {}, { once: true }); target.dispatchEvent(new Event("ping")); }
          out.afterOnce = list();
          for (var m = 0; m < 30000; m++) target.addEventListener("distinct" + (m % 1000), function () {});
          out.afterManyLive = list();
          return JSON.stringify(out);
        })()
        """)
        XCTAssertEqual(result["afterReAdds"] as? Int, 1, "the engine ignores a handler added again, so it is one listener")
        XCTAssertEqual(result["afterAddRemove"] as? Int, 1, "a listener that was added and removed leaves no record")
        XCTAssertLessThanOrEqual(result["afterOnce"] as? Int ?? .max, 1100, "once-only listeners the engine removes itself do not pile up")
        XCTAssertLessThanOrEqual(result["afterManyLive"] as? Int ?? .max, 1100, "and no page can make one target's list unbounded")
    }

    func testListenersAreStillListedAndRemoved() async throws {
        let result = try await run("""
        (function () {
          var target = document.body;
          var a = function () {}, b = function () {}, c = function () {};
          target.addEventListener("x", a); target.addEventListener("x", b); target.addEventListener("y", c, true);
          var list = window.__orbitInspectEarly.listeners.get(target);
          var name = function (r) { return r.type + (r.capture ? "+capture" : "") + ":" + (r.handler === a ? "a" : r.handler === b ? "b" : "c"); };
          var out = { added: list.map(name).join(",") };
          target.removeEventListener("x", b);
          out.removed = list.map(name).join(",");
          target.removeEventListener("y", c);
          out.wrongCapture = list.length;
          out.handlerIsReadable = typeof list[0].handler;
          return JSON.stringify(out);
        })()
        """)
        XCTAssertEqual(result["added"] as? String, "x:a,x:b,y+capture:c")
        XCTAssertEqual(result["removed"] as? String, "x:a,y+capture:c")
        XCTAssertEqual(result["wrongCapture"] as? Int, 2, "removing with another capture flag removes nothing in the engine, so it removes nothing here")
        XCTAssertEqual(result["handlerIsReadable"] as? String, "function", "the Elements panel reads each record's handler")
    }

    func testConsoleStackCaptureIsRateLimited() async throws {
        let result = try await run("""
        (function () {
          for (var i = 0; i < 5000; i++) console.error("e" + i);
          var entries = window.__orbitInspectEarly.con;
          var withStack = 0;
          for (var j = 0; j < entries.length; j++) if (entries[j].e) withStack++;
          return JSON.stringify({ kept: entries.length, withStack: withStack });
        })()
        """)
        XCTAssertLessThanOrEqual(result["withStack"] as? Int ?? .max, 400, "a page in an error loop does not pay for a stack on every call")
        XCTAssertGreaterThan(result["kept"] as? Int ?? 0, 0)
    }
}
