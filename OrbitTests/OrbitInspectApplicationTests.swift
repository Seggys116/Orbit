import XCTest
import Foundation

// OrbitInspectApplicationLogic.swift and OrbitInspectDecode.swift are compiled directly into this bundle, so no @testable import.

final class OrbitInspectApplicationTests: XCTestCase {

    // MARK: - Cookie record from HTTPCookie

    func testCookieRecord_nameValue() {
        let cookie = makeCookie(name: "session", value: "abc123", domain: "example.com", path: "/")
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertEqual(record.name, "session")
        XCTAssertEqual(record.value, "abc123")
    }

    func testCookieRecord_id_encodesDomainAndPath() {
        let cookie = makeCookie(name: "foo", value: "bar", domain: ".example.com", path: "/app")
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertEqual(record.id, "foo|.example.com|/app")
    }

    func testCookieRecord_sessionCookie_nilExpiresDate() {
        let cookie = makeCookie(name: "temp", value: "1", domain: "x.com", path: "/")
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertTrue(record.isSession)
        XCTAssertNil(record.expiresDate)
    }

    func testCookieRecord_persistentCookie_hasExpiresDate() {
        let future = Date(timeIntervalSinceNow: 86400)
        let cookie = makeCookie(name: "pref", value: "1", domain: "x.com", path: "/", expires: future)
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertFalse(record.isSession)
        XCTAssertNotNil(record.expiresDate)
    }

    func testCookieRecord_secure() {
        let cookie = makeCookie(name: "s", value: "v", domain: "x.com", path: "/", secure: true)
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertTrue(record.isSecure)
    }

    func testCookieRecord_sameSiteLax() {
        let cookie = makeCookie(name: "s", value: "v", domain: "x.com", path: "/",
                                sameSite: HTTPCookieStringPolicy.sameSiteLax)
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertEqual(record.sameSite, "Lax")
    }

    func testCookieRecord_sameSiteStrict() {
        let cookie = makeCookie(name: "s", value: "v", domain: "x.com", path: "/",
                                sameSite: HTTPCookieStringPolicy.sameSiteStrict)
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertEqual(record.sameSite, "Strict")
    }

    func testCookieRecord_noSameSite_emptyString() {
        let cookie = makeCookie(name: "s", value: "v", domain: "x.com", path: "/")
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertEqual(record.sameSite, "")
    }

    func testCookieRecord_httpOnly() {
        // When creating via properties, isHTTPOnly depends on the Foundation implementation, so only readability is checked.
        let cookie = makeCookie(name: "h", value: "v", domain: "x.com", path: "/")
        let record = OrbitApplicationLogic.cookieRecord(from: cookie)
        XCTAssertEqual(record.isHTTPOnly, cookie.isHTTPOnly)
    }

    // MARK: - HTTPCookie from CookieRecord (round-trip)

    func testHTTPCookieFromRecord_roundtrips_nameValue() {
        let record = OrbitApplicationLogic.CookieRecord(
            id: "x", name: "myname", value: "myvalue",
            domain: ".example.com", path: "/page",
            expiresDate: nil, isHTTPOnly: false, isSecure: false,
            sameSite: "", partitionKey: "", priority: "")
        let cookie = OrbitApplicationLogic.httpCookie(from: record)
        XCTAssertEqual(cookie?.name, "myname")
        XCTAssertEqual(cookie?.value, "myvalue")
        XCTAssertEqual(cookie?.domain, ".example.com")
        XCTAssertEqual(cookie?.path, "/page")
    }

    func testHTTPCookieFromRecord_secure() {
        let record = OrbitApplicationLogic.CookieRecord(
            id: "", name: "s", value: "v", domain: "x.com", path: "/",
            expiresDate: nil, isHTTPOnly: false, isSecure: true,
            sameSite: "", partitionKey: "", priority: "")
        let cookie = OrbitApplicationLogic.httpCookie(from: record)
        XCTAssertEqual(cookie?.isSecure, true)
    }

