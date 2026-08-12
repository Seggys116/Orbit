//  Per-API suites can stay green while a real extension does nothing (isolated
//  registration, not proxied delivery); this drives one modelled on Wappalyzer end to end.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumRealExtensionEndToEndLiveTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private static let reportAttribute = "data-orbit-analysis-report"
    private static let popupResultElementID = "orbit-popup-result"
    private static let popupActiveTabResultElementID = "orbit-popup-active-tab-result"

    // MARK: - The page under analysis

    // The shape a technology profiler reads: a generator meta tag, a script
    // subresource, and a global only reachable from the page's main world.
    private static let realisticPage = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="generator" content="Orbit Test CMS 4.2.1">
    <meta name="description" content="orbit real extension end to end fixture">
    <title>Orbit Real Extension Fixture</title>
    <script src="/vendor/jquery.js"></script>
    </head>
    <body>
    <div id="app">orbit-real-extension-fixture</div>
    </body>
    </html>
    """

    private static let mainFrameHeaderName = "X-Orbit-Powered-By"
    private static let mainFrameHeaderValue = "OrbitTestServer/8.2.10"

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html",
                body: Self.realisticPage,
                extraHeaders: [Self.mainFrameHeaderName: Self.mainFrameHeaderValue]
            ),
            // Sets a real page-world global, which is the only way the
            // injected web_accessible_resource can observe it.
            "/vendor/jquery.js": LiveHTTPTestServer.Route(
                contentType: "application/javascript",
                body: "window.jQuery = { fn: { jquery: '3.7.1' } };"
            ),
        ])
    }

    // MARK: - The fixture extension

    private static let injectedMarker = "orbit-web-accessible-resource-marker"

    private struct Fixture {
        let directory: URL
    }

    private func writeFixture(named name: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-RealExtension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["webRequest", "tabs"],
          "host_permissions": ["http://127.0.0.1/*"],
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle" }
          ],
          "web_accessible_resources": [
            { "resources": ["injected.js"], "matches": ["http://*/*"] }
          ],
          "action": { "default_popup": "popup.html" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // webRequest listeners registered exactly as Wappalyzer registers
        // them, plus a message router storing detections per hostname/tab.
        let background = """
        var state = {
          onResponseStarted: [],
          onCompleted: [],
          onCompletedScript: [],
          detections: {},
          tabDetections: {},
          contentLoads: 0,
          errors: []
        };

        function record(hostname, tabId, names) {
          state.detections[hostname] = state.detections[hostname] || [];
          var bucket = state.detections[hostname];
          names.forEach(function (n) { if (bucket.indexOf(n) === -1) { bucket.push(n); } });
          if (typeof tabId === 'number' && tabId >= 0) {
            state.tabDetections[tabId] = state.tabDetections[tabId] || [];
            var tabBucket = state.tabDetections[tabId];
            names.forEach(function (n) { if (tabBucket.indexOf(n) === -1) { tabBucket.push(n); } });
          }
        }

        function hostnameOf(url) {
          try { return new URL(url).hostname; } catch (e) { return ''; }
        }

        chrome.webRequest.onResponseStarted.addListener(
          function (request) {
            state.onResponseStarted.push({
              url: request.url, tabId: request.tabId, type: request.type, statusCode: request.statusCode
            });
          },
          { urls: ['http://127.0.0.1/*'], types: ['main_frame'] }
        );

        chrome.webRequest.onCompleted.addListener(
          function (request) {
            var headers = {};
            (request.responseHeaders || []).forEach(function (h) {
              if (h && h.name) { headers[String(h.name).toLowerCase()] = String(h.value || ''); }
            });
            state.onCompleted.push({
              url: request.url,
              tabId: request.tabId,
              type: request.type,
              statusCode: request.statusCode,
              headerCount: (request.responseHeaders || []).length,
              headers: headers
            });
            // Header-derived detection: the half of a technology profiler
            // that only webRequest can supply.
            var powered = headers['\(Self.mainFrameHeaderName.lowercased())'];
            if (powered) {
              record(hostnameOf(request.url), request.tabId, ['header:' + powered]);
            }
          },
          { urls: ['http://127.0.0.1/*'], types: ['main_frame'] },
          ['responseHeaders']
        );

        chrome.webRequest.onCompleted.addListener(
          function (request) {
            state.onCompletedScript.push({ url: request.url, tabId: request.tabId, type: request.type });
          },
          { urls: ['http://127.0.0.1/*'], types: ['script'] }
        );

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          try {
            var func = message && message.func;
            if (func === 'onContentLoad') {
              var payload = message.args[0] || {};
              var tabId = sender && sender.tab ? sender.tab.id : null;
              var names = [];
              if (payload.meta && payload.meta.generator) { names.push('meta:' + payload.meta.generator); }
              (payload.scriptSrc || []).forEach(function (src) {
                if (src.indexOf('jquery') !== -1) { names.push('script:jQuery'); }
              });
              (payload.js || []).forEach(function (entry) {
                names.push('window:' + entry.chain + '=' + entry.value);
              });
              state.contentLoads += 1;
              record(hostnameOf(payload.url), tabId, names);
              sendResponse(JSON.stringify({ ok: true, tabId: tabId, recorded: names }));
              return true;
            }
            if (func === 'getReport') { sendResponse(JSON.stringify(state)); return true; }
            if (func === 'getDetections') {
              sendResponse(JSON.stringify(state.detections[message.args[0]] || []));
              return true;
            }
            // Wappalyzer's Driver.getDetections: the worker resolves which
            // tab the popup is about via this exact query.
            if (func === 'getActiveTabDetections') {
              chrome.tabs.query({ active: true, currentWindow: true }, function (tabs) {
                if (chrome.runtime.lastError) {
                  sendResponse(JSON.stringify({ error: 'query: ' + chrome.runtime.lastError.message }));
                  return;
                }
                if (!tabs || !tabs.length) {
                  sendResponse(JSON.stringify({ error: 'no active tab found' }));
                  return;
                }
                var tab = tabs[0];
                sendResponse(JSON.stringify({
                  tabId: tab.id,
                  windowId: tab.windowId,
                  url: tab.url || null,
                  detections: state.tabDetections[tab.id] || []
                }));
              });
              return true;
            }
            sendResponse(JSON.stringify({ error: 'unknown func: ' + String(func) }));
          } catch (error) {
            state.errors.push(String(error));
            sendResponse(JSON.stringify({ error: String(error) }));
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        // Runs in the page's own main world; an isolated-world content
        // script cannot see window.jQuery, which is why real profilers inject.
        let injected = """
        /* \(Self.injectedMarker) */
        (function () {
          addEventListener('message', function (event) {
            var data = event.data;
            if (!data || !data.orbitTest || !data.orbitTest.chains) { return; }
            var results = [];
            data.orbitTest.chains.forEach(function (chain) {
              var value = chain.split('.').reduce(function (carry, key) {
                return carry && carry instanceof Object &&
                  Object.prototype.hasOwnProperty.call(carry, key) ? carry[key] : '__UNDEFINED__';
              }, window);
              if (value !== '__UNDEFINED__') {
                results.push({
                  chain: chain,
                  value: (typeof value === 'string' || typeof value === 'number') ? value : true
                });
              }
            });
            postMessage({ orbitTest: { js: results } });
          }, { once: true });
        })();
        """
        try injected.write(to: directory.appendingPathComponent("injected.js"), atomically: true, encoding: .utf8)

        // Mirrors Wappalyzer's inject()/driver() shape; onerror makes a
        // blocked resource fail loudly instead of hanging like the real one.
        let content = """
        function inject(src, id, message) {
          return new Promise(function (resolve, reject) {
            var script = document.createElement('script');
            script.onload = function () {
              var onMessage = function (event) {
                var data = event.data;
                if (!data || !data.orbitTest || !data.orbitTest[id]) { return; }
                window.removeEventListener('message', onMessage);
                script.remove();
                resolve(data.orbitTest[id]);
              };
              window.addEventListener('message', onMessage);
              window.postMessage({ orbitTest: message });
            };
            script.onerror = function () {
              reject(new Error('web_accessible_resource blocked: ' + src));
            };
            script.setAttribute('src', chrome.runtime.getURL(src));
            document.body.appendChild(script);
          });
        }

        function driver(func, args) {
          return new Promise(function (resolve) {
            chrome.runtime.sendMessage({ source: 'content.js', func: func, args: args }, function (response) {
              if (chrome.runtime.lastError) {
                resolve('lastError=' + chrome.runtime.lastError.message);
                return;
              }
              resolve(response);
            });
          });
        }

        var report = { stage: 'start', error: null };

        function collectMeta() {
          var meta = {};
          var nodes = document.querySelectorAll('meta');
          for (var i = 0; i < nodes.length; i++) {
            var key = nodes[i].getAttribute('name');
            if (key) { meta[key.toLowerCase()] = nodes[i].getAttribute('content'); }
          }
          return meta;
        }

        function collectScriptSrc() {
          return Array.prototype.map.call(document.scripts, function (s) { return s.src; })
            .filter(function (src) { return !!src; });
        }

        (async function () {
          report.stage = 'collect';
          var meta = collectMeta();
          var scriptSrc = collectScriptSrc();

          report.stage = 'fetchWebAccessibleResource';
          try {
            var response = await fetch(chrome.runtime.getURL('injected.js'));
            report.fetchStatus = response.status;
            report.fetchBody = (await response.text()).indexOf('\(Self.injectedMarker)') !== -1;
          } catch (error) {
            report.fetchStatus = 'threw';
            report.fetchError = String(error);
          }

          report.stage = 'inject';
          var js = await inject('injected.js', 'js', { chains: ['jQuery.fn.jquery', 'document.title'] });
          report.js = js;
          report.orphanedScripts = document.querySelectorAll('script[src^="chrome-extension://"]').length;

          report.stage = 'sendToWorker';
          report.workerResponse = await driver('onContentLoad', [{
            url: location.href, meta: meta, scriptSrc: scriptSrc, js: js
          }]);

          report.stage = 'done';
        })().catch(function (error) {
          report.stage = 'failed';
          report.error = String(error);
        }).finally(function () {
          document.documentElement.setAttribute('\(Self.reportAttribute)', JSON.stringify(report));
        });
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let popupHTML = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Orbit Test Popup</title></head>
        <body><div id="\(Self.popupResultElementID)">pending</div>
        <div id="\(Self.popupActiveTabResultElementID)">pending</div>
        <script src="popup.js"></script></body></html>
        """
        try popupHTML.write(to: directory.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)

        // Exactly the shape Wappalyzer's popup uses: asks the worker and
        // renders whatever comes back.
        let popupJS = """
        chrome.runtime.sendMessage(
          { source: 'popup.js', func: 'getDetections', args: [window.__orbitHostname || '127.0.0.1'] },
          function (response) {
            var node = document.getElementById('\(Self.popupResultElementID)');
            if (chrome.runtime.lastError) {
              node.textContent = 'lastError=' + chrome.runtime.lastError.message;
              return;
            }
            node.textContent = String(response);
          }
        );

        chrome.runtime.sendMessage(
          { source: 'popup.js', func: 'getActiveTabDetections', args: [] },
          function (response) {
            var node = document.getElementById('\(Self.popupActiveTabResultElementID)');
            if (chrome.runtime.lastError) {
              node.textContent = 'lastError=' + chrome.runtime.lastError.message;
              return;
            }
            node.textContent = String(response);
          }
        );
        """
        try popupJS.write(to: directory.appendingPathComponent("popup.js"), atomically: true, encoding: .utf8)

        return Fixture(directory: directory)
    }

    // MARK: - Helpers

    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(25),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "timed out after \(timeout) waiting for \(waitingFor)"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private struct ContentReport: Decodable {
        let stage: String
        let error: String?
        let js: [JSEntry]?
        let orphanedScripts: Int?
        let workerResponse: String?
        let fetchStatus: FetchStatus?
        let fetchBody: Bool?
        let fetchError: String?

        struct JSEntry: Decodable {
            let chain: String
            let value: Value

            enum Value: Decodable, CustomStringConvertible {
                case string(String)
                case bool(Bool)

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let string = try? container.decode(String.self) {
                        self = .string(string)
                    } else {
                        self = .bool(try container.decode(Bool.self))
                    }
                }

                var description: String {
                    switch self {
                    case let .string(value): return value
                    case let .bool(value): return String(value)
                    }
                }
            }
        }

        enum FetchStatus: Decodable, CustomStringConvertible {
            case code(Int)
            case threw(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let code = try? container.decode(Int.self) {
                    self = .code(code)
                } else {
                    self = .threw(try container.decode(String.self))
                }
            }

            var description: String {
                switch self {
                case let .code(value): return String(value)
                case let .threw(value): return value
                }
            }
        }
    }

    private struct WorkerReport: Decodable {
        let onResponseStarted: [Event]
        let onCompleted: [CompletedEvent]
        let onCompletedScript: [Event]
        let detections: [String: [String]]
        let tabDetections: [String: [String]]
        let contentLoads: Int
        let errors: [String]

        struct Event: Decodable {
            let url: String
            let tabId: Int
            let type: String
            let statusCode: Int?
        }

        struct CompletedEvent: Decodable {
            let url: String
            let tabId: Int
            let type: String
            let statusCode: Int
            let headerCount: Int
            let headers: [String: String]
        }
    }

    private struct ActiveTabAnswer: Decodable {
        let error: String?
        let tabId: Int32?
        let windowId: Int32?
        let url: String?
        let detections: [String]?
    }

    /// Blocks until the background worker answers, proving its webRequest
    /// listeners (registered above onMessage) exist. Navigating before this
    /// races worker startup and silently drops the event as if unwired.
    private func makeReadyWorkerPage(
        engine: ChromiumEngine, extensionID: String
    ) async throws -> ChromiumWebContents {
        let page = try await LiveChromiumEngineHost.makeContents(engine: engine)
        page.load(URL(string: "chrome-extension://\(extensionID)/popup.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(page)
        try await Self.pollUntil("the background service worker to finish starting up") {
            _ = try await page.evaluateJavaScript("""
            (function () {
              window.__orbitReady = null;
              chrome.runtime.sendMessage({ source: 'test', func: 'getReport', args: [] }, function (response) {
                window.__orbitReady = chrome.runtime.lastError ? 'error' : 'ready';
              });
              return 'asked';
            })()
            """)
            try await Task.sleep(for: .milliseconds(250))
            return try await page.evaluateJavaScript("String(window.__orbitReady)") as? String == "ready"
        }
        return page
    }

    /// Runs the fixture on a real registered tab (not a bare WebContents),
    /// which is what makes tab ids in webRequest events meaningful.
    private func runAnalysis(
        named name: String,
        body: @escaping (ChromiumWebContents, String, LiveHTTPTestServer, Int32) async throws -> Void = { _, _, _, _ in }
    ) throws -> (ContentReport, WorkerReport, Int32) {
        try LiveChromiumEngineHost.runLive(timeout: 180) { () -> (ContentReport, WorkerReport, Int32) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture(named: name)
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            // Before any navigation: the worker must be up, or its webRequest
            // listeners do not exist yet to receive the navigation.
            let workerPage = try await self.makeReadyWorkerPage(engine: engine, extensionID: loaded.id)
            defer { workerPage.close() }

            // A real Orbit tab, so OrbitTabRegistry knows about it and
            // GetTabAndWindowIdForWebContents has a real id to hand back.
            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            let registeredTabID = try XCTUnwrap(
                OrbitChromiumTabsBridge.shared.existingTabID(for: tabID),
                "opening a tab must register it with OrbitTabRegistry"
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.pollUntil("the content script to finish its analysis and write its report") {
                try await contents.evaluateJavaScript(
                    "document.documentElement.getAttribute('\(Self.reportAttribute)')"
                ) != nil
            }

            let rawReportValue = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(Self.reportAttribute)')"
            ) as? String
            let rawReport = try XCTUnwrap(rawReportValue, "the content script never reported")
            let contentReport = try JSONDecoder().decode(ContentReport.self, from: Data(rawReport.utf8))

            try await body(contents, loaded.id, server, registeredTabID)

            // Ask the worker for everything it saw.
            _ = try await workerPage.evaluateJavaScript("""
            (function () {
              window.__orbitReport = null;
              chrome.runtime.sendMessage({ source: 'test', func: 'getReport', args: [] }, function (response) {
                window.__orbitReport = chrome.runtime.lastError
                  ? JSON.stringify({ lastError: chrome.runtime.lastError.message })
                  : String(response);
              });
              return 'started';
            })()
            """)
            try await Self.pollUntil("the background service worker to answer getReport") {
                try await workerPage.evaluateJavaScript("window.__orbitReport !== null") as? Bool == true
            }
            let rawWorkerValue = try await workerPage.evaluateJavaScript("window.__orbitReport") as? String
            let rawWorker = try XCTUnwrap(
                rawWorkerValue, "the background service worker never answered getReport"
            )
            let workerReport = try JSONDecoder().decode(WorkerReport.self, from: Data(rawWorker.utf8))

            return (contentReport, workerReport, registeredTabID)
        }
    }

    // MARK: - 1. The content script's full path

    func testContentScriptOnARealPageReportsPageDerivedDataThroughTheFullExtensionPath() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (content, worker, _) = try runAnalysis(named: "Orbit Real Page Analysis Test")

        XCTAssertNil(content.error, "the content script threw before completing its analysis")
        XCTAssertEqual(
            content.stage, "done",
            "the content script never reached the end of the path a real extension uses -- it stopped at '\(content.stage)'"
        )
        XCTAssertEqual(worker.contentLoads, 1, "the background service worker never received the content script's analysis")
        XCTAssertTrue(worker.errors.isEmpty, "the background service worker recorded errors: \(worker.errors)")

        let detections = worker.detections["127.0.0.1"] ?? []
        XCTAssertTrue(
            detections.contains("meta:Orbit Test CMS 4.2.1"),
            "the worker never learned the page's generator meta tag; it has \(detections)"
        )
        XCTAssertTrue(
            detections.contains("script:jQuery"),
            "the worker never learned the page's script subresources; it has \(detections)"
        )
    }

    // MARK: - 2. A web_accessible_resource genuinely fetched from a real page

    func testContentScriptFetchesAWebAccessibleResourceFromARealPage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (content, _, _) = try runAnalysis(named: "Orbit Web Accessible Resource Test")

        XCTAssertEqual(
            content.fetchStatus?.description, "200",
            """
            a content script could not fetch its own web_accessible_resource from a real page \
            (\(content.fetchError ?? "no error text")) -- \
            OrbitExtensionsBrowserClient::AllowCrossRendererResourceLoad returning false \
            unconditionally blocks every one of them
            """
        )
        XCTAssertEqual(content.fetchBody, true, "the web_accessible_resource was served but its body was not the extension's own file")
    }

    // MARK: - 3. That resource reading page globals and round-tripping back
    // The exact mechanism Wappalyzer wedges on: a blocked resource stops the
    // content script forever, since only its onload resolves the promise.

    func testInjectedWebAccessibleScriptReadsPageWorldGlobalsAndRoundTripsThemBack() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (content, worker, _) = try runAnalysis(named: "Orbit Injected Script Test")

        let entries = try XCTUnwrap(content.js, "the injected web_accessible_resource never answered the content script")
        let byChain = Dictionary(uniqueKeysWithValues: entries.map { ($0.chain, $0.value.description) })
        XCTAssertEqual(
            byChain["jQuery.fn.jquery"], "3.7.1",
            """
            the injected script did not read window.jQuery out of the page's own main world; it saw \(byChain). \
            An isolated-world content script cannot see that global at all, which is why real \
            technology profilers inject a web_accessible_resource to read it
            """
        )
        XCTAssertEqual(
            content.orphanedScripts, 0,
            """
            the injected <script src="chrome-extension://..."> was still in the DOM after the round trip. \
            A real extension removes it only once its onload has fired and its message has come back, \
            so a leftover tag is the signature of a content script wedged on a blocked resource
            """
        )
        XCTAssertTrue(
            (worker.detections["127.0.0.1"] ?? []).contains("window:jQuery.fn.jquery=3.7.1"),
            "the page-world global never reached the background worker; it has \(worker.detections["127.0.0.1"] ?? [])"
        )
    }

    // MARK: - 4. chrome.webRequest receiving genuine events

    func testWebRequestListenersReceiveGenuineEventsIncludingResponseHeaders() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (_, worker, _) = try runAnalysis(named: "Orbit WebRequest Delivery Test")

        XCTAssertFalse(
            worker.onResponseStarted.isEmpty,
            """
            chrome.webRequest.onResponseStarted never fired for a real main-frame navigation. \
            Registering a listener is not enough: OrbitContentBrowserClient::WillCreateURLLoaderFactory \
            must call WebRequestAPI::MaybeProxyURLLoaderFactory, or no webRequest event can ever be delivered
            """
        )
        XCTAssertEqual(worker.onResponseStarted.first?.statusCode, 200)
        XCTAssertEqual(worker.onResponseStarted.first?.type, "main_frame")

        let completed = try XCTUnwrap(
            worker.onCompleted.first,
            "chrome.webRequest.onCompleted never fired for the main-frame navigation"
        )
        XCTAssertEqual(completed.statusCode, 200)
        XCTAssertGreaterThan(
            completed.headerCount, 0,
            "onCompleted fired but carried no response headers, despite being registered with ['responseHeaders']"
        )
        XCTAssertEqual(
            completed.headers[Self.mainFrameHeaderName.lowercased()], Self.mainFrameHeaderValue,
            "the response header the server actually sent did not reach the extension; it saw \(completed.headers)"
        )

        XCTAssertFalse(
            worker.onCompletedScript.isEmpty,
            "chrome.webRequest.onCompleted never fired for the page's script subresource -- only the navigation was proxied"
        )
        XCTAssertTrue(
            worker.onCompletedScript.contains { $0.url.contains("/vendor/jquery.js") },
            "the script subresource the page really loaded produced no webRequest event; saw \(worker.onCompletedScript.map(\.url))"
        )

        XCTAssertTrue(
            (worker.detections["127.0.0.1"] ?? []).contains("header:\(Self.mainFrameHeaderValue)"),
            """
            no technology was derived from response headers. Header-derived detection is the half of a \
            technology profiler that only chrome.webRequest can supply, and it is exactly what a real \
            extension loses when webRequest is registered but never proxied
            """
        )
    }

    // MARK: - 5. Those events carrying the real Orbit tab id

    func testWebRequestEventsCarryTheRealOrbitTabIdRatherThanMinusOne() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (_, worker, registeredTabID) = try runAnalysis(named: "Orbit WebRequest Tab Id Test")

        let event = try XCTUnwrap(
            worker.onResponseStarted.first,
            "chrome.webRequest.onResponseStarted never fired, so there was no tab id to check"
        )
        XCTAssertEqual(
            event.tabId, Int(registeredTabID),
            """
            a webRequest event reported tabId \(event.tabId) for a navigation in a genuinely registered \
            Orbit tab (\(registeredTabID)). ExtensionsBrowserClient::GetTabAndWindowIdForWebContents \
            defaults to -1, and real extensions drop any event whose tabId is negative -- Wappalyzer's \
            own onResponseStarted returns immediately on `request.tabId < 0`
            """
        )
        XCTAssertFalse(
            worker.tabDetections.isEmpty,
            "no detection was ever stored against a tab id, so no popup could look one up by tab"
        )
    }

    // MARK: - 6. The popup asking its worker for the page-derived answer

    func testExtensionPopupAsksItsBackgroundWorkerForPageDerivedDataAndGetsIt() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let popupText = try LiveChromiumEngineHost.runLive(timeout: 180) { () -> String in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture(named: "Orbit Popup Data Test")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let readyPage = try await self.makeReadyWorkerPage(engine: engine, extensionID: loaded.id)
            readyPage.close()

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.pollUntil("the content script to finish its analysis") {
                try await contents.evaluateJavaScript(
                    "document.documentElement.getAttribute('\(Self.reportAttribute)')"
                ) != nil
            }

            // The popup is a real extension page, loaded from its real
            // chrome-extension:// URL, running its own popup.js.
            let popup = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { popup.close() }
            popup.load(URL(string: "chrome-extension://\(loaded.id)/popup.html")!)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(popup)

            try await Self.pollUntil("the popup to render the worker's answer") {
                let text = try await popup.evaluateJavaScript(
                    "document.getElementById('\(Self.popupResultElementID)').textContent"
                ) as? String
                return text != nil && text != "pending"
            }

            let renderedValue = try await popup.evaluateJavaScript(
                "document.getElementById('\(Self.popupResultElementID)').textContent"
            ) as? String
            return try XCTUnwrap(renderedValue, "the popup never rendered anything")
        }

        XCTAssertFalse(
            popupText.hasPrefix("lastError="),
            "the popup could not reach its own background service worker: \(popupText)"
        )
        XCTAssertTrue(
            popupText.contains("meta:Orbit Test CMS 4.2.1"),
            """
            the popup asked its worker for the current page's technologies and got \(popupText). \
            This is the exact shape Wappalyzer's popup uses, and "No technologies detected." is what \
            it renders when this answer comes back empty
            """
        )
        XCTAssertTrue(
            popupText.contains("window:jQuery.fn.jquery=3.7.1"),
            "the popup's answer carried no page-world data, so the injected resource never contributed: \(popupText)"
        )
        XCTAssertTrue(
            popupText.contains("header:\(Self.mainFrameHeaderValue)"),
            "the popup's answer carried nothing derived from response headers, so webRequest contributed nothing: \(popupText)"
        )
    }

    // MARK: - 7. The hosted popup asking its worker about the ACTIVE TAB

    // Test 6 passes even with this defect since it names its hostname
    // literally; a real popup resolves the active tab while a popover holds key status.
    func testHostedPopupResolvesTheActiveTabThroughItsWorkerWhileAPopoverHoldsKeyStatus() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let (answer, expectedTabID, expectedWindowID) = try LiveChromiumEngineHost.runLive(timeout: 180) {
            () -> (ActiveTabAnswer, Int32, Int32) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture(named: "Orbit Active Tab Popup Test")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture.directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let readyPage = try await self.makeReadyWorkerPage(engine: engine, extensionID: loaded.id)
            readyPage.close()

            // The window WINDOW_ID_CURRENT resolves to. The XCTest host has
            // no OrbitWindowController to register it automatically.
            let bridge = OrbitChromiumTabsBridge.shared
            if !bridge.isWindowRegistered(env) {
                bridge.windowCreated(owner: env, focused: true)
            }
            bridge.windowFocusChanged(owner: env)
            let windowID = bridge._test_windowID(for: env)

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            let registeredTabID = try XCTUnwrap(
                bridge.existingTabID(for: tabID), "opening a tab must register it with OrbitTabRegistry"
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            env.activateTab(tabID)

            try await Self.pollUntil("the content script to finish its analysis") {
                try await contents.evaluateJavaScript(
                    "document.documentElement.getAttribute('\(Self.reportAttribute)')"
                ) != nil
            }

            // Clicking a toolbar icon: the popover takes key status and the
            // window reports focus lost, but the active tab must still resolve.
            bridge.windowFocusChanged(owner: nil)

            let popupURL = try XCTUnwrap(
                ExtensionActionPopupSupport.actionPopupURL(
                    extensionID: loaded.id,
                    isEnabled: true,
                    hasToolbarAction: true,
                    manifestKey: nil,
                    actionPopupPath: "popup.html",
                    sessionIsPersistent: engine.defaultSession.isPersistent,
                    directory: fixture.directory,
                    idIsEngineAssigned: true
                ),
                "the production popup URL builder refused this fixture"
            )

            // The real hosting path, not a bare WebContents: created and
            // sized exactly as SiteControlPopoverView creates it.
            let model = ExtensionActionPopupModel(engine: engine, session: contents.session, url: popupURL)
            model.start()
            defer { model.teardown() }
            XCTAssertNil(model.loadFailure, "the hosted popup failed to start")
            let popup = try XCTUnwrap(
                model.contents as? ChromiumWebContents, "ExtensionActionPopupModel produced no WebContents"
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(popup)

            try await Self.pollUntil("the hosted popup to render its worker's active-tab answer") {
                let text = try await popup.evaluateJavaScript(
                    "document.getElementById('\(Self.popupActiveTabResultElementID)').textContent"
                ) as? String
                return text != nil && text != "pending"
            }
            let renderedValue = try await popup.evaluateJavaScript(
                "document.getElementById('\(Self.popupActiveTabResultElementID)').textContent"
            ) as? String
            let rendered = try XCTUnwrap(renderedValue, "the hosted popup never rendered anything")
            XCTAssertFalse(
                rendered.hasPrefix("lastError="),
                "the hosted popup could not reach its own background service worker: \(rendered)"
            )
            let decoded = try JSONDecoder().decode(ActiveTabAnswer.self, from: Data(rendered.utf8))
            return (decoded, registeredTabID, windowID)
        }

        XCTAssertNil(
            answer.error,
            """
            the worker could not resolve the active tab for its own popup: \(answer.error ?? ""). \
            This is what leaves a technology profiler's popup rendering "No technologies detected." \
            while its toolbar badge, which is keyed by the tab id the content script's own sender \
            carries, still shows the right count
            """
        )
        XCTAssertEqual(answer.tabId, expectedTabID, "the active tab the worker resolved is not the tab Orbit has open")
        XCTAssertEqual(answer.windowId, expectedWindowID, "the active tab was resolved in the wrong window")
        XCTAssertTrue(
            answer.url?.hasPrefix("http://127.0.0.1") == true,
            """
            the resolved tab carried no usable url (\(answer.url ?? "nil")), so a popup keying its \
            lookup on the page under analysis has nothing to key on
            """
        )
        let detections = answer.detections ?? []
        XCTAssertTrue(
            detections.contains("meta:Orbit Test CMS 4.2.1"),
            "the active tab's detections carried nothing the content script derived: \(detections)"
        )
        XCTAssertTrue(
            detections.contains("header:\(Self.mainFrameHeaderValue)"),
            "the active tab's detections carried nothing webRequest derived: \(detections)"
        )
    }
}
