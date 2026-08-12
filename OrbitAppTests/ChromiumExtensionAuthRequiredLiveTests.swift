//  With content::'s default a 401 resolved with no credentials and
//  onAuthRequired was dead code; the negative control (no extension) is what makes the positive result mean anything.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionAuthRequiredLiveTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    private static let username = "orbit-user"
    private static let password = "orbit-pass"
    private static let protectedMarker = "orbit-protected-body"

    private struct AuthEvent: Decodable {
        let url: String
        let realm: String
        let isProxy: Bool
        let statusCode: Int
    }

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Subresource challenge

    func testExtensionAnswersASubresourceAuthChallenge() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let outcome = try LiveChromiumEngineHost.runLive(timeout: 180) { () -> Outcome in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture()
            let server = try self.makeServer(realm: "OrbitSubresourceRealm")
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let workerPage = try await self.makeReadyWorkerPage(engine: engine, extensionID: loaded.id)
            defer { workerPage.close() }

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let fetched = try await self.fetchProtected(from: contents)
            try await Task.sleep(for: .seconds(1))

            return Outcome(
                fetchResult: fetched,
                authEvents: try await self.readAuthEvents(from: workerPage),
                authorizationHeaders: server.requestLog.all
                    .filter { $0.path == "/protected" }
                    .map { $0.headers["authorization"] ?? "" },
                protectedURL: server.baseURL.appendingPathComponent("protected").absoluteString
            )
        }

        XCTAssertNil(
            outcome.fetchResult.error,
            "the protected fetch failed outright: \(outcome.fetchResult)"
        )
        XCTAssertEqual(
            outcome.fetchResult.status, 200,
            "the extension's credentials were not honoured; the protected fetch returned \(outcome.fetchResult)"
        )
        XCTAssertTrue(
            outcome.fetchResult.body.contains(Self.protectedMarker),
            "the protected content did not come back; the protected fetch returned \(outcome.fetchResult)"
        )
        XCTAssertEqual(
            outcome.authEvents.count, 1,
            "onAuthRequired must fire exactly once for one challenge; got \(outcome.authEvents)"
        )
        let event = try XCTUnwrap(outcome.authEvents.first)
        XCTAssertEqual(event.url, outcome.protectedURL)
        XCTAssertEqual(event.realm, "OrbitSubresourceRealm")
        XCTAssertEqual(event.statusCode, 401)
        XCTAssertFalse(event.isProxy)
        XCTAssertEqual(
            outcome.authorizationHeaders.count, 2,
            "expected an unauthenticated attempt then an authenticated retry; got \(outcome.authorizationHeaders)"
        )
        XCTAssertEqual(outcome.authorizationHeaders.first, "")
        XCTAssertEqual(
            outcome.authorizationHeaders.last,
            "Basic " + Data("\(Self.username):\(Self.password)".utf8).base64EncodedString(),
            "the retry did not carry the credentials the extension supplied"
        )
    }

    /// Same server, same 401, no extension: this must stay unauthorised, or
    /// a browser silently retrying with cached credentials would pass the test above.
    func testSubresourceAuthChallengeIsNotAnsweredWithoutAnExtension() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let fetched = try LiveChromiumEngineHost.runLive(timeout: 120) { () -> FetchResult in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let server = try self.makeServer(realm: "OrbitControlRealm")
            defer { server.stop() }

            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            return try await self.fetchProtected(from: contents)
        }

        XCTAssertEqual(
            fetched.status, 401,
            "with no extension to answer the challenge the resource must stay unauthorised; got \(fetched)"
        )
        XCTAssertFalse(
            fetched.body.contains(Self.protectedMarker),
            "the protected content came back with nobody to answer the challenge; got \(fetched)"
        )
    }

    // MARK: - Main-frame navigation challenge

    func testExtensionAnswersAMainFrameNavigationAuthChallenge() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let body = try LiveChromiumEngineHost.runLive(timeout: 180) { () -> String? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            ChromiumTabsSetup.installHandlerOnce
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let fixture = try self.writeFixture()
            let server = try self.makeServer(realm: "OrbitNavigationRealm")
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let workerPage = try await self.makeReadyWorkerPage(engine: engine, extensionID: loaded.id)
            defer { workerPage.close() }

            let tabID = env.openTab(
                url: server.baseURL.appendingPathComponent("protected"),
                in: spaceID
            )
            defer { env.closeTab(tabID) }
            let contents = try XCTUnwrap(env.webContents[tabID] as? ChromiumWebContents)
            try? await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .seconds(2))

            let value = try? await contents.evaluateJavaScript(
                "document.body ? document.body.innerText : ''"
            )
            return value as? String
        }

        XCTAssertEqual(
            body?.contains(Self.protectedMarker), true,
            "a main-frame navigation into a 401 was not completed with the extension's credentials; body was \(body ?? "nil")"
        )
    }

    // MARK: - Support

    private struct Outcome {
        let fetchResult: FetchResult
        let authEvents: [AuthEvent]
        let authorizationHeaders: [String]
        let protectedURL: String
    }

    /// Status and body kept apart on purpose: a single "status:body" string
    /// couples the test to the fixture's exact serialisation.
    private struct FetchResult: Decodable, CustomStringConvertible {
        let status: Int
        let body: String
        let error: String?

        var description: String {
            if let error { return "threw \(error)" }
            return "status \(status), body \(body.isEmpty ? "<empty>" : body)"
        }
    }

    private func fetchProtected(from contents: ChromiumWebContents) async throws -> FetchResult {
        _ = try await contents.evaluateJavaScript("""
        (function () {
          window.__orbitProtected = null;
          fetch('/protected').then(function (response) {
            return response.text().then(function (text) {
              window.__orbitProtected = JSON.stringify({
                status: response.status,
                body: text.trim(),
                error: null
              });
            });
          }).catch(function (error) {
            window.__orbitProtected = JSON.stringify({
              status: 0, body: '', error: String(error)
            });
          });
          return 'fetching';
        })()
        """)
        try await Self.pollUntil("the protected fetch to settle") {
            try await contents.evaluateJavaScript("window.__orbitProtected !== null") as? Bool == true
        }
        let rawValue = try await contents.evaluateJavaScript("window.__orbitProtected") as? String
        let raw = try XCTUnwrap(rawValue, "the protected fetch never reported a result")
        return try JSONDecoder().decode(FetchResult.self, from: Data(raw.utf8))
    }

    private func makeServer(realm: String) throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(
            routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><h1>orbit-auth-host</h1></body></html>"
                )
            ],
            authenticatedRoutes: [
                "/protected": LiveHTTPTestServer.AuthenticatedRoute(
                    realm: realm,
                    username: Self.username,
                    password: Self.password,
                    route: LiveHTTPTestServer.Route(
                        contentType: "text/html",
                        body: "<html><body>\(Self.protectedMarker)</body></html>"
                    )
                )
            ]
        )
    }

    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-AuthRequired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Orbit onAuthRequired Fixture",
          "version": "1.0",
          "permissions": ["webRequest", "webRequestAuthProvider"],
          "host_permissions": ["http://127.0.0.1/*"],
          "background": { "service_worker": "background.js" },
          "action": { "default_popup": "popup.html" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let background = """
        var challenges = [];
        chrome.webRequest.onAuthRequired.addListener(
          function (details, callback) {
            challenges.push({
              url: String(details.url),
              realm: String(details.realm || ''),
              isProxy: !!details.isProxy,
              statusCode: Number(details.statusCode || 0)
            });
            callback({
              authCredentials: { username: '\(Self.username)', password: '\(Self.password)' }
            });
          },
          { urls: ['<all_urls>'] },
          ['asyncBlocking']
        );

        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message && message.func === 'getChallenges') {
            sendResponse(JSON.stringify(challenges));
            return true;
          }
          sendResponse('pong');
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        try "<html><head><script src=\"popup.js\"></script></head><body>orbit</body></html>"
            .write(to: directory.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try "window.__orbitPopupReady = true;"
            .write(to: directory.appendingPathComponent("popup.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func readAuthEvents(from workerPage: ChromiumWebContents) async throws -> [AuthEvent] {
        _ = try await workerPage.evaluateJavaScript("""
        (function () {
          window.__orbitChallenges = null;
          chrome.runtime.sendMessage({ func: 'getChallenges' }, function (response) {
            window.__orbitChallenges = chrome.runtime.lastError ? '[]' : String(response);
          });
          return 'asked';
        })()
        """)
        try await Self.pollUntil("the background service worker to return its auth challenges") {
            try await workerPage.evaluateJavaScript("window.__orbitChallenges !== null") as? Bool == true
        }
        let rawValue = try await workerPage.evaluateJavaScript("window.__orbitChallenges") as? String
        let raw = try XCTUnwrap(rawValue, "the background service worker never answered getChallenges")
        return try JSONDecoder().decode([AuthEvent].self, from: Data(raw.utf8))
    }

    /// The worker registers onAuthRequired above its onMessage listener, so an
    /// answer here proves the auth listener is installed before any request.
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
              chrome.runtime.sendMessage({ func: 'ping' }, function (response) {
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

    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(30),
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
