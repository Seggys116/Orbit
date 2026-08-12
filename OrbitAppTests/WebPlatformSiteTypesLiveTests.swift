//  Live coverage for real site shapes: a heavy SPA with dynamic import(), multi-page navigation,
//  many subresources, cross-origin iframes, a service worker, a PWA manifest, and a large DOM.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebPlatformSiteTypesLiveTests: XCTestCase {

    private func waitUntilTrue(
        _ contents: ChromiumWebContents,
        _ expression: String,
        timeout: Duration = .seconds(15)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            let result = try await contents.evaluateJavaScript(expression)
            if (result as? Bool) == true { return }
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "'\(expression)' never became true")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Heavy SPA: nested dynamic import() code-splitting

    func testHeavySPAWithNestedDynamicImportsBuildsItsDOMFromCodeSplitChunks() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let text = try LiveChromiumEngineHost.runLive { () -> String in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><div id=\"root\">loading</div><script type=\"module\" src=\"/main.mjs\"></script></body></html>"
                ),
                "/main.mjs": LiveHTTPTestServer.Route(
                    contentType: "text/javascript",
                    body: """
                    import('/chunk-a.mjs').then(function(a) {
                      document.getElementById('root').textContent = a.render();
                    });
                    """
                ),
                "/chunk-a.mjs": LiveHTTPTestServer.Route(
                    contentType: "text/javascript",
                    body: """
                    import { render as renderB } from '/chunk-b.mjs';
                    export function render() { return 'chunk-a+' + renderB(); }
                    """
                ),
                "/chunk-b.mjs": LiveHTTPTestServer.Route(
                    contentType: "text/javascript",
                    body: "export function render() { return 'chunk-b'; }"
                ),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntilTrue(contents, "document.getElementById('root').textContent !== 'loading'")
            return (try await contents.evaluateJavaScript("document.getElementById('root').textContent")) as? String ?? ""
        }
        XCTAssertEqual(text, "chunk-a+chunk-b", "nested dynamic import() code-splitting never resolved both real module chunks")
    }

    // MARK: - Static content site: several real distinct pages

    func testStaticContentSiteNavigatesAcrossSeveralRealDistinctPages() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let titles = try LiveChromiumEngineHost.runLive { () -> [String] in
            let server = try LiveHTTPTestServer(routes: [
                "/page1": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><head><title>Orbit Page One</title></head><body>one</body></html>"),
                "/page2": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><head><title>Orbit Page Two</title></head><body>two</body></html>"),
                "/page3": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><head><title>Orbit Page Three</title></head><body>three</body></html>"),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            var seenTitles: [String] = []
            for page in ["page1", "page2", "page3"] {
                contents.load(server.baseURL.appendingPathComponent(page))
                try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
                let title = try await contents.evaluateJavaScript("document.title")
                seenTitles.append((title as? String) ?? "")
            }
            return seenTitles
        }
        XCTAssertEqual(titles, ["Orbit Page One", "Orbit Page Two", "Orbit Page Three"], "navigating across a real static multi-page site did not settle on each page's own real title in order")
    }

    // MARK: - Many subresources: correctness, not just latency

    /// Complements ChromiumPageLoadLatencyLiveTests: this proves every subresource actually
    /// loaded, which a latency-only budget could miss if some silently dropped.
    func testPageWithManySubresourcesActuallyLoadsEveryOne() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subresourceCount = 40
        let loadedCount = try LiveChromiumEngineHost.runLive { () -> Int in
            var routes: [String: LiveHTTPTestServer.Route] = [:]
            var scriptTags = ""
            for index in 0..<subresourceCount {
                routes["/r\(index).js"] = LiveHTTPTestServer.Route(
                    contentType: "application/javascript",
                    body: "window.__orbitSubresourceLoaded = (window.__orbitSubresourceLoaded || 0) + 1;"
                )
                scriptTags += "<script src=\"/r\(index).js\"></script>\n"
            }
            routes["/"] = LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>\(scriptTags)</body></html>")
            let server = try LiveHTTPTestServer(routes: routes)
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let result = try await contents.evaluateJavaScript("window.__orbitSubresourceLoaded || 0")
            return (result as? NSNumber)?.intValue ?? 0
        }
        XCTAssertEqual(loadedCount, subresourceCount, "not every one of \(subresourceCount) real subresources ran -- some were silently dropped")
    }

    // MARK: - Iframe-heavy, genuinely cross-origin

    func testIframeHeavyPageLoadsCrossOriginFramesThatEachRunIndependently() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let receivedFrom = try LiveChromiumEngineHost.runLive { () -> [String] in
            // Three separate listen sockets on 127.0.0.1, each its own port -- distinct
            // origins by scheme+host+port, no DNS or public internet involved.
            let frameServerB = try LiveHTTPTestServer(routes: [
                "/frame": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><script>window.parent.postMessage({from:'frame-b'}, '*');</script></body></html>"
                ),
            ])
            defer { frameServerB.stop() }
            let frameServerC = try LiveHTTPTestServer(routes: [
                "/frame": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><script>window.parent.postMessage({from:'frame-c'}, '*');</script></body></html>"
                ),
            ])
            defer { frameServerC.stop() }

            // The message listener must be part of the host page's own parsed HTML: injecting it
            // via evaluateJavaScript afterward loses it, since contents.load(_:) replaces window/document.
            let hostServer = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: """
                    <html><body>
                    <script>
                    window.__orbitFrameMessages = [];
                    window.addEventListener('message', function(e) {
                      if (e.data && e.data.from) { window.__orbitFrameMessages.push(e.data.from); }
                    });
                    </script>
                    <iframe src="/frame-a"></iframe>
                    <iframe src="http://127.0.0.1:\(frameServerB.port)/frame"></iframe>
                    <iframe src="http://127.0.0.1:\(frameServerC.port)/frame"></iframe>
                    </body></html>
                    """
                ),
                "/frame-a": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><script>window.parent.postMessage({from:'frame-a'}, '*');</script></body></html>"
                ),
            ])
            defer { hostServer.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)

            contents.load(hostServer.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntilTrue(contents, "!!window.__orbitFrameMessages && window.__orbitFrameMessages.length === 3")

            let result = try await contents.evaluateJavaScript("window.__orbitFrameMessages.slice().sort()")
            return (result as? [Any])?.compactMap { $0 as? String } ?? []
        }
        XCTAssertEqual(receivedFrom, ["frame-a", "frame-b", "frame-c"], "not every one of 3 real (one same-origin, two cross-origin) iframes ran and posted back to the parent")
    }

    // MARK: - Service worker: registration, active state, real fetch interception

    func testServiceWorkerRegistersReachesActiveStateAndInterceptsAFetch() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (registered, controlled, interceptedBody) = try LiveChromiumEngineHost.runLive { () -> (Bool, Bool, String) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body>orbit-service-worker-test</body></html>"
                ),
                "/sw.js": LiveHTTPTestServer.Route(
                    contentType: "text/javascript",
                    body: """
                    self.addEventListener('install', function(e) { self.skipWaiting(); });
                    self.addEventListener('activate', function(e) { e.waitUntil(self.clients.claim()); });
                    self.addEventListener('fetch', function(e) {
                      if (e.request.url.indexOf('/intercepted') !== -1) {
                        e.respondWith(new Response('service-worker-response', { headers: { 'Content-Type': 'text/plain' } }));
                      }
                    });
                    """
                ),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            window.__orbitSWReady = false;
            navigator.serviceWorker.register('/sw.js').then(function() {
              return navigator.serviceWorker.ready;
            }).then(function() { window.__orbitSWReady = true; })
            .catch(function(e) { window.__orbitSWError = String(e); });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitSWReady === true || !!window.__orbitSWError", timeout: .seconds(20))
            let ready = ((try await contents.evaluateJavaScript("window.__orbitSWReady === true")) as? Bool) ?? false

            try await self.waitUntilTrue(contents, "navigator.serviceWorker.controller !== null", timeout: .seconds(10))
            let isControlled = ((try await contents.evaluateJavaScript("navigator.serviceWorker.controller !== null")) as? Bool) ?? false

            _ = try await contents.evaluateJavaScript("""
            window.__orbitInterceptedBody = null;
            fetch('/intercepted').then(function(r) { return r.text(); }).then(function(text) {
              window.__orbitInterceptedBody = text;
            }).catch(function(e) { window.__orbitInterceptedBody = 'error:' + String(e); });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitInterceptedBody !== null")
            let body = (try await contents.evaluateJavaScript("window.__orbitInterceptedBody")) as? String ?? ""

            return (ready, isControlled, body)
        }

        XCTAssertTrue(registered, "navigator.serviceWorker.register + .ready never resolved -- the real service worker never reached the active state")
        XCTAssertTrue(controlled, "clients.claim() from the real service worker's activate handler never made this page's own client controlled")
        XCTAssertEqual(interceptedBody, "service-worker-response", "a controlled page's fetch('/intercepted') did not go through the real service worker's fetch event -- it must not have reached the server's real 404 either, since that has different content")
    }

    // MARK: - PWA manifest

    func testPWAManifestIsLinkedAndFetchableWithItsRealFields() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (linkedHref, name, display) = try LiveChromiumEngineHost.runLive { () -> (String, String, String) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><head><link rel=\"manifest\" href=\"/manifest.json\"></head><body>orbit-pwa-test</body></html>"
                ),
                "/manifest.json": LiveHTTPTestServer.Route(
                    contentType: "application/manifest+json",
                    body: """
                    {"name":"Orbit Live Test PWA","short_name":"OrbitPWA","start_url":"/","display":"standalone"}
                    """
                ),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let href = try await contents.evaluateJavaScript("document.querySelector('link[rel=manifest]').href")

            _ = try await contents.evaluateJavaScript("""
            window.__orbitManifest = null;
            fetch(document.querySelector('link[rel=manifest]').href).then(function(r) { return r.json(); }).then(function(json) {
              window.__orbitManifest = json;
            }).catch(function(e) { window.__orbitManifest = { error: String(e) }; });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitManifest !== null")
            let manifest = try await contents.evaluateJavaScript("window.__orbitManifest")
            let dictionary = manifest as? [String: Any] ?? [:]
            return ((href as? String) ?? "", (dictionary["name"] as? String) ?? "", (dictionary["display"] as? String) ?? "")
        }

        XCTAssertTrue(linkedHref.hasSuffix("/manifest.json"), "the page's <link rel=manifest> did not resolve to the real manifest URL")
        XCTAssertEqual(name, "Orbit Live Test PWA", "fetching the linked manifest did not return its real declared name")
        XCTAssertEqual(display, "standalone", "fetching the linked manifest did not return its real declared display mode")
    }

    // MARK: - Large DOM

    func testLargeDOMPageFullyParsesAndEveryNodeIsQueryable() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let nodeCount = 5000
        let (count, lastText) = try LiveChromiumEngineHost.runLive { () -> (Int, String) in
            var items = ""
            for index in 0..<nodeCount {
                items += "<li>item-\(index)</li>"
            }
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body><ul id=\"list\">\(items)</ul></body></html>"),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let countResult = try await contents.evaluateJavaScript("document.querySelectorAll('#list li').length")
            let lastResult = try await contents.evaluateJavaScript("document.querySelectorAll('#list li')[document.querySelectorAll('#list li').length - 1].textContent")
            return ((countResult as? NSNumber)?.intValue ?? -1, (lastResult as? String) ?? "")
        }

        XCTAssertEqual(count, nodeCount, "a large DOM (\(nodeCount) real elements) did not fully parse -- querySelectorAll found the wrong count")
        XCTAssertEqual(lastText, "item-\(nodeCount - 1)", "the last of \(nodeCount) real DOM nodes did not have its real expected content")
    }
}
