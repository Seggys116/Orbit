//  User-Agent and Sec-CH-UA* headers read off the real socket.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumUserAgentLiveTests: XCTestCase {

    private struct BrandVersion: Hashable {
        let brand: String
        let version: String
    }

    // MARK: - The User-Agent string

    func testNavigatorUserAgentIsOrbitsChromeCompatibleString() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let userAgent = try LiveChromiumEngineHost.runLive { () -> String in
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            return try await contents.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        }

        XCTAssertFalse(userAgent.isEmpty, "navigator.userAgent is empty — every site that parses it sees nothing")
        XCTAssertEqual(
            userAgent,
            ChromiumBuild.userAgent,
            "the engine's User-Agent must be the one ChromiumBuild publishes, which Orbit's own HTTP clients also send"
        )
        XCTAssertTrue(userAgent.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "), userAgent)
        XCTAssertTrue(userAgent.contains(" \(ChromiumBuild.userAgentProduct) "), userAgent)
        XCTAssertTrue(userAgent.hasSuffix(" Safari/537.36"), userAgent)
    }

    // MARK: - navigator.userAgentData

    func testNavigatorUserAgentDataExposesOnlyChromeAndChromiumBrands() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        // 127.0.0.1, not about:blank: userAgentData is [SecureContext].
        let json = try LiveChromiumEngineHost.runLive { () -> String in
            let server = try LiveHTTPTestServer(routes: [
                "/brands": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>brands</body></html>"),
            ])
            defer { server.stop() }
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("brands"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            return try await contents.evaluateJavaScript("""
            JSON.stringify({
              exists: !!navigator.userAgentData,
              brands: navigator.userAgentData ? navigator.userAgentData.brands : [],
              mobile: navigator.userAgentData ? navigator.userAgentData.mobile : null,
              platform: navigator.userAgentData ? navigator.userAgentData.platform : null
            })
            """) as? String ?? ""
        }

        let payload = try Self.decodeObject(json)
        XCTAssertEqual(payload["exists"] as? Bool, true, "navigator.userAgentData is missing entirely")
        XCTAssertEqual(payload["mobile"] as? Bool, false)
        XCTAssertEqual(payload["platform"] as? String, "macOS")

        let brands = Self.brands(fromJSValue: payload["brands"])
        XCTAssertFalse(
            brands.isEmpty,
            "navigator.userAgentData.brands is empty — site bundles that read it throw on an empty brand list"
        )
        for expected in Self.expectedMajorVersionBrands {
            XCTAssertTrue(
                brands.contains(expected),
                "navigator.userAgentData.brands is missing \(expected.brand);v=\"\(expected.version)\" — got \(Self.describe(brands))"
            )
        }
        XCTAssertFalse(
            brands.contains { $0.brand == "Orbit" },
            "navigator.userAgentData.brands must never carry Orbit's own brand — Google's sign-in flow blocks any " +
                "Sec-CH-UA brand it doesn't recognise, and this exact brand is what triggered that block — got \(Self.describe(brands))"
        )
        // Chromium's GREASE entry, on top of the two real brands above.
        XCTAssertEqual(brands.count, Self.expectedMajorVersionBrands.count + 1, Self.describe(brands))
    }

    // MARK: - What actually reaches the server

    func testSecCHUAHeadersMatchTheJavaScriptVisibleBrands() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (request, brandsJSON) = try LiveChromiumEngineHost.runLive { () -> (LiveHTTPTestServer.RecordedRequest?, String) in
            let server = try LiveHTTPTestServer(routes: [
                "/ua": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body>orbit-user-agent-probe</body></html>"
                ),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("ua"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let brands = try await contents.evaluateJavaScript(
                "JSON.stringify(navigator.userAgentData ? navigator.userAgentData.brands : [])"
            ) as? String ?? "[]"
            return (server.requestLog.first(path: "/ua"), brands)
        }

        let recorded = try XCTUnwrap(request, "the local server never saw the navigation")
        XCTAssertEqual(
            recorded.headers["user-agent"],
            ChromiumBuild.userAgent,
            "the User-Agent on the wire disagrees with the one JavaScript sees"
        )
        XCTAssertEqual(recorded.headers["sec-ch-ua-mobile"], "?0")
        XCTAssertEqual(recorded.headers["sec-ch-ua-platform"], "\"macOS\"")

        let header = try XCTUnwrap(
            recorded.headers["sec-ch-ua"],
            "no Sec-CH-UA header was sent at all — headers seen: \(recorded.headers.keys.sorted())"
        )
        let headerBrands = Self.parseBrandListHeader(header)
        XCTAssertFalse(headerBrands.isEmpty, "Sec-CH-UA was present but parsed to nothing: \(header)")

        let scriptBrands = Self.brands(fromJSON: brandsJSON)
        XCTAssertEqual(
            headerBrands,
            scriptBrands,
            "Sec-CH-UA \(Self.describe(headerBrands)) disagrees with navigator.userAgentData.brands \(Self.describe(scriptBrands))"
        )
        for expected in Self.expectedMajorVersionBrands {
            XCTAssertTrue(headerBrands.contains(expected), "Sec-CH-UA is missing \(expected.brand): \(header)")
        }
        XCTAssertFalse(
            headerBrands.contains { $0.brand == "Orbit" },
            "Sec-CH-UA must never carry Orbit's own brand — this is the header Google's sign-in flow reads, and " +
                "an unrecognised brand on it is what blocks sign-in: \(header)"
        )
    }

    // MARK: - The per-session override

    func testSessionUserAgentOverrideTakesEffectAndClearsBackToTheDefault() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let override = "OrbitUserAgentOverrideProbe/9.9 (live test)"

        let (overriddenScript, overriddenHeader, restoredScript) = try LiveChromiumEngineHost.runLive {
            () -> (String, String?, String) in
            let server = try LiveHTTPTestServer(routes: [
                "/overridden": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>overridden</body></html>"),
                "/restored": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>restored</body></html>"),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let session = engine.defaultSession
            // Process-wide, so every later live suite inherits it if it is not cleared.
            defer { session.setUserAgent("") }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            session.setUserAgent(override)
            contents.load(server.baseURL.appendingPathComponent("overridden"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let overridden = try await contents.evaluateJavaScript("navigator.userAgent") as? String ?? ""
            let header = server.requestLog.first(path: "/overridden")?.headers["user-agent"]

            session.setUserAgent("")
            contents.load(server.baseURL.appendingPathComponent("restored"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let restored = try await contents.evaluateJavaScript("navigator.userAgent") as? String ?? ""

            return (overridden, header, restored)
        }

        XCTAssertEqual(overriddenScript, override, "setUserAgent did not reach navigator.userAgent")
        XCTAssertEqual(overriddenHeader, override, "setUserAgent did not reach the User-Agent request header")
        XCTAssertEqual(
            restoredScript,
            ChromiumBuild.userAgent,
            "clearing the override did not restore Orbit's own default User-Agent"
        )
    }

    // MARK: - Helpers

    /// Stock Chrome's brand list, major versions only -- see orbit_user_agent.cc.
    private static var expectedMajorVersionBrands: [BrandVersion] {
        [
            BrandVersion(brand: "Chromium", version: String(ChromiumBuild.majorVersion)),
            BrandVersion(brand: "Google Chrome", version: String(ChromiumBuild.majorVersion)),
        ]
    }

    private static func decodeObject(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "not a JSON object: \(json)")
    }

    private static func brands(fromJSON json: String) -> Set<BrandVersion> {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return [] }
        return brands(fromJSValue: list)
    }

    private static func brands(fromJSValue value: Any?) -> Set<BrandVersion> {
        guard let entries = value as? [[String: Any]] else { return [] }
        return Set(entries.compactMap { entry in
            guard let brand = entry["brand"] as? String, let version = entry["version"] as? String else { return nil }
            return BrandVersion(brand: brand, version: version)
        })
    }

    /// RFC 8941 list; GREASE brands exclude `"` and `,`, so quoted-token extraction is exact.
    private static func parseBrandListHeader(_ header: String) -> Set<BrandVersion> {
        let pattern = #""([^"]*)";\s*v="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        var result: Set<BrandVersion> = []
        for match in regex.matches(in: header, range: range) {
            guard let brandRange = Range(match.range(at: 1), in: header),
                  let versionRange = Range(match.range(at: 2), in: header)
            else { continue }
            result.insert(BrandVersion(brand: String(header[brandRange]), version: String(header[versionRange])))
        }
        return result
    }

    private static func describe(_ brands: Set<BrandVersion>) -> String {
        brands.map { "\($0.brand);v=\"\($0.version)\"" }.sorted().joined(separator: ", ")
    }

    // MARK: - Browser identity surface

    // window.chrome and the PDF plugin list are long-standing "is this a real browser" signals.
    func testBrowserIdentitySurfaceMatchesChrome() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let readings = try LiveChromiumEngineHost.runLive { () -> [String: String] in
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            var out: [String: String] = [:]
            for (key, expression) in [
                ("typeofChrome", "typeof window.chrome"),
                ("chromeKeys", "window.chrome ? Object.keys(window.chrome).sort().join(',') : '<none>'"),
                ("typeofChromeApp", "typeof (window.chrome || {}).app"),
                ("appKeys", "window.chrome && window.chrome.app ? Object.keys(window.chrome.app).join(',') : '<none>'"),
                ("appIsInstalled", "String(!!(window.chrome && window.chrome.app && window.chrome.app.isInstalled))"),
                ("appRunningState", "window.chrome && window.chrome.app ? String(window.chrome.app.runningState()) : '<none>'"),
                ("hasLoadTimes", "String(!!(window.chrome && window.chrome.loadTimes))"),
                ("hasCsi", "String(!!(window.chrome && window.chrome.csi))"),
                ("pluginCount", "String(navigator.plugins.length)"),
                ("mimeTypeCount", "String(navigator.mimeTypes.length)"),
                ("webdriver", "String(navigator.webdriver)"),
            ] {
                out[key] = try await contents.evaluateJavaScript(expression) as? String ?? "<nil>"
            }
            return out
        }

        for (key, value) in readings.sorted(by: { $0.key < $1.key }) {
            print("ORBIT-IDENTITY \(key)=\(value)")
        }

        XCTAssertEqual(readings["webdriver"], "false", "navigator.webdriver must not advertise automation")
        XCTAssertEqual(
            readings["typeofChrome"], "object",
            "window.chrome is absent. Every Chromium-derived browser exposes it, and its absence is a long-standing signal that a client is not a real browser."
        )
        XCTAssertEqual(readings["hasLoadTimes"], "true", "window.chrome.loadTimes is missing")
        XCTAssertEqual(readings["hasCsi"], "true", "window.chrome.csi is missing")
        XCTAssertEqual(
            readings["typeofChromeApp"], "object",
            "window.chrome.app is missing. Chrome exposes it to every web page, and Google's sign-in serves its " +
                "\"browser may not be secure\" block on the identifier step when it is absent."
        )
    }

    // Needs no account: the block is served before any credential is asked for.
    func testGoogleSignInPageIsNotBlocked() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let readings = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> [String: String] in
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.load(URL(string: "https://accounts.google.com/ServiceLogin?hl=en")!)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .seconds(3))
            var out: [String: String] = [:]
            for (key, expression) in [
                ("finalURL", "location.href"),
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
        XCTAssertEqual(
            readings["bodyHasCouldntSignIn"], "false",
            "Google served its \"Couldn't sign you in / this browser may not be secure\" block instead of the sign-in form."
        )
        XCTAssertEqual(
            readings["hasEmailField"], "true",
            "Google's sign-in page did not render an email field, so the sign-in form was not served."
        )
    }

    // The owner's exact repro: identifier "test", Enter, no credential needed.
    func testGoogleSignInIdentifierSubmissionIsBlocked() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let readings = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> [String: String] in
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.load(URL(string: "https://accounts.google.com/ServiceLogin?hl=en")!)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .seconds(3))

            let submitOutcome = try await contents.evaluateJavaScript(
                """
                (function() {
                  const input = document.querySelector('input[type=email], input[name=identifier]');
                  if (!input) { return 'no-input'; }
                  input.focus();
                  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                  setter.call(input, 'test');
                  input.dispatchEvent(new Event('input', {bubbles: true}));
                  input.dispatchEvent(new Event('change', {bubbles: true}));
                  const opts = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true};
                  input.dispatchEvent(new KeyboardEvent('keydown', opts));
                  input.dispatchEvent(new KeyboardEvent('keypress', opts));
                  input.dispatchEvent(new KeyboardEvent('keyup', opts));
                  return 'submitted-enter';
                })()
                """,
                userGesture: true
            ) as? String ?? "<nil>"

            try await Task.sleep(for: .seconds(2))

            // Only fires when nothing has changed yet, so it never double-submits.
            _ = try await contents.evaluateJavaScript(
                """
                (function() {
                  if (document.querySelector('input[type=password]')) { return 'already-advanced'; }
                  if (/may not be secure|Couldn.t sign you in/.test(document.body.innerText)) { return 'already-blocked'; }
                  const button = document.querySelector('#identifierNext button, #identifierNext, div[role=button][jsname]');
                  if (button) { button.click(); return 'clicked-next'; }
                  return 'no-button';
                })()
                """,
                userGesture: true
            ) as? String ?? "<nil>"

            try? await LiveChromiumEngineHost.waitUntilStoppedLoading(contents, timeout: .seconds(15))
            try await Task.sleep(for: .seconds(4))

            var out: [String: String] = ["submitOutcome": submitOutcome]
            for (key, expression) in [
                ("finalURL", "location.href"),
                ("title", "document.title"),
                ("bodyHasBlockText", "String(document.body.innerText.indexOf('may not be secure') >= 0)"),
                ("bodyHasCouldntSignIn", "String(/Couldn.t sign you in/.test(document.body.innerText))"),
                ("hasPasswordField", "String(!!document.querySelector('input[type=password]'))"),
                ("hasEmailField", "String(!!document.querySelector('input[type=email], input[name=identifier]'))"),
                ("bodySnippet", "document.body.innerText.slice(0, 400).replace(/\\s+/g, ' ')"),
            ] {
                out[key] = try await contents.evaluateJavaScript(expression) as? String ?? "<nil>"
            }
            return out
        }
        for (key, value) in readings.sorted(by: { $0.key < $1.key }) {
            print("ORBIT-GOOGLE-SUBMIT \(key)=\(value)")
        }
        XCTAssertEqual(
            readings["bodyHasCouldntSignIn"], "false",
            "Submitting the identifier \"test\" made Google serve its \"Couldn't sign you in / this browser may not " +
                "be secure\" block. Final URL: \(readings["finalURL"] ?? "<nil>"), snippet: \(readings["bodySnippet"] ?? "<nil>")"
        )
    }

    // FedCM, WebAuthn and the high-entropy client hints Google's sign-in probes.
    func testHighEntropyClientHintsAndModernIdentitySurfaces() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let readings = try LiveChromiumEngineHost.runLive(timeout: 40) { () -> [String: String] in
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }

            _ = try await contents.evaluateJavaScript(
                """
                window.__orbitHighEntropy = null;
                if (navigator.userAgentData && navigator.userAgentData.getHighEntropyValues) {
                  navigator.userAgentData.getHighEntropyValues([
                    'architecture', 'bitness', 'formFactors', 'fullVersionList',
                    'model', 'platformVersion', 'uaFullVersion', 'wow64'
                  ]).then(v => { window.__orbitHighEntropy = JSON.stringify(v); })
                    .catch(e => { window.__orbitHighEntropy = JSON.stringify({error: String(e)}); });
                } else {
                  window.__orbitHighEntropy = JSON.stringify({error: 'no userAgentData'});
                }
                """
            )
            var highEntropyJSON = "<nil>"
            for _ in 0..<50 {
                if let value = try await contents.evaluateJavaScript("window.__orbitHighEntropy") as? String {
                    highEntropyJSON = value
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            // Settles-or-times-out: "pending-after-3s" is itself the finding.
            _ = try await contents.evaluateJavaScript(
                """
                window.__orbitFedCM = 'pending';
                if (navigator.credentials && navigator.credentials.get) {
                  navigator.credentials.get({identity: {providers: []}})
                    .then(() => { window.__orbitFedCM = 'resolved'; })
                    .catch(e => { window.__orbitFedCM = 'rejected: ' + e.name + ': ' + e.message; });
                } else {
                  window.__orbitFedCM = 'no-credentials-get';
                }
                """
            )
            var fedCMOutcome = "<nil>"
            for _ in 0..<30 {
                if let value = try await contents.evaluateJavaScript("window.__orbitFedCM") as? String, value != "pending" {
                    fedCMOutcome = value
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if fedCMOutcome == "<nil>" { fedCMOutcome = "pending-after-3s" }

            var out: [String: String] = ["highEntropyValues": highEntropyJSON, "fedCMOutcome": fedCMOutcome]
            for (key, expression) in [
                ("hasPublicKeyCredential", "String(typeof PublicKeyCredential !== 'undefined')"),
                ("hasCredentialsAPI", "String(!!(navigator.credentials && navigator.credentials.get))"),
                ("hasIdentityCredential", "String(typeof window.IdentityCredential !== 'undefined')"),
                ("hasNetworkInformation", "String(!!navigator.connection)"),
                ("connectionEffectiveType", "navigator.connection ? navigator.connection.effectiveType : '<none>'"),
                ("hasNotification", "String(typeof Notification !== 'undefined')"),
                ("notificationPermission", "typeof Notification !== 'undefined' ? Notification.permission : '<none>'"),
            ] {
                out[key] = try await contents.evaluateJavaScript(expression) as? String ?? "<nil>"
            }
            return out
        }
        for (key, value) in readings.sorted(by: { $0.key < $1.key }) {
            print("ORBIT-ENTROPY \(key)=\(value)")
        }
        XCTAssertNotEqual(readings["highEntropyValues"], "<nil>", "getHighEntropyValues() never resolved or rejected")
    }

    // tls.peet.ws is a third-party probe echoing the ClientHello and HTTP/2 frames the server saw.
    func testTLSAndHTTP2FingerprintAgainstAPublicProbe() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let bodyJSON = try LiveChromiumEngineHost.runLive(timeout: 45) { () -> String in
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.load(URL(string: "https://tls.peet.ws/api/all")!)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .seconds(1))
            // Blink wraps a JSON body in a <pre>; falls back to the body text.
            return try await contents.evaluateJavaScript(
                "document.querySelector('pre') ? document.querySelector('pre').innerText : document.body.innerText"
            ) as? String ?? ""
        }

        print("ORBIT-TLS-FINGERPRINT raw=\(bodyJSON)")
        guard let data = bodyJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("tls.peet.ws did not return parseable JSON -- got: \(bodyJSON.prefix(200))")
            return
        }
        let tls = object["tls"] as? [String: Any] ?? [:]
        let http2 = object["http2"] as? [String: Any] ?? [:]
        for (key, value) in [
            ("http_version", object["http_version"]),
            ("ja3_hash", tls["ja3_hash"]),
            ("ja4", tls["ja4"]),
            ("akamai_fingerprint_hash", http2["akamai_fingerprint_hash"]),
        ] {
            print("ORBIT-TLS-FINGERPRINT \(key)=\(value ?? "<missing>")")
        }
        XCTAssertNotNil(tls["ja4"], "no ja4 fingerprint in the probe response -- compare this value against a known-good Chrome 152 ja4 by hand")
    }

    // Chrome sends `en-US,en;q=0.9` and `gzip, deflate, br, zstd`.
    func testAcceptHeadersOnTheWireMatchChrome() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (recorded, scriptLanguages) = try LiveChromiumEngineHost.runLive {
            () -> (LiveHTTPTestServer.RecordedRequest?, String) in
            let server = try LiveHTTPTestServer(routes: [
                "/accept": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>accept</body></html>"),
            ])
            defer { server.stop() }
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("accept"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let languages = try await contents.evaluateJavaScript(
                "JSON.stringify({language: navigator.language, languages: navigator.languages})"
            ) as? String ?? "<nil>"
            return (server.requestLog.first(path: "/accept"), languages)
        }

        let request = try XCTUnwrap(recorded, "the local server never saw the navigation")
        print("ORBIT-ACCEPT accept-language=\(request.headers["accept-language"] ?? "<absent>")")
        print("ORBIT-ACCEPT accept-encoding=\(request.headers["accept-encoding"] ?? "<absent>")")
        print("ORBIT-ACCEPT accept=\(request.headers["accept"] ?? "<absent>")")
        print("ORBIT-ACCEPT navigatorLanguages=\(scriptLanguages)")

        XCTAssertEqual(
            request.headers["accept-language"], "en-US,en;q=0.9",
            "Accept-Language is not the one Chrome sends; a UA claiming Chrome with a header no Chrome build ever emits is a server-side tell"
        )
        XCTAssertEqual(
            request.headers["accept-encoding"], "gzip, deflate, br, zstd",
            "Accept-Encoding is missing zstd, which every Chrome since M123 advertises"
        )
    }

    // 127.0.0.1, not about:blank: every reading below is [SecureContext].
    func testIdentitySurfaceOnASecureOrigin() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let readings = try LiveChromiumEngineHost.runLive(timeout: 60) { () -> [String: String] in
            let server = try LiveHTTPTestServer(routes: [
                "/surface": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>surface</body></html>"),
            ])
            defer { server.stop() }
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.load(server.baseURL.appendingPathComponent("surface"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript(
                """
                window.__orbitSurface = null;
                (async function() {
                  const out = {};
                  const read = async (key, fn) => {
                    try { out[key] = String(await fn()); } catch (e) { out[key] = 'threw: ' + e; }
                  };
                  await read('secureContext', () => window.isSecureContext);
                  await read('language', () => navigator.language);
                  await read('languages', () => JSON.stringify(navigator.languages));
                  await read('platform', () => navigator.platform);
                  await read('vendor', () => navigator.vendor);
                  await read('hardwareConcurrency', () => navigator.hardwareConcurrency);
                  await read('deviceMemory', () => navigator.deviceMemory);
                  await read('maxTouchPoints', () => navigator.maxTouchPoints);
                  await read('pdfViewerEnabled', () => navigator.pdfViewerEnabled);
                  await read('pluginNames', () => Array.from(navigator.plugins).map(p => p.name).join('|') || '<empty>');
                  await read('mimeTypes', () => Array.from(navigator.mimeTypes).map(m => m.type).join('|') || '<empty>');
                  await read('chromeKeys', () => window.chrome ? Object.keys(window.chrome).sort().join(',') : '<no chrome>');
                  await read('typeofChromeApp', () => typeof (window.chrome || {}).app);
                  await read('typeofChromeRuntime', () => typeof (window.chrome || {}).runtime);
                  await read('typeofPublicKeyCredential', () => typeof window.PublicKeyCredential);
                  await read('isUVPAA', () => window.PublicKeyCredential
                    ? PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()
                    : '<no PublicKeyCredential>');
                  await read('isConditionalMediationAvailable', () => window.PublicKeyCredential && PublicKeyCredential.isConditionalMediationAvailable
                    ? PublicKeyCredential.isConditionalMediationAvailable()
                    : '<absent>');
                  await read('hasCredentialsGet', () => !!(navigator.credentials && navigator.credentials.get));
                  await read('hasIdentityCredential', () => typeof window.IdentityCredential);
                  await read('userAgentData', () => navigator.userAgentData
                    ? JSON.stringify(navigator.userAgentData.brands) : '<absent>');
                  await read('highEntropy', async () => navigator.userAgentData
                    ? JSON.stringify(await navigator.userAgentData.getHighEntropyValues(
                        ['architecture', 'bitness', 'formFactors', 'fullVersionList', 'model', 'platformVersion', 'uaFullVersion', 'wow64']))
                    : '<absent>');
                  await read('notificationPermission', () => typeof Notification !== 'undefined' ? Notification.permission : '<absent>');
                  await read('permissionsNotifications', async () => (await navigator.permissions.query({name: 'notifications'})).state);
                  await read('permissionsGeolocation', async () => (await navigator.permissions.query({name: 'geolocation'})).state);
                  await read('webglVendor', () => {
                    const gl = document.createElement('canvas').getContext('webgl');
                    if (!gl) { return '<no webgl>'; }
                    const ext = gl.getExtension('WEBGL_debug_renderer_info');
                    return ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : '<no debug ext>';
                  });
                  await read('webglRenderer', () => {
                    const gl = document.createElement('canvas').getContext('webgl');
                    if (!gl) { return '<no webgl>'; }
                    const ext = gl.getExtension('WEBGL_debug_renderer_info');
                    return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : '<no debug ext>';
                  });
                  await read('hasWebGL2', () => !!document.createElement('canvas').getContext('webgl2'));
                  await read('hasServiceWorker', () => !!navigator.serviceWorker);
                  await read('hasGetBattery', () => typeof navigator.getBattery);
                  await read('hasMediaDevices', () => !!(navigator.mediaDevices && navigator.mediaDevices.enumerateDevices));
                  await read('canPlayH264', () => document.createElement('video').canPlayType('video/mp4; codecs="avc1.42E01E"') || '<no>');
                  await read('canPlayAac', () => document.createElement('audio').canPlayType('audio/mp4; codecs="mp4a.40.2"') || '<no>');
                  await read('screen', () => screen.width + 'x' + screen.height + ' avail ' + screen.availWidth + 'x' + screen.availHeight + ' dpr ' + devicePixelRatio + ' depth ' + screen.colorDepth);
                  await read('timeZone', () => Intl.DateTimeFormat().resolvedOptions().timeZone);
                  await read('speechVoices', () => window.speechSynthesis ? speechSynthesis.getVoices().length : '<absent>');
                  await read('cookieEnabled', () => navigator.cookieEnabled);
                  await read('userActivation', () => navigator.userActivation ? navigator.userActivation.hasBeenActive : '<absent>');
                  await read('functionToString', () => Function.prototype.toString.call(navigator.permissions.query));
                  window.__orbitSurface = JSON.stringify(out);
                })();
                """
            )

            var json = "<nil>"
            for _ in 0..<100 {
                if let value = try await contents.evaluateJavaScript("window.__orbitSurface") as? String {
                    json = value
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            var out: [String: String] = [:]
            if let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in object { out[key] = String(describing: value) }
            } else {
                out["<raw>"] = json
            }
            return out
        }
        for (key, value) in readings.sorted(by: { $0.key < $1.key }) {
            print("ORBIT-SURFACE \(key)=\(value)")
        }
        XCTAssertEqual(readings["secureContext"], "true", "the probe page was not a secure context, so every gated reading is meaningless")
        XCTAssertEqual(readings["typeofChromeApp"], "object", "window.chrome.app is missing")
    }

    // Reads the submit exchange itself, not the page that replaces it.
    func testGoogleIdentifierSubmissionNetworkExchange() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let readings = try LiveChromiumEngineHost.runLive(timeout: 120) { () -> [String: String] in
            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            contents.load(URL(string: "https://accounts.google.com/ServiceLogin?hl=en")!)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .seconds(3))

            _ = try await contents.evaluateJavaScript(
                """
                window.__orbitNet = [];
                window.__orbitErrors = [];
                window.addEventListener('error', e => { window.__orbitErrors.push('error: ' + e.message + ' @ ' + e.filename + ':' + e.lineno); });
                window.addEventListener('unhandledrejection', e => { window.__orbitErrors.push('rejection: ' + e.reason); });
                (function() {
                  const origFetch = window.fetch;
                  window.fetch = function(input, init) {
                    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
                    const body = init && init.body ? String(init.body).slice(0, 3000) : '';
                    const entry = {kind: 'fetch', url: String(url).slice(0, 400), body: body, status: 'pending', response: ''};
                    window.__orbitNet.push(entry);
                    return origFetch.apply(this, arguments).then(r => {
                      entry.status = String(r.status);
                      r.clone().text().then(t => { entry.response = t.slice(0, 2000); }).catch(() => {});
                      return r;
                    }).catch(e => { entry.status = 'threw: ' + e; throw e; });
                  };
                  const origOpen = XMLHttpRequest.prototype.open;
                  const origSend = XMLHttpRequest.prototype.send;
                  XMLHttpRequest.prototype.open = function(method, url) {
                    this.__orbitEntry = {kind: 'xhr ' + method, url: String(url).slice(0, 400), body: '', status: 'pending', response: ''};
                    return origOpen.apply(this, arguments);
                  };
                  XMLHttpRequest.prototype.send = function(body) {
                    const entry = this.__orbitEntry;
                    if (entry) {
                      entry.body = body ? String(body).slice(0, 3000) : '';
                      window.__orbitNet.push(entry);
                      this.addEventListener('loadend', () => {
                        entry.status = String(this.status);
                        try { entry.response = String(this.responseText).slice(0, 2000); } catch (e) { entry.response = 'unreadable'; }
                      });
                    }
                    return origSend.apply(this, arguments);
                  };
                })();
                """
            )

            _ = try await contents.evaluateJavaScript(
                """
                (function() {
                  const input = document.querySelector('input[type=email], input[name=identifier]');
                  if (!input) { return 'no-input'; }
                  input.focus();
                  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                  setter.call(input, 'test');
                  input.dispatchEvent(new Event('input', {bubbles: true}));
                  input.dispatchEvent(new Event('change', {bubbles: true}));
                  const opts = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true};
                  input.dispatchEvent(new KeyboardEvent('keydown', opts));
                  input.dispatchEvent(new KeyboardEvent('keypress', opts));
                  input.dispatchEvent(new KeyboardEvent('keyup', opts));
                  return 'submitted-enter';
                })()
                """,
                userGesture: true
            )

            // Read before the block navigation replaces the document that made the calls.
            var net = "<nil>"
            var errors = "<nil>"
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(250))
                let captured = try await contents.evaluateJavaScript(
                    "window.__orbitNet ? JSON.stringify(window.__orbitNet) : '<gone>'"
                ) as? String ?? "<nil>"
                if captured != "<gone>" && captured != "[]" {
                    net = captured
                    errors = try await contents.evaluateJavaScript(
                        "window.__orbitErrors ? JSON.stringify(window.__orbitErrors) : '<gone>'"
                    ) as? String ?? "<nil>"
                }
                let url = try await contents.evaluateJavaScript("location.href") as? String ?? ""
                if url.contains("rejected") { break }
            }
            let finalURL = try await contents.evaluateJavaScript("location.href") as? String ?? "<nil>"
            return ["net": net, "errors": errors, "finalURL": finalURL]
        }
        print("ORBIT-NET finalURL=\(readings["finalURL"] ?? "<nil>")")
        print("ORBIT-NET errors=\(readings["errors"] ?? "<nil>")")
        print("ORBIT-NET exchange=\(readings["net"] ?? "<nil>")")
        XCTAssertNotEqual(readings["net"], "<nil>", "no XHR or fetch was captured at the identifier step")
    }

}
