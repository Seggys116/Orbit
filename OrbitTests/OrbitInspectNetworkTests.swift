// Tests for OrbitNetworkLogic; OrbitInspectNetworkLogic.swift and OrbitInspectDecode.swift are compiled directly (no @testable import).

import XCTest

final class OrbitInspectNetworkTests: XCTestCase {


    func testPhasesFullDetail() {
        var t = NetResourceTimingRaw()
        t.fetchStart = 100
        t.domainLookupStart = 105; t.domainLookupEnd = 115
        t.connectStart = 115; t.connectEnd = 135
        t.secureConnectionStart = 125
        t.requestStart = 135
        t.responseStart = 185
        t.responseEnd = 220
        t.duration = 120

        let b = OrbitNetworkLogic.phases(from: t)
        XCTAssertFalse(b.crossOriginOpaque)
        XCTAssertEqual(b.dnsMs ?? .nan, 10, accuracy: 0.001)
        XCTAssertEqual(b.connectMs ?? 0, 10, accuracy: 0.001)  // 125-115
        XCTAssertEqual(b.tlsMs ?? 0, 10, accuracy: 0.001)       // 135-125
        XCTAssertEqual(b.waitingMs ?? 0, 50, accuracy: 0.001)  // 185-135
        XCTAssertEqual(b.downloadMs ?? 0, 35, accuracy: 0.001) // 220-185
        XCTAssertEqual(b.totalMs ?? 0, 120, accuracy: 0.001)   // 220-100
    }

    func testPhasesCrossOriginOpaque() {
        var t = NetResourceTimingRaw()
        t.startTime = 50; t.duration = 80
        // All detailed timestamps are zero — cross-origin without TAO

        let b = OrbitNetworkLogic.phases(from: t)
        XCTAssertTrue(b.crossOriginOpaque)
        XCTAssertEqual(b.totalMs ?? .nan, 80, accuracy: 0.001)
        XCTAssertNil(b.dnsMs)
        XCTAssertNil(b.connectMs)
    }

    func testPhasesNoTiming() {
        let b = OrbitNetworkLogic.phases(from: NetResourceTimingRaw())
        XCTAssertFalse(b.crossOriginOpaque)
        XCTAssertNil(b.totalMs)
        XCTAssertNil(b.dnsMs)
    }

    func testPhasesNoTlsWhenNotHttps() {
        var t = NetResourceTimingRaw()
        t.fetchStart = 0; t.connectStart = 10; t.connectEnd = 30
        // secureConnectionStart = 0 means no TLS
        t.requestStart = 30; t.responseStart = 60; t.responseEnd = 80

        let b = OrbitNetworkLogic.phases(from: t)
        XCTAssertNil(b.tlsMs)
        XCTAssertEqual(b.connectMs ?? 0, 20, accuracy: 0.001)
    }

    func testPhasesRedirectTime() {
        var t = NetResourceTimingRaw()
        t.redirectStart = 10; t.redirectEnd = 30
        t.fetchStart = 30
        t.requestStart = 35; t.responseStart = 70; t.responseEnd = 90

        let b = OrbitNetworkLogic.phases(from: t)
        XCTAssertEqual(b.redirectMs ?? 0, 20, accuracy: 0.001)
    }


    func testFilterQueryEmpty() {
        XCTAssertTrue(OrbitNetworkLogic.parseFilterQuery("").isEmpty)
        XCTAssertTrue(OrbitNetworkLogic.parseFilterQuery("   ").isEmpty)
    }

    func testFilterQueryPlainText() {
        let tokens = OrbitNetworkLogic.parseFilterQuery("api")
        XCTAssertEqual(tokens.count, 1)
        if case .text(let t) = tokens[0].kind { XCTAssertEqual(t, "api") }
        else { XCTFail("expected .text") }
    }

    func testFilterQueryDomain() {
        let tokens = OrbitNetworkLogic.parseFilterQuery("domain:example.com")
        XCTAssertEqual(tokens.count, 1)
        if case .domain(let d) = tokens[0].kind { XCTAssertEqual(d, "example.com") }
        else { XCTFail("expected .domain") }
    }

    func testFilterQueryStatusCode() {
        let tokens = OrbitNetworkLogic.parseFilterQuery("status-code:404")
        if case .statusCode(let c) = tokens.first?.kind { XCTAssertEqual(c, 404) }
        else { XCTFail("expected .statusCode") }
    }

