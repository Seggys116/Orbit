//  User-Agent/Client Hints/Sec-CH-UA* headers read off the real socket
//  (not what the page thinks it sent), plus setUserAgent overrides.

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
        // 127.0.0.1, not about:blank: navigator.userAgentData is [SecureContext],
        // and a fresh about:blank's opaque origin is not one.
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
            // Process-wide (one BrowserContext), so it must be cleared
            // however this test leaves, or every later live suite inherits it.
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

    /// Major versions only -- Sec-CH-UA and navigator.userAgentData.brands
    /// both carry the significant version. Deliberately just Chromium and
    /// Google Chrome, byte-for-byte stock Chrome's brand list: no Orbit
    /// brand, ever -- see orbit_user_agent.cc.
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

    /// `"Chromium";v="151", "Google Chrome";v="151"` — RFC 8941 list. GREASE
    /// brands exclude `"` and `,`, so quoted-token extraction is exact.
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
}
