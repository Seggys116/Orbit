//  Until Orbit registered ExtensionNavigationThrottle, any web page could
//  navigate to chrome-extension://<any id>/<any path>. Negative controls are the point of this file.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionNavigationThrottleLiveTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    /// The resource declared web-accessible to the test server's origin.
    private static let allowedPage = "accessible.html"
    /// Declared web-accessible, but only to an origin the test page is not.
    private static let wrongOriginPage = "other-origin-only.html"
    /// Not listed in web_accessible_resources at all.
    private static let forbiddenPage = "forbidden.html"

    private static let loadedMessagePrefix = "orbit-war-loaded:"
    private static let pageMarkerAttribute = "data-orbit-war-page"

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Iframes

    func testIframeReachesOnlyTheResourceDeclaredWebAccessibleToThisOrigin() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let messages = try LiveChromiumEngineHost.runLive(timeout: 180) { () -> [String] in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture()
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            (function () {
              window.__orbitWarMessages = [];
              window.addEventListener('message', function (event) {
                window.__orbitWarMessages.push(String(event.data));
              });
              var names = ['\(Self.allowedPage)', '\(Self.wrongOriginPage)', '\(Self.forbiddenPage)'];
              names.forEach(function (name) {
                var frame = document.createElement('iframe');
                frame.src = 'chrome-extension://\(loaded.id)/' + name;
                document.body.appendChild(frame);
              });
              return 'started';
            })()
            """)

            // The allowed frame arriving makes the two absences meaningful:
            // it proves the extension is live and the postMessage channel works.
            try await Self.pollUntil("the web-accessible iframe to report in") {
                let raw = try await contents.evaluateJavaScript(
                    "JSON.stringify(window.__orbitWarMessages)"
                ) as? String ?? "[]"
                return raw.contains("\(Self.loadedMessagePrefix)/\(Self.allowedPage)")
            }

            // Settle: a blocked frame that was merely slow would show up here.
            try await Task.sleep(for: .seconds(3))

            let raw = try await contents.evaluateJavaScript(
                "JSON.stringify(window.__orbitWarMessages)"
            ) as? String ?? "[]"
            return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
        }

        XCTAssertTrue(
            messages.contains("\(Self.loadedMessagePrefix)/\(Self.allowedPage)"),
            "a resource declared web-accessible to this origin must be reachable by iframe; got \(messages)"
        )
        XCTAssertFalse(
            messages.contains("\(Self.loadedMessagePrefix)/\(Self.wrongOriginPage)"),
            "a resource web-accessible only to another origin must not be reachable by iframe; got \(messages)"
        )
        XCTAssertFalse(
            messages.contains("\(Self.loadedMessagePrefix)/\(Self.forbiddenPage)"),
            "a resource absent from web_accessible_resources must not be reachable by iframe; got \(messages)"
        )
    }

    // MARK: - Top-level navigation

    func testTopLevelNavigationFromAWebPageReachesOnlyTheDeclaredResource() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let outcome = try LiveChromiumEngineHost.runLive(timeout: 180) { () -> TopLevelOutcome in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture()
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            @MainActor func navigateFromPage(to resource: String) async throws -> String? {
                let tabID = env.openTab(url: server.baseURL, in: spaceID)
                defer { env.closeTab(tabID) }
                let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
                try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
                _ = try? await contents.evaluateJavaScript(
                    "location.href = 'chrome-extension://\(loaded.id)/\(resource)'; 'navigating'"
                )
                try await Task.sleep(for: .seconds(3))
                try? await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
                // A blocked navigation commits an error document, where
                // evaluation may fail outright -- that's a "not reachable" answer, not a test failure.
                let value = try? await contents.evaluateJavaScript("""
                (function () {
                  var marker = document.documentElement.getAttribute('\(Self.pageMarkerAttribute)');
                  if (marker) { return 'page:' + marker; }
                  return 'body:' + (document.body ? document.body.innerText : '').slice(0, 200);
                })()
                """)
                return value as? String
            }

            return TopLevelOutcome(
                allowed: try await navigateFromPage(to: Self.allowedPage),
                forbidden: try await navigateFromPage(to: Self.forbiddenPage),
                manifest: try await navigateFromPage(to: "manifest.json")
            )
        }

        XCTAssertEqual(
            outcome.allowed, "page:/\(Self.allowedPage)",
            "a declared web-accessible page must be reachable by top-level navigation"
        )
        XCTAssertNotEqual(
            outcome.forbidden, "page:/\(Self.forbiddenPage)",
            "a non-web-accessible extension page must not commit from a web-page-initiated navigation"
        )
        // The exact exfiltration vector from the audit: manifest.json is never
        // web-accessible, and reading it fingerprints the installed extension.
        XCTAssertFalse(
            (outcome.manifest ?? "").contains("manifest_version"),
            "manifest.json must not be readable by a web-page-initiated navigation; got \(outcome.manifest ?? "nil")"
        )
    }

    // MARK: - Fixture

    private struct TopLevelOutcome {
        let allowed: String?
        let forbidden: String?
        let manifest: String?
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html",
                body: "<html><body><h1>orbit-war-host</h1></body></html>"
            )
        ])
    }

    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-WARThrottle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Orbit WAR Navigation Fixture",
          "version": "1.0",
          "background": { "service_worker": "background.js" },
          "web_accessible_resources": [
            { "resources": ["\(Self.allowedPage)"], "matches": ["http://127.0.0.1/*"] },
            { "resources": ["\(Self.wrongOriginPage)"], "matches": ["https://orbit-not-this-origin.example/*"] }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try "self.addEventListener('install', function () {});"
            .write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        // MV3 forbids inline script on an extension page, so the marker and
        // postMessage live in a same-origin subresource, not itself subject to a WAR check.
        let frameScript = """
        document.documentElement.setAttribute('\(Self.pageMarkerAttribute)', location.pathname);
        if (window.parent !== window) {
          window.parent.postMessage('\(Self.loadedMessagePrefix)' + location.pathname, '*');
        }
        """
        try frameScript.write(to: directory.appendingPathComponent("frame.js"), atomically: true, encoding: .utf8)

        for page in [Self.allowedPage, Self.wrongOriginPage, Self.forbiddenPage] {
            let html = "<html><head><script src=\"frame.js\"></script></head><body>\(page)</body></html>"
            try html.write(to: directory.appendingPathComponent(page), atomically: true, encoding: .utf8)
        }

        return directory
    }

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
}