    func testHTTPCookieFromRecord_expires() {
        let future = Date(timeIntervalSinceNow: 3600)
        let record = OrbitApplicationLogic.CookieRecord(
            id: "", name: "e", value: "v", domain: "x.com", path: "/",
            expiresDate: future, isHTTPOnly: false, isSecure: false,
            sameSite: "", partitionKey: "", priority: "")
        let cookie = OrbitApplicationLogic.httpCookie(from: record)
        XCTAssertNotNil(cookie?.expiresDate)
        XCTAssertFalse(cookie?.isSessionOnly == true)
    }

    func testHTTPCookieFromRecord_sameSiteLax() {
        let record = OrbitApplicationLogic.CookieRecord(
            id: "", name: "s", value: "v", domain: "x.com", path: "/",
            expiresDate: nil, isHTTPOnly: false, isSecure: false,
            sameSite: "Lax", partitionKey: "", priority: "")
        let cookie = OrbitApplicationLogic.httpCookie(from: record)
        XCTAssertEqual(cookie?.sameSitePolicy, .sameSiteLax)
    }

    func testHTTPCookieFromRecord_sameSiteStrict() {
        let record = OrbitApplicationLogic.CookieRecord(
            id: "", name: "s", value: "v", domain: "x.com", path: "/",
            expiresDate: nil, isHTTPOnly: false, isSecure: false,
            sameSite: "Strict", partitionKey: "", priority: "")
        let cookie = OrbitApplicationLogic.httpCookie(from: record)
        XCTAssertEqual(cookie?.sameSitePolicy, .sameSiteStrict)
    }

    // MARK: - Cookie URL matching

    func testCookieMatches_exactDomain() {
        let record = cookieRecord(domain: "example.com", path: "/", secure: false)
        let url = URL(string: "http://example.com/page")!
        XCTAssertTrue(OrbitApplicationLogic.cookie(record, matchesURL: url))
    }

    func testCookieMatches_dotPrefixedDomain_matchesSubdomain() {
        let record = cookieRecord(domain: ".example.com", path: "/", secure: false)
        let url = URL(string: "http://sub.example.com/")!
        XCTAssertTrue(OrbitApplicationLogic.cookie(record, matchesURL: url))
    }

    func testCookieMatches_dotPrefixedDomain_matchesApex() {
        let record = cookieRecord(domain: ".example.com", path: "/", secure: false)
        let url = URL(string: "http://example.com/")!
        XCTAssertTrue(OrbitApplicationLogic.cookie(record, matchesURL: url))
    }

    func testCookieMatches_differentDomain_fails() {
        let record = cookieRecord(domain: "example.com", path: "/", secure: false)
        let url = URL(string: "http://other.com/")!
        XCTAssertFalse(OrbitApplicationLogic.cookie(record, matchesURL: url))
    }

    func testCookieMatches_secureCookieOnHTTP_fails() {
        let record = cookieRecord(domain: "example.com", path: "/", secure: true)
        let url = URL(string: "http://example.com/")!
        XCTAssertFalse(OrbitApplicationLogic.cookie(record, matchesURL: url))
    }

    func testCookieMatches_secureCookieOnHTTPS_succeeds() {
        let record = cookieRecord(domain: "example.com", path: "/", secure: true)
        let url = URL(string: "https://example.com/")!
        XCTAssertTrue(OrbitApplicationLogic.cookie(record, matchesURL: url))
    }

    func testCookieMatches_pathPrefix() {
        let record = cookieRecord(domain: "example.com", path: "/app", secure: false)
        let url = URL(string: "http://example.com/app/page")!
        XCTAssertTrue(OrbitApplicationLogic.cookie(record, matchesURL: url))
    }

    func testCookieMatches_pathMismatch_fails() {
        let record = cookieRecord(domain: "example.com", path: "/admin", secure: false)
        let url = URL(string: "http://example.com/user")!
        XCTAssertFalse(OrbitApplicationLogic.cookie(record, matchesURL: url))
    }

    // MARK: - Value kind detection

    func testDetectValueKind_jsonObject() {
        XCTAssertEqual(OrbitApplicationLogic.detectValueKind("{\"key\":\"value\"}"), .json)
    }