    func testFilterQueryNegation() {
        let tokens = OrbitNetworkLogic.parseFilterQuery("-domain:cdn.example.com")
        if case .negated(let inner) = tokens.first?.kind,
           case .domain(let d) = inner { XCTAssertEqual(d, "cdn.example.com") }
        else { XCTFail("expected negated domain") }
    }

    func testFilterQueryLargerThan() {
        let tokens = OrbitNetworkLogic.parseFilterQuery("larger-than:100kb")
        if case .largerThan(let bytes) = tokens.first?.kind { XCTAssertEqual(bytes, 100 * 1024) }
        else { XCTFail("expected largerThan") }
    }

    func testFilterQueryMultiple() {
        let tokens = OrbitNetworkLogic.parseFilterQuery("method:POST status-code:201")
        XCTAssertEqual(tokens.count, 2)
    }

    func testFilterQueryRegex() {
        let tokens = OrbitNetworkLogic.parseFilterQuery("/api[0-9]+/")
        XCTAssertEqual(tokens.count, 1)
        if case .regex(let p) = tokens.first?.kind { XCTAssertEqual(p, "api[0-9]+") }
        else { XCTFail("expected .regex token") }
    }


    func testMatchesFilterTextURL() {
        let record = makeRecord(url: "https://api.example.com/users")
        let tokens = OrbitNetworkLogic.parseFilterQuery("users")
        XCTAssertTrue(OrbitNetworkLogic.matchesFilter(record, tokens: tokens))
    }

    func testMatchesFilterDomain() {
        let r = makeRecord(url: "https://api.example.com/x")
        let tokens = OrbitNetworkLogic.parseFilterQuery("domain:example.com")
        XCTAssertTrue(OrbitNetworkLogic.matchesFilter(r, tokens: tokens))

        let tokens2 = OrbitNetworkLogic.parseFilterQuery("domain:other.com")
        XCTAssertFalse(OrbitNetworkLogic.matchesFilter(r, tokens: tokens2))
    }

    func testMatchesFilterNegation() {
        let r = makeRecord(url: "https://cdn.example.com/img.png")
        let tokens = OrbitNetworkLogic.parseFilterQuery("-domain:cdn.example.com")
        XCTAssertFalse(OrbitNetworkLogic.matchesFilter(r, tokens: tokens))
    }

    func testMatchesFilterStatusCode() {
        let r = makeRecord(url: "https://a.com/x", status: 404)
        XCTAssertTrue(OrbitNetworkLogic.matchesFilter(r, tokens: OrbitNetworkLogic.parseFilterQuery("status-code:404")))
        XCTAssertFalse(OrbitNetworkLogic.matchesFilter(r, tokens: OrbitNetworkLogic.parseFilterQuery("status-code:200")))
    }


    func testCurlBashGET() {
        let r = makeRecord(url: "https://api.example.com/data", requestHeaders: [
            OrbitHeader(name: "Accept", value: "application/json"),
            OrbitHeader(name: "Host", value: "api.example.com")
        ])
        let curl = OrbitNetworkLogic.curlBash(r)
        XCTAssertTrue(curl.hasPrefix("curl 'https://api.example.com/data'"))
        XCTAssertTrue(curl.contains("-H 'Accept: application/json'"))
        // Host header should be skipped
        XCTAssertFalse(curl.contains("Host:"))
    }

    func testCurlBashPOST() {
        var r = makeRecord(url: "https://api.example.com/submit")
        r.method = "POST"
        let curl = OrbitNetworkLogic.curlBash(r, body: "{\"x\":1}")
        XCTAssertTrue(curl.contains("-X 'POST'"))
        XCTAssertTrue(curl.contains("--data-raw '{\"x\":1}'"))
    }

    func testCurlBashQuoting() {
        // Shell quoting: single quotes, with ' → '\''
        let r = makeRecord(url: "https://example.com/it's%20here", requestHeaders: [
            OrbitHeader(name: "X-Token", value: "it's a 'test'")
        ])
        let curl = OrbitNetworkLogic.curlBash(r)
        // The URL and header value must be properly single-quoted
        XCTAssertTrue(curl.contains("'https://example.com/it"), "URL must be single-quoted")
        XCTAssertTrue(curl.contains("it'\\''s"), "Single quotes in header value must be escaped")
    }

