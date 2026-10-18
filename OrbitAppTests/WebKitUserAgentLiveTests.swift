//  Orbit identifies as Safari/WebKit by default and as Chrome only on the Chrome Web Store.
//  User-Agent and client-hint headers are read off the real socket.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitUserAgentLiveTests: XCTestCase {

    private static let html = "<html><body>probe</body></html>"

    private struct Reading {
        let script: String
        let request: LiveHTTPTestServer.RecordedRequest?
    }

    // MARK: - The default identity

    func testDefaultUserAgentIsSafariAndMatchesTheWire() throws {
        let (reading, vendor, platform) = try WebKitLiveEngineHost.runLive { () -> (Reading, String, String) in
            let server = try LiveHTTPTestServer(routes: ["/ua": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.html)])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("ua"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            let script = try await contents.evaluateJavaScript("navigator.userAgent") as? String ?? ""
            let vendor = try await contents.evaluateJavaScript("navigator.vendor") as? String ?? ""
            let platform = try await contents.evaluateJavaScript("navigator.platform") as? String ?? ""
            return (Reading(script: script, request: server.requestLog.first(path: "/ua")), vendor, platform)
        }

        let request = try XCTUnwrap(reading.request, "the local server never saw the navigation")
        XCTAssertFalse(reading.script.isEmpty, "navigator.userAgent is empty")
        XCTAssertEqual(request.headers["user-agent"], reading.script, "the User-Agent on the wire disagrees with the one JavaScript sees")
        XCTAssertEqual(reading.script, WebKitProduct.userAgent, "the engine's User-Agent must be the one WebKitProduct publishes")
        XCTAssertTrue(reading.script.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"), reading.script)
        XCTAssertFalse(reading.script.contains("Chrome/"), "the default identity must not claim to be Chrome: \(reading.script)")
        XCTAssertFalse(reading.script.contains("Orbit"), reading.script)
        if let version = WebKitProduct.safariVersion {
            XCTAssertTrue(reading.script.hasSuffix(" Version/\(version) Safari/605.1.15"), reading.script)
        }
        XCTAssertEqual(vendor, "Apple Computer, Inc.", "navigator.vendor is not WebKit's")
        XCTAssertEqual(platform, "MacIntel", "navigator.platform is not Safari's")
    }

    func testNoClientHintsOrChromeSurfaceByDefault() throws {
        let (request, surface) = try WebKitLiveEngineHost.runLive { () -> (LiveHTTPTestServer.RecordedRequest?, String) in
            // 127.0.0.1 is a secure context, where userAgentData would be exposed if it existed.
            let server = try LiveHTTPTestServer(routes: ["/hints": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.html)])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("hints"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            let surface = try await contents.evaluateJavaScript(
                """
                JSON.stringify({
                  secure: window.isSecureContext,
                  userAgentData: typeof navigator.userAgentData,
                  chrome: typeof window.chrome,
                  loadTimes: typeof (window.chrome && window.chrome.loadTimes)
                })
                """
            ) as? String ?? "{}"
            return (server.requestLog.first(path: "/hints"), surface)
        }

        let recorded = try XCTUnwrap(request, "the local server never saw the navigation")
        let hintHeaders = recorded.headers.keys.filter { $0.hasPrefix("sec-ch-") }
        XCTAssertTrue(hintHeaders.isEmpty, "WebKit sends no client hints; a Chrome-style header makes a half-Chrome identity: \(hintHeaders)")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(surface.utf8)) as? [String: Any], surface)
        XCTAssertEqual(object["secure"] as? Bool, true, "the probe page was not a secure context")
        XCTAssertEqual(object["userAgentData"] as? String, "undefined", "navigator.userAgentData must not be polyfilled")
        XCTAssertEqual(object["chrome"] as? String, "undefined", "window.chrome must not exist on an ordinary page")
        XCTAssertEqual(object["loadTimes"] as? String, "undefined")
    }

    func testAcceptHeadersOnTheWireMatchWebKit() throws {
        let (recorded, languages) = try WebKitLiveEngineHost.runLive { () -> (LiveHTTPTestServer.RecordedRequest?, [String]) in
            let server = try LiveHTTPTestServer(routes: ["/accept": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.html)])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("accept"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            let json = try await contents.evaluateJavaScript("JSON.stringify(navigator.languages)") as? String ?? "[]"
            let languages = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            return (server.requestLog.first(path: "/accept"), languages)
        }

        let request = try XCTUnwrap(recorded, "the local server never saw the navigation")
        let accept = try XCTUnwrap(request.headers["accept"], "no Accept header")
        XCTAssertTrue(accept.hasPrefix("text/html,application/xhtml+xml,application/xml;q=0.9"), "not the navigation Accept WebKit sends: \(accept)")

        let encoding = try XCTUnwrap(request.headers["accept-encoding"], "no Accept-Encoding header")
        // WebKit's own HTTP navigation on this OS advertises gzip and deflate, not br.
        XCTAssertTrue(encoding.contains("gzip") && encoding.contains("deflate"), "Accept-Encoding is not WebKit's navigation encoding: \(encoding)")

        // WebKit sends the system languages as they are; nothing here fakes en-US.
        let acceptLanguage = try XCTUnwrap(request.headers["accept-language"], "no Accept-Language header")
        let firstTag = acceptLanguage.split(separator: ",").first.map { $0.split(separator: ";")[0].lowercased() } ?? ""
        let systemTag = Locale.preferredLanguages.first?.lowercased() ?? ""
        let primary = { (tag: String) in tag.split(separator: "-").first.map(String.init) ?? tag }
        XCTAssertEqual(primary(firstTag), primary(systemTag), "Accept-Language \(acceptLanguage) does not lead with the system language \(systemTag)")
        XCTAssertEqual(firstTag, languages.first?.lowercased(), "Accept-Language disagrees with navigator.languages \(languages)")
    }

    // MARK: - Chrome identity on the Web Store only

    func testChromeIdentityHostMatcher() {
        let store = [
            "https://chromewebstore.google.com/",
            "https://chromewebstore.google.com/detail/ublock-origin/cjpalhdlnbpafiamejdnhcphjbkeiagm",
            "https://CHROME.google.com/webstore",
            "https://chrome.google.com/webstore/detail/x/cjpalhdlnbpafiamejdnhcphjbkeiagm",
        ]
        for string in store {
            XCTAssertTrue(WebKitProduct.usesChromeIdentity(for: URL(string: string)), string)
        }
        let other = [
            "http://chromewebstore.google.com/",
            "https://chrome.google.com/",
            "https://chrome.google.com/webstorefront",
            "https://chrome.google.com/intl/en/chrome/",
            "https://accounts.google.com/ServiceLogin",
            "https://google.com/webstore",
            "https://chromewebstore.google.com.evil.example/",
            "https://evilchromewebstore.google.com/",
            "https://example.com/?u=https://chromewebstore.google.com/",
            "about:blank",
        ]
        for string in other {
            XCTAssertFalse(WebKitProduct.usesChromeIdentity(for: URL(string: string)), string)
        }
        XCTAssertFalse(WebKitProduct.usesChromeIdentity(for: nil))
        XCTAssertTrue(WebKitProduct.webStoreUserAgent.contains(" Chrome/\(WebKitProduct.webStoreProductVersion) "))
        XCTAssertTrue(WebKitProduct.webStoreProductVersion.hasPrefix("\(WebKitProduct.webStoreChromeMajorVersion)."))
    }

    func testStoreNavigationGetsChromeUserAgentAndLeavingRestoresSafari() throws {
        let (store, afterLeaving, storeScript, storeThenLeftScript) = try WebKitLiveEngineHost.runLive {
            () -> (LiveHTTPTestServer.RecordedRequest?, LiveHTTPTestServer.RecordedRequest?, String, String) in
            let server = try LiveHTTPTestServer(routes: [
                "/store/detail": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.html),
                "/elsewhere": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.html),
            ])
            defer { server.stop() }
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            // The local server stands in for the store host; the production matcher is covered above.
            contents.chromeIdentityMatcher = { $0?.path.hasPrefix("/store") == true }

            contents.load(server.baseURL.appendingPathComponent("store/detail"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            let onStore = try await contents.evaluateJavaScript("navigator.userAgent") as? String ?? ""

            contents.load(server.baseURL.appendingPathComponent("elsewhere"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(100))
            let left = try await contents.evaluateJavaScript("navigator.userAgent") as? String ?? ""
            return (server.requestLog.first(path: "/store/detail"), server.requestLog.first(path: "/elsewhere"), onStore, left)
        }

        let storeRequest = try XCTUnwrap(store, "the store page was never requested")
        XCTAssertEqual(storeRequest.headers["user-agent"], WebKitProduct.webStoreUserAgent, "the store request did not carry the Chrome identity")
        XCTAssertEqual(storeScript, WebKitProduct.webStoreUserAgent, "navigator.userAgent on the store page is not the Chrome identity")

        let leftRequest = try XCTUnwrap(afterLeaving, "the page after the store was never requested")
        XCTAssertEqual(leftRequest.headers["user-agent"], WebKitProduct.userAgent, "leaving the store kept the Chrome identity on the wire")
        XCTAssertEqual(storeThenLeftScript, WebKitProduct.userAgent, "leaving the store kept the Chrome identity in JavaScript")
        XCTAssertFalse(storeThenLeftScript.contains("Chrome/"))
    }

    func testExplicitSessionOverrideBeatsTheStoreIdentity() throws {
        let override = "OrbitUserAgentOverrideProbe/9.9 (live test)"
        let header = try WebKitLiveEngineHost.runLive { () -> String? in
            let server = try LiveHTTPTestServer(routes: ["/store/x": LiveHTTPTestServer.Route(contentType: "text/html", body: Self.html)])
            defer { server.stop() }
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let session = engine.defaultSession
            defer { session.setUserAgent("") }
            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.chromeIdentityMatcher = { _ in true }
            session.setUserAgent(override)
            contents.load(server.baseURL.appendingPathComponent("store/x"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            return server.requestLog.first(path: "/store/x")?.headers["user-agent"]
        }
        XCTAssertEqual(header, override, "the per-site override must win over the store's Chrome identity")
    }

    // MARK: - The per-session override

    func testSessionUserAgentOverrideTakesEffectAndClearsBackToTheDefault() throws {
        let override = "OrbitUserAgentOverrideProbe/9.9 (live test)"

        let (overriddenScript, overriddenHeader, restoredScript) = try WebKitLiveEngineHost.runLive {
            () -> (String, String?, String) in
            let server = try LiveHTTPTestServer(routes: [
                "/overridden": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>overridden</body></html>"),
                "/restored": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>restored</body></html>"),
            ])
            defer { server.stop() }

            let engine = await WebKitLiveEngineHost.sharedEngine()
            let session = engine.defaultSession
            // Process-wide, so every later live suite inherits it if it is not cleared.
            defer { session.setUserAgent("") }

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            session.setUserAgent(override)
            contents.load(server.baseURL.appendingPathComponent("overridden"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            let overridden = try await contents.evaluateJavaScript("navigator.userAgent") as? String ?? ""
            let header = server.requestLog.first(path: "/overridden")?.headers["user-agent"]

            session.setUserAgent("")
            contents.load(server.baseURL.appendingPathComponent("restored"))
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            let restored = try await contents.evaluateJavaScript("navigator.userAgent") as? String ?? ""

            return (overridden, header, restored)
        }

        XCTAssertEqual(overriddenScript, override, "setUserAgent did not reach navigator.userAgent")
        XCTAssertEqual(overriddenHeader, override, "setUserAgent did not reach the User-Agent request header")
        XCTAssertEqual(
            restoredScript,
            WebKitProduct.userAgent,
            "clearing the override did not restore the default Safari User-Agent"
        )
    }

    // MARK: - Public sites

    // Needs no account: the block is served before any credential is asked for. Hits the public site, like the other live web tests.
    func testGoogleSignInPageIsNotBlocked() throws {
        let readings = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> [String: String] in
            let contents = try await WebKitLiveEngineHost.makeContents()
            defer { contents.close() }
            contents.load(URL(string: "https://accounts.google.com/ServiceLogin?hl=en")!)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .seconds(3))
            var out: [String: String] = [:]
            for (key, expression) in [
                ("finalURL", "location.href"),
                ("ua", "navigator.userAgent"),
                ("title", "document.title"),
                ("bodyHasBlockText", "String(document.body.innerText.indexOf('may not be secure') >= 0)"),
                ("bodyHasCouldntSignIn", "String(/Couldn.t sign you in/.test(document.body.innerText))"),
                ("hasEmailField", "String(!!document.querySelector('input[type=email], input[name=identifier]'))"),
                ("bodySnippet", "document.body.innerText.slice(0, 160).replace(/\\s+/g, ' ')"),
            ] {
                out[key] = try await contents.evaluateJavaScript(expression) as? String ?? "<nil>"
            }
            return out
        }
        for (key, value) in readings.sorted(by: { $0.key < $1.key }) {
            print("ORBIT-GOOGLE \(key)=\(value)")
        }
        XCTAssertEqual(readings["ua"], WebKitProduct.userAgent, "the sign-in page was not loaded with the Safari identity")
        XCTAssertEqual(
            readings["bodyHasCouldntSignIn"], "false",
            "Google served its \"Couldn't sign you in / this browser may not be secure\" block to the Safari identity instead of the sign-in form."
        )
        XCTAssertEqual(
            readings["hasEmailField"], "true",
            "Google's sign-in page did not render an email field, so the sign-in form was not served."
        )
    }
}