    func testDetectValueKind_jsonArray() {
        XCTAssertEqual(OrbitApplicationLogic.detectValueKind("[1,2,3]"), .json)
    }

    func testDetectValueKind_urlEncoded() {
        XCTAssertEqual(OrbitApplicationLogic.detectValueKind("hello%20world"), .urlEncoded)
    }

    func testDetectValueKind_plainText() {
        XCTAssertEqual(OrbitApplicationLogic.detectValueKind("hello world"), .plainText)
    }

    func testDetectValueKind_emptyString_plainText() {
        XCTAssertEqual(OrbitApplicationLogic.detectValueKind(""), .plainText)
    }

    func testDetectValueKind_base64() {
        // "Hello, World!" in base64 is "SGVsbG8sIFdvcmxkIQ=="
        let b64 = "SGVsbG8sIFdvcmxkIQ=="
        XCTAssertEqual(OrbitApplicationLogic.detectValueKind(b64), .base64)
    }


    func testPrettyJSON_validJSON() {
        let pretty = OrbitApplicationLogic.prettyJSON("{\"a\":1}")
        XCTAssertNotNil(pretty)
        XCTAssertTrue(pretty!.contains("\"a\""))
    }

    func testPrettyJSON_invalidJSON_returnsNil() {
        XCTAssertNil(OrbitApplicationLogic.prettyJSON("not json"))
    }


    func testURLDecoded_decodesPercentEncoding() {
        XCTAssertEqual(OrbitApplicationLogic.urlDecoded("hello%20world"), "hello world")
    }

    func testURLDecoded_decodesPlus() {
        XCTAssertEqual(OrbitApplicationLogic.urlDecoded("hello+world"), "hello world")
    }


    func testStorageEntry_sizeIsKeyPlusValue() {
        let entry = OrbitApplicationLogic.StorageEntry(key: "abc", value: "xyz")
        XCTAssertEqual(entry.size, 6)  // "abc".utf8.count + "xyz".utf8.count
    }

    // MARK: - Quota formatting

    func testFormatBytes_lessThan1KB() {
        XCTAssertEqual(OrbitApplicationLogic.formatBytes(512), "512 B")
    }

    func testFormatBytes_kilobytes() {
        let result = OrbitApplicationLogic.formatBytes(2048)
        XCTAssertTrue(result.contains("KB"), "Expected KB, got \(result)")
    }

    func testFormatBytes_megabytes() {
        let result = OrbitApplicationLogic.formatBytes(2 * 1024 * 1024)
        XCTAssertTrue(result.contains("MB"), "Expected MB, got \(result)")
    }

    func testQuotaFraction_normal() {
        XCTAssertEqual(OrbitApplicationLogic.quotaFraction(usage: 50, quota: 100), 0.5, accuracy: 0.001)
    }

    func testQuotaFraction_zeroQuota_returnsZero() {
        XCTAssertEqual(OrbitApplicationLogic.quotaFraction(usage: 100, quota: 0), 0)
    }

    func testQuotaFraction_overQuota_clampedToOne() {
        XCTAssertEqual(OrbitApplicationLogic.quotaFraction(usage: 200, quota: 100), 1.0, accuracy: 0.001)
    }

    // MARK: - IDB key range parsing