    func testCurlWindows() {
        let r = makeRecord(url: "https://example.com/x", requestHeaders: [
            OrbitHeader(name: "X-Key", value: "val\"ue")
        ])
        let curl = OrbitNetworkLogic.curlWindows(r)
        XCTAssertTrue(curl.hasPrefix("curl.exe"), "Windows curl uses curl.exe")
        XCTAssertTrue(curl.contains("\"\""), "Inner double quotes must be doubled")
        XCTAssertTrue(curl.contains("^"), "Windows line continuation is ^")
    }

    func testFetchExpression() {
        var r = makeRecord(url: "https://api.example.com/items", requestHeaders: [
            OrbitHeader(name: "Authorization", value: "Bearer tok123")
        ])
        r.method = "DELETE"
        let expr = OrbitNetworkLogic.fetchExpression(r)
        XCTAssertTrue(expr.hasPrefix("fetch("))
        XCTAssertTrue(expr.contains("DELETE"))
        XCTAssertTrue(expr.contains("Authorization"))
        XCTAssertTrue(expr.contains("Bearer tok123"))
    }


    func testHarJSONStructure() {
        let r = makeRecord(url: "https://example.com/page", status: 200, requestHeaders: [
            OrbitHeader(name: "Accept", value: "*/*")
        ])
        let har = OrbitNetworkLogic.harJSON(records: [r], pageURL: "https://example.com", pageTitle: "Test")
        XCTAssertFalse(har.isEmpty)
        guard let data = har.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = obj["log"] as? [String: Any] else {
            XCTFail("HAR must be valid JSON with a .log key")
            return
        }
        XCTAssertEqual(log["version"] as? String, "1.2")
        let entries = log["entries"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.count, 1)
        let req = entries[0]["request"] as? [String: Any]
        XCTAssertEqual(req?["url"] as? String, "https://example.com/page")
        let resp = entries[0]["response"] as? [String: Any]
        XCTAssertEqual(resp?["status"] as? Int, 200)
    }

