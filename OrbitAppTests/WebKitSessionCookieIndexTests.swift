//  WebKitSession.startWatchingCookies once built its known-cookie table with
//  Dictionary(uniqueKeysWithValues:), which traps on a repeated key. A real profile's store held cookies
//  sharing name, domain and path with different attributes, so Orbit crashed about two seconds after launch.

import WebKit
import XCTest

@testable import Orbit

@MainActor
final class WebKitSessionCookieIndexTests: XCTestCase {

    private func cookie(
        _ name: String,
        value: String,
        domain: String = "example.com",
        path: String = "/",
        sameSite: HTTPCookieStringPolicy? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if let sameSite { properties[.sameSitePolicy] = sameSite }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    func testTwoCookiesSharingNameDomainAndPathDoNotTrapAndCollapseToOneEntry() throws {
        let lax = try cookie("session", value: "lax", sameSite: .sameSiteLax)
        let strict = try cookie("session", value: "strict", sameSite: .sameSiteStrict)

        let index = WebKitSession.indexCookies([lax, strict])

        XCTAssertEqual(index.count, 1, "Cookies with the same name, domain and path should share one change-detection key.")
        XCTAssertEqual(index.values.first?.value, "strict", "The later cookie should win, matching what noteCookies does for the same input.")
    }

    func testDistinctCookiesStayDistinctAroundADuplicatePair() throws {
        let cookies = [
            try cookie("a", value: "1"),
            try cookie("a", value: "2", sameSite: .sameSiteLax),
            try cookie("a", value: "3", path: "/app"),
            try cookie("a", value: "4", domain: "other.example"),
            try cookie("b", value: "5"),
        ]

        let index = WebKitSession.indexCookies(cookies)

        XCTAssertEqual(index.count, 4, "Only the genuinely repeated key should collapse; name, domain and path still separate cookies.")
        XCTAssertEqual(Set(index.keys), ["a|example.com|/", "a|example.com|/app", "a|other.example|/", "b|example.com|/"])
    }

    func testAnEmptyStoreIndexesToNothing() {
        XCTAssertTrue(WebKitSession.indexCookies([]).isEmpty)
    }

    /// The shape of the real crash: a large store where a few keys repeat.
    func testALargeStoreWithScatteredRepeatedKeysIndexesEveryUniqueKey() throws {
        var cookies: [HTTPCookie] = []
        for i in 0..<3000 { cookies.append(try cookie("c\(i)", value: "v")) }
        for i in stride(from: 0, to: 3000, by: 700) {
            cookies.append(try cookie("c\(i)", value: "dup", sameSite: .sameSiteStrict))
        }

        let index = WebKitSession.indexCookies(cookies)

        XCTAssertEqual(index.count, 3000)
        XCTAssertEqual(index["c0|example.com|/"]?.value, "dup")
    }

    // MARK: - watching only when asked

    private func waitUntil(_ timeout: Duration = .seconds(8), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testCookieChangesAreReportedOnlyWhileTheWatchIsRunning() async throws {
        let session = WebKitSession(identifier: "cookie-watch-\(UUID().uuidString)", persistent: false, storageURL: nil)
        var added: [String] = []
        session.onCookieChanged = { cookie, removed in if !removed { added.append(cookie.name) } }
        let store = session.dataStore.httpCookieStore

        await store.setCookie(try cookie("before", value: "1"))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(added.isEmpty, "A session nobody asked to watch still read the whole cookie store on a change.")

        session.startWatchingCookies()
        try await Task.sleep(for: .milliseconds(700))
        await store.setCookie(try cookie("during", value: "1"))
        try await waitUntil { added.contains("during") }
        XCTAssertEqual(added, ["during"], "The cookie that was already there is not a change.")

        session.stopWatchingCookies()
        await store.setCookie(try cookie("after", value: "1"))
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(added, ["during"], "A stopped watch kept reporting.")
    }

    func testABurstOfCookieChangesIsStillReportedInFull() async throws {
        let session = WebKitSession(identifier: "cookie-burst-\(UUID().uuidString)", persistent: false, storageURL: nil)
        var added = Set<String>()
        session.onCookieChanged = { cookie, removed in if !removed { added.insert(cookie.name) } }
        session.startWatchingCookies()
        try await Task.sleep(for: .milliseconds(700))

        let names = (0..<40).map { "burst\($0)" }
        for name in names { await session.dataStore.httpCookieStore.setCookie(try cookie(name, value: "1")) }

        try await waitUntil { added.count == names.count }
        XCTAssertEqual(added, Set(names), "Reads that were folded into one read dropped a cookie change.")
        session.stopWatchingCookies()
    }

    func testAWatchCanBeStartedAgainAfterItWasStopped() async throws {
        let session = WebKitSession(identifier: "cookie-restart-\(UUID().uuidString)", persistent: false, storageURL: nil)
        var added: [String] = []
        session.onCookieChanged = { cookie, removed in if !removed { added.append(cookie.name) } }
        session.startWatchingCookies()
        session.stopWatchingCookies()
        session.startWatchingCookies()
        try await Task.sleep(for: .milliseconds(700))

        await session.dataStore.httpCookieStore.setCookie(try cookie("again", value: "1"))

        try await waitUntil { added.contains("again") }
        XCTAssertEqual(added, ["again"])
        session.stopWatchingCookies()
    }
}