    func testParseIDBKeyRange_emptyString_emptyRange() {
        let range = OrbitApplicationLogic.parseIDBKeyRange("")
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.isEmpty)
    }

    func testParseIDBKeyRange_singleValue_lowerBound() {
        let range = OrbitApplicationLogic.parseIDBKeyRange("alpha")
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.lower, .string("alpha"))
        if case .none = range!.upper { } else { XCTFail("Expected no upper bound") }
    }

    func testParseIDBKeyRange_rangeSyntax() {
        let range = OrbitApplicationLogic.parseIDBKeyRange("a .. z")
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.lower, .string("a"))
        XCTAssertEqual(range!.upper, .string("z"))
    }

    func testIDBKeyRangeJS_emptyRange_returnsNull() {
        let range = OrbitApplicationLogic.IDBKeyRange()
        XCTAssertEqual(OrbitApplicationLogic.idbKeyRangeJS(range), "null")
    }

    func testIDBKeyRangeJS_lowerBound() {
        var range = OrbitApplicationLogic.IDBKeyRange()
        range.lower = .string("foo")
        let js = OrbitApplicationLogic.idbKeyRangeJS(range)
        XCTAssertTrue(js.hasPrefix("IDBKeyRange.lowerBound"), "Got: \(js)")
        XCTAssertTrue(js.contains("\"foo\""))
    }

    func testIDBKeyRangeJS_numberBound() {
        var range = OrbitApplicationLogic.IDBKeyRange()
        range.lower = .number(42)
        let js = OrbitApplicationLogic.idbKeyRangeJS(range)
        XCTAssertTrue(js.contains("42"), "Got: \(js)")
    }

    func testIDBKeyRangeJS_boundRange() {
        var range = OrbitApplicationLogic.IDBKeyRange()
        range.lower = .string("a")
        range.upper = .string("z")
        let js = OrbitApplicationLogic.idbKeyRangeJS(range)
        XCTAssertTrue(js.hasPrefix("IDBKeyRange.bound"), "Got: \(js)")
        XCTAssertTrue(js.contains("\"a\""))
        XCTAssertTrue(js.contains("\"z\""))
    }

    // MARK: - Manifest parsing

    func testParseManifest_allFields() {
        let json = """
        {
          "name": "My App",
          "short_name": "App",
          "start_url": "/",
          "scope": "/",
          "display": "standalone",
          "theme_color": "#ffffff",
          "background_color": "#000000",
          "icons": [
            { "src": "icon-192.png", "sizes": "192x192", "type": "image/png" },
            { "src": "icon-512.png", "sizes": "512x512", "type": "image/png" }
          ],
          "shortcuts": [{ "name": "Open", "url": "/open" }]
        }
        """
        let manifest = OrbitApplicationLogic.parseManifest(json)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest!.name, "My App")
        XCTAssertEqual(manifest!.shortName, "App")
        XCTAssertEqual(manifest!.display, "standalone")
        XCTAssertEqual(manifest!.themeColor, "#ffffff")
        XCTAssertEqual(manifest!.icons.count, 2)
        XCTAssertEqual(manifest!.shortcuts.count, 1)
    }

    func testParseManifest_invalidJSON_returnsNil() {
        XCTAssertNil(OrbitApplicationLogic.parseManifest("not json"))
    }

    // MARK: - Installability checks

    func testInstallabilityChecks_allPass() {
        let manifest = OrbitApplicationLogic.ManifestData(
            name: "My App", shortName: "App", startURL: "/",
            scope: "/", display: "standalone",
            themeColor: "", backgroundColor: "",
            icons: [
                OrbitApplicationLogic.ManifestIcon(src: "a.png", sizes: "192x192", type: "image/png", purpose: "any"),
                OrbitApplicationLogic.ManifestIcon(src: "b.png", sizes: "512x512", type: "image/png", purpose: "any"),
            ],
            shortcuts: [], rawJSON: "{}")
        let checks = OrbitApplicationLogic.installabilityChecks(for: manifest)
        XCTAssertTrue(checks.allSatisfy { $0.pass }, "All checks should pass")
    }

    func testInstallabilityChecks_missingName_fails() {
        let manifest = OrbitApplicationLogic.ManifestData(
            name: "", shortName: "", startURL: "/",
            scope: "/", display: "standalone",
            themeColor: "", backgroundColor: "",
            icons: [], shortcuts: [], rawJSON: "{}")
        let checks = OrbitApplicationLogic.installabilityChecks(for: manifest)
        let nameCheck = checks.first { $0.label.contains("name") }
        XCTAssertNotNil(nameCheck)
        XCTAssertFalse(nameCheck!.pass)
    }

    func testInstallabilityChecks_missing192Icon_fails() {
        let manifest = OrbitApplicationLogic.ManifestData(
            name: "App", shortName: "", startURL: "/",
            scope: "/", display: "standalone",
            themeColor: "", backgroundColor: "",
            icons: [OrbitApplicationLogic.ManifestIcon(src: "a.png", sizes: "512x512", type: "image/png", purpose: "any")],
            shortcuts: [], rawJSON: "{}")
        let checks = OrbitApplicationLogic.installabilityChecks(for: manifest)
        let check192 = checks.first { $0.label.contains("192") }
        XCTAssertFalse(check192?.pass ?? true)
    }

    func testInstallabilityChecks_invalidDisplay_fails() {
        let manifest = OrbitApplicationLogic.ManifestData(
            name: "App", shortName: "", startURL: "/",
            scope: "/", display: "browser",
            themeColor: "", backgroundColor: "",
            icons: [], shortcuts: [], rawJSON: "{}")
        let checks = OrbitApplicationLogic.installabilityChecks(for: manifest)
        let displayCheck = checks.first { $0.label.contains("display") }
        XCTAssertFalse(displayCheck?.pass ?? true)
    }

    // MARK: - Storage diff

    func testDiffStorage_noChange_returnsUnchanged() {
        let entries = [OrbitApplicationLogic.StorageEntry(key: "a", value: "1")]
        let (_, changed) = OrbitApplicationLogic.diffStorage(old: entries, new: entries)
        XCTAssertFalse(changed)
    }

    func testDiffStorage_newEntry_returnsChanged() {
        let old = [OrbitApplicationLogic.StorageEntry(key: "a", value: "1")]
        let new = [OrbitApplicationLogic.StorageEntry(key: "a", value: "1"),
                   OrbitApplicationLogic.StorageEntry(key: "b", value: "2")]
        let (result, changed) = OrbitApplicationLogic.diffStorage(old: old, new: new)
        XCTAssertTrue(changed)
        XCTAssertEqual(result.count, 2)
    }

    func testDiffStorage_changedValue_returnsChanged() {
        let old = [OrbitApplicationLogic.StorageEntry(key: "a", value: "1")]
        let new = [OrbitApplicationLogic.StorageEntry(key: "a", value: "2")]
        let (_, changed) = OrbitApplicationLogic.diffStorage(old: old, new: new)
        XCTAssertTrue(changed)
    }

    // MARK: - Cookie expiry formatting

    func testFormatCookieExpiry_nil_returnsSession() {
        XCTAssertEqual(OrbitApplicationLogic.formatCookieExpiry(nil), "Session")
    }

    func testFormatCookieExpiry_pastDate_returnsExpired() {
        let past = Date(timeIntervalSinceNow: -100)
        XCTAssertEqual(OrbitApplicationLogic.formatCookieExpiry(past), "Expired")
    }

    func testFormatCookieExpiry_futureDate_returnsFormattedDate() {
        let future = Date(timeIntervalSinceNow: 86400)
        let result = OrbitApplicationLogic.formatCookieExpiry(future)
        XCTAssertNotEqual(result, "Session")
        XCTAssertNotEqual(result, "Expired")
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Registrable domain

    func testRegistrableDomain_twoPartHost() {
        XCTAssertEqual(OrbitApplicationLogic.registrableDomain(of: "example.com"), "example.com")
    }

    func testRegistrableDomain_subdomain() {
        XCTAssertEqual(OrbitApplicationLogic.registrableDomain(of: "sub.example.com"), "example.com")
    }

    func testRegistrableDomain_deepSubdomain() {
        XCTAssertEqual(OrbitApplicationLogic.registrableDomain(of: "a.b.c.example.com"), "example.com")
    }

    // MARK: - Helpers

    private func makeCookie(
        name: String, value: String, domain: String, path: String,
        expires: Date? = nil, secure: Bool = false,
        sameSite: HTTPCookieStringPolicy? = nil
    ) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if secure { props[.secure] = "TRUE" }
        if let expires { props[.expires] = expires }
        if let sameSite { props[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: props)!
    }

    private func cookieRecord(domain: String, path: String, secure: Bool) -> OrbitApplicationLogic.CookieRecord {
        OrbitApplicationLogic.CookieRecord(
            id: "test|\(domain)|\(path)",
            name: "test", value: "value",
            domain: domain, path: path,
            expiresDate: nil, isHTTPOnly: false, isSecure: secure,
            sameSite: "", partitionKey: "", priority: "")
    }
}