    func testHarQueryString() {
        let r = makeRecord(url: "https://example.com/search?q=hello&limit=10")
        let har = OrbitNetworkLogic.harJSON(records: [r], pageURL: "", pageTitle: "")
        guard let data = har.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = obj["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]],
              let req = entries.first?["request"] as? [String: Any],
              let qs = req["queryString"] as? [[String: String]] else {
            XCTFail("HAR must have queryString entries")
            return
        }
        XCTAssertEqual(qs.count, 2)
        XCTAssertTrue(qs.contains { $0["name"] == "q" && $0["value"] == "hello" })
    }


    func testParseCookieHeader() {
        let cookies = OrbitNetworkLogic.parseCookieHeader("session=abc123; user=jdoe; _ga=GA1.2.xyz")
        XCTAssertEqual(cookies.count, 3)
        XCTAssertEqual(cookies[0].name, "session")
        XCTAssertEqual(cookies[0].value, "abc123")
        XCTAssertEqual(cookies[1].name, "user")
        XCTAssertEqual(cookies[1].value, "jdoe")
    }

    func testParseCookieHeaderEmpty() {
        XCTAssertTrue(OrbitNetworkLogic.parseCookieHeader("").isEmpty)
    }

    func testParseSetCookieHeader() {
        let sc = OrbitNetworkLogic.parseSetCookieHeader(
            "token=abc; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=3600"
        )
        XCTAssertEqual(sc.name, "token")
        XCTAssertEqual(sc.value, "abc")
        XCTAssertEqual(sc.path, "/")
        XCTAssertTrue(sc.secure)
        XCTAssertTrue(sc.httpOnly)
        XCTAssertEqual(sc.sameSite, "Strict")
        XCTAssertEqual(sc.maxAge, 3600)
        XCTAssertTrue(sc.issues.isEmpty, "A properly set cookie must have no issues")
    }

    func testParseSetCookieIssues() {
        let sc = OrbitNetworkLogic.parseSetCookieHeader("name=value; Path=/")
        // Missing Secure, HttpOnly, SameSite
        XCTAssertEqual(sc.issues.count, 3)
    }


    func testSizeLabel() {
        let (xfer, res) = OrbitNetworkLogic.sizeLabel(transferSize: 1024, bodySize: 2048, fromCache: false)
        XCTAssertEqual(xfer, "1.0 KB")
        XCTAssertEqual(res, "2.0 KB")
    }

    func testSizeLabelMemoryCache() {
        let (xfer, _) = OrbitNetworkLogic.sizeLabel(transferSize: 0, bodySize: 512, fromCache: true, diskCache: false)
        XCTAssertEqual(xfer, "(memory cache)")
    }

    func testSizeLabelDiskCache() {
        let (xfer, _) = OrbitNetworkLogic.sizeLabel(transferSize: 0, bodySize: 512, fromCache: true, diskCache: true)
        XCTAssertEqual(xfer, "(disk cache)")
    }


    func testTimeRangeFilter() {
        var r1 = makeRecord(url: "https://a.com/1"); r1.startTime = 100
        var r2 = makeRecord(url: "https://a.com/2"); r2.startTime = 200
        var r3 = makeRecord(url: "https://a.com/3"); r3.startTime = 300

        let filtered = OrbitNetworkLogic.applyTimeRange([r1, r2, r3], range: 150...250)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].url, "https://a.com/2")
    }

    func testTimeRangeFilterNil() {
        var r1 = makeRecord(url: "https://a.com/1"); r1.startTime = 100
        var r2 = makeRecord(url: "https://a.com/2"); r2.startTime = 200
        let filtered = OrbitNetworkLogic.applyTimeRange([r1, r2], range: nil)
        XCTAssertEqual(filtered.count, 2)
    }

    func testTimeRangeFilterNoStartTime() {
        // Records without startTime are included (unknown timing = include)
        let r = makeRecord(url: "https://a.com/x")
        let filtered = OrbitNetworkLogic.applyTimeRange([r], range: 0...100)
        XCTAssertEqual(filtered.count, 1)
    }


    func testCanonicalTypesByMime() {
        XCTAssertEqual(OrbitNetworkLogic.canonicalType(resourceType: "other", mimeType: "text/javascript"), "script")
        XCTAssertEqual(OrbitNetworkLogic.canonicalType(resourceType: "other", mimeType: "text/css"), "stylesheet")
        XCTAssertEqual(OrbitNetworkLogic.canonicalType(resourceType: "other", mimeType: "image/png"), "image")
        XCTAssertEqual(OrbitNetworkLogic.canonicalType(resourceType: "other", mimeType: "video/mp4"), "media")
        XCTAssertEqual(OrbitNetworkLogic.canonicalType(resourceType: "other", mimeType: "font/woff2"), "font")
    }

    func testCanonicalTypesByResourceType() {
        XCTAssertEqual(OrbitNetworkLogic.canonicalType(resourceType: "main_frame", mimeType: ""), "document")
        XCTAssertEqual(OrbitNetworkLogic.canonicalType(resourceType: "fetch", mimeType: ""), "fetch")
        XCTAssertEqual(OrbitNetworkLogic.canonicalType(resourceType: "websocket", mimeType: ""), "websocket")
    }

    // MARK: - Status text

    func testStatusText200() {
        XCTAssertEqual(OrbitNetworkLogic.statusText(for: 200), "OK")
    }

    func testStatusText404() {
        XCTAssertEqual(OrbitNetworkLogic.statusText(for: 404), "Not Found")
    }

    func testStatusTextPending() {
        XCTAssertEqual(OrbitNetworkLogic.statusText(for: 0), "Pending")
    }

    // MARK: - Summary

    func testSummary() {
        var r1 = makeRecord(url: "https://a.com/x"); r1.transferSize = 1000; r1.startTime = 100; r1.duration = 50
        var r2 = makeRecord(url: "https://a.com/y"); r2.transferSize = 2000; r2.startTime = 120; r2.duration = 80

        let s = OrbitNetworkLogic.summary(all: [r1, r2], filtered: [r1, r2], dclMs: 150, loadMs: 200)
        XCTAssertEqual(s.totalRequests, 2)
        XCTAssertEqual(s.transferredBytes, 3000)
        XCTAssertEqual(s.dclMs, 150)
        XCTAssertEqual(s.loadMs, 200)
        // finish = max(end) - min(start) = max(200, 150) - 100 = 100
        XCTAssertEqual(s.finishMs ?? 0, 100, accuracy: 0.001)
    }

    // MARK: - Ring buffer

    private func ring(capacity: Int, appending ids: Range<Int>) -> OrbitRingBuffer<RingItem> {
        var buffer = OrbitRingBuffer<RingItem>(capacity: capacity)
        for n in ids { buffer.append(RingItem(id: "r\(n)", value: n)) }
        return buffer
    }

    func testRingBufferKeepsInsertionOrderBelowCapacity() {
        let buffer = ring(capacity: 5, appending: 0..<3)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.map(\.value), [0, 1, 2])
        XCTAssertEqual(buffer.first?.value, 0)
        XCTAssertEqual(buffer.last?.value, 2)
    }

    func testRingBufferEvictsOldestAtCapacityAndReturnsIt() {
        var buffer = ring(capacity: 3, appending: 0..<3)
        let evicted = buffer.append(RingItem(id: "r3", value: 3))
        XCTAssertEqual(evicted?.value, 0, "the oldest entry is the one dropped")
        XCTAssertEqual(buffer.count, 3, "the buffer never grows past its capacity")
        XCTAssertEqual(buffer.map(\.value), [1, 2, 3])
    }

    func testRingBufferAppendBelowCapacityEvictsNothing() {
        var buffer = OrbitRingBuffer<RingItem>(capacity: 3)
        XCTAssertNil(buffer.append(RingItem(id: "a", value: 1)))
    }

    func testRingBufferStaysOrderedAcrossManyWraps() {
        // 23 appends into 5 slots wraps the head four times; only the newest five survive, oldest first.
        let buffer = ring(capacity: 5, appending: 0..<23)
        XCTAssertEqual(buffer.map(\.value), [18, 19, 20, 21, 22])
        XCTAssertEqual(buffer[0].value, 18)
        XCTAssertEqual(buffer[4].value, 22)
    }

    func testRingBufferLookupByIDAfterWrap() {
        let buffer = ring(capacity: 4, appending: 0..<10)   // holds r6...r9
        XCTAssertNil(buffer.position(forID: "r0"), "an evicted id must not resolve")
        XCTAssertNil(buffer.position(forID: "r5"))
        XCTAssertEqual(buffer.position(forID: "r6"), 0)
        XCTAssertEqual(buffer.position(forID: "r9"), 3)
        XCTAssertEqual(buffer[id: "r7"]?.value, 7)
        XCTAssertNil(buffer[id: "missing"])
    }

    func testRingBufferLookupFollowsEntriesAsTheyShiftDown() {
        var buffer = ring(capacity: 3, appending: 0..<3)
        XCTAssertEqual(buffer.position(forID: "r2"), 2)
        buffer.append(RingItem(id: "r3", value: 3))
        XCTAssertEqual(buffer.position(forID: "r2"), 1, "an eviction moves every survivor down one place")
        XCTAssertEqual(buffer[id: "r2"]?.value, 2)
    }

    func testRingBufferSetByPositionAfterWrapChangesTheRightEntry() {
        var buffer = ring(capacity: 3, appending: 0..<5)    // r2, r3, r4
        buffer[0].value = 200
        XCTAssertEqual(buffer.map(\.value), [200, 3, 4])
        XCTAssertEqual(buffer[id: "r2"]?.value, 200)
    }

    func testRingBufferSetWithNewIDRekeysTheEntry() {
        var buffer = ring(capacity: 3, appending: 0..<3)
        buffer[1] = RingItem(id: "renamed", value: 1)
        XCTAssertNil(buffer.position(forID: "r1"), "the old id stops resolving")
        XCTAssertEqual(buffer.position(forID: "renamed"), 1)
    }

    func testRingBufferAliasResolvesUntilItsEntryIsEvicted() {
        var buffer = ring(capacity: 3, appending: 0..<3)
        buffer.alias("js-alias", toPosition: 0)             // second key for r0
        XCTAssertEqual(buffer[id: "js-alias"]?.value, 0)
        buffer.append(RingItem(id: "r3", value: 3))         // evicts r0
        XCTAssertNil(buffer[id: "js-alias"], "an alias must not outlive the entry it points at")
        XCTAssertNil(buffer[id: "r0"])
    }

    func testRingBufferAliasFollowsItsEntryAcrossEvictionsOfOthers() {
        var buffer = ring(capacity: 3, appending: 0..<3)
        buffer.alias("alias-r2", toPosition: 2)
        buffer.append(RingItem(id: "r3", value: 3))
        buffer.append(RingItem(id: "r4", value: 4))
        XCTAssertEqual(buffer[id: "alias-r2"]?.value, 2)
        XCTAssertEqual(buffer.position(forID: "alias-r2"), 0)
    }

    func testRingBufferRemoveAllInvalidatesOldIDsAndAcceptsNewOnes() {
        var buffer = ring(capacity: 3, appending: 0..<5)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.position(forID: "r4"), "ids from before the clear must not resolve")
        buffer.append(RingItem(id: "fresh", value: 9))
        XCTAssertEqual(buffer.map(\.value), [9])
        XCTAssertEqual(buffer.position(forID: "fresh"), 0)
    }

    func testRingBufferFilterPreservesOrderOnAWrappedBuffer() {
        let buffer = ring(capacity: 5, appending: 0..<12)   // 7...11
        XCTAssertEqual(buffer.filter { $0.value % 2 == 1 }.map(\.value), [7, 9, 11])
    }

    func testRingBufferManyStaleAliasesAreCompactedWithoutLosingLiveEntries() {
        var buffer = OrbitRingBuffer<RingItem>(capacity: 4)
        for n in 0..<400 {
            buffer.append(RingItem(id: "r\(n)", value: n))
            buffer.alias("alias\(n)", toPosition: buffer.count - 1)
        }
        XCTAssertEqual(buffer.map(\.value), [396, 397, 398, 399])
        XCTAssertEqual(buffer[id: "alias399"]?.value, 399)
        XCTAssertEqual(buffer[id: "r396"]?.value, 396)
        XCTAssertNil(buffer[id: "alias10"])
    }

    // MARK: - Helpers

    // OrbitNetworkRecord's optional properties have no `= nil` defaults, so the memberwise initializer needs them all.
    private func makeRecord(
        url: String,
        status: Int = 200,
        requestHeaders: [OrbitHeader] = [],
        responseHeaders: [OrbitHeader] = []
    ) -> OrbitNetworkRecord {
        var r = OrbitNetworkRecord(
            id: UUID().uuidString, url: url,
            transferSize: nil, bodySize: nil,
            startTime: nil, duration: nil,
            initiatorURL: nil, protocolName: nil)
        r.status = status
        r.requestHeaders = requestHeaders
        r.responseHeaders = responseHeaders
        return r
    }

    // MARK: - Cookie matching

    func test_cookieDomainMatches_onlyOnADotBoundary() {
        XCTAssertTrue(OrbitNetworkLogic.cookieDomainMatches(host: "example.com", cookieDomain: ".example.com"))
        XCTAssertTrue(OrbitNetworkLogic.cookieDomainMatches(host: "a.b.example.com", cookieDomain: ".example.com"))
        XCTAssertTrue(OrbitNetworkLogic.cookieDomainMatches(host: "WWW.Example.com", cookieDomain: "example.com"))
        XCTAssertFalse(OrbitNetworkLogic.cookieDomainMatches(host: "evilexample.com", cookieDomain: ".example.com"))
        XCTAssertFalse(OrbitNetworkLogic.cookieDomainMatches(host: "evilexample.com", cookieDomain: "example.com"))
        XCTAssertFalse(OrbitNetworkLogic.cookieDomainMatches(host: "example.com.evil.net", cookieDomain: ".example.com"))
        XCTAssertFalse(OrbitNetworkLogic.cookieDomainMatches(host: "example.com", cookieDomain: "."))
    }

    func test_cookiePathMatches_onlyOnASlashBoundary() {
        XCTAssertTrue(OrbitNetworkLogic.cookiePathMatches(requestPath: "/", cookiePath: "/"))
        XCTAssertTrue(OrbitNetworkLogic.cookiePathMatches(requestPath: "/docs/a", cookiePath: "/docs"))
        XCTAssertTrue(OrbitNetworkLogic.cookiePathMatches(requestPath: "/docs/a", cookiePath: "/docs/"))
        XCTAssertTrue(OrbitNetworkLogic.cookiePathMatches(requestPath: "/docs", cookiePath: "/docs"))
        XCTAssertFalse(OrbitNetworkLogic.cookiePathMatches(requestPath: "/docsearch", cookiePath: "/docs"))
        XCTAssertFalse(OrbitNetworkLogic.cookiePathMatches(requestPath: "/other", cookiePath: "/docs"))
    }
}

private struct RingItem: Identifiable, Equatable {
    var id: String
    var value: Int
}
