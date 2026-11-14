// Unit tests for OrbitSecurityLogic; its source and OrbitInspectApplicationLogic.swift and OrbitInspectDecode.swift are compiled directly.

import XCTest

final class OrbitInspectSecurityTests: XCTestCase {

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // fixed so expiry maths never depends on the clock
    private let day: TimeInterval = 86_400

    private func certificate(
        subject: String = "example.com", issuer: String = "Example CA",
        daysValid: Double = 90, daysAgoIssued: Double = 10,
        names: [String] = ["example.com", "www.example.com"],
        keyType: String? = "EC", bits: Int? = 256, signature: String? = "SHA-256 with ECDSA"
    ) -> OrbitSecurityCertificate {
        OrbitSecurityCertificate(
            subject: subject, issuer: issuer,
            notBefore: now.addingTimeInterval(-daysAgoIssued * day),
            notAfter: now.addingTimeInterval(daysValid * day),
            serialNumber: "0A:0B", subjectAlternativeNames: names,
            keyType: keyType, keySizeBits: bits, signatureAlgorithm: signature
        )
    }

    private let goodHeaders: [String: String] = [
        "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
        "content-security-policy": "default-src 'none'; script-src 'self' 'nonce-abc'; base-uri 'none'; frame-ancestors 'none'; object-src 'none'",
        "x-content-type-options": "nosniff",
        "referrer-policy": "strict-origin-when-cross-origin",
        "cross-origin-opener-policy": "same-origin",
        "cross-origin-embedder-policy": "require-corp",
        "cross-origin-resource-policy": "same-origin",
        "permissions-policy": "camera=(), microphone=(), geolocation=()",
    ]

    private func input(
        url: String = "https://example.com/", headers: [String: String]? = nil,
        certs: [OrbitSecurityCertificate]? = nil, trust: OrbitSecurityTrust = .trusted
    ) -> OrbitSecurityInput {
        var value = OrbitSecurityInput()
        value.pageURL = url
        value.now = now
        value.documentHeaders = headers
        value.certificates = certs ?? (url.hasPrefix("https") ? [certificate()] : [])
        value.trust = url.hasPrefix("https") ? trust : .unavailable
        value.hasOnlySecureContent = true
        return value
    }

    private func check(_ id: String, _ report: OrbitSecurityReport) -> OrbitSecurityCheck {
        guard let found = report.checks.first(where: { $0.id == id }) else {
            XCTFail("no check named \(id)")
            return OrbitSecurityCheck(id: id, section: .headers, title: "", state: .info, value: nil, summary: "", advice: "", weight: 0)
        }
        return found
    }

    private func cookie(
        _ name: String, domain: String = "example.com", path: String = "/",
        secure: Bool = true, httpOnly: Bool = true, sameSite: String = "Lax"
    ) -> OrbitApplicationLogic.CookieRecord {
        OrbitApplicationLogic.CookieRecord(
            id: "\(name)|\(domain)|\(path)", name: name, value: "v", domain: domain, path: path,
            expiresDate: nil, isHTTPOnly: httpOnly, isSecure: secure, sameSite: sameSite,
            partitionKey: "", priority: ""
        )
    }

    private func findings(_ text: String, reportOnly: Bool = false) -> [OrbitSecurityCSPFinding] {
        OrbitSecurityLogic.gradeCSP(OrbitSecurityLogic.parseCSP(text, reportOnly: reportOnly))
    }

    // MARK: - CSP parsing

    func testParseCSP_splitsDirectivesAndLowercasesNames() {
        let policies = OrbitSecurityLogic.parseCSP("Default-Src 'self' https:; IMG-SRC data:", reportOnly: false)
        XCTAssertEqual(policies.count, 1)
        XCTAssertEqual(policies[0].values(for: "default-src"), ["'self'", "https:"])
        XCTAssertEqual(policies[0].values(for: "img-src"), ["data:"])
    }

    func testParseCSP_firstDuplicateDirectiveWins() {
        let policy = OrbitSecurityLogic.parseCSP("script-src 'self'; script-src *", reportOnly: false)[0]
        XCTAssertEqual(policy.values(for: "script-src"), ["'self'"])
    }

    func testParseCSP_commaSeparatesPolicies() {
        let policies = OrbitSecurityLogic.parseCSP("script-src 'self', object-src 'none'", reportOnly: false)
        XCTAssertEqual(policies.count, 2)
    }

    func testParseCSP_effectiveValuesFallBackToDefaultSrc() {
        let policy = OrbitSecurityLogic.parseCSP("default-src 'self'; img-src *", reportOnly: false)[0]
        XCTAssertEqual(policy.effectiveValues(for: "script-src"), ["'self'"])
        XCTAssertEqual(policy.effectiveValues(for: "img-src"), ["*"])
    }

    // MARK: - CSP grading

    func testGradeCSP_missingPolicyFails() {
        let result = OrbitSecurityLogic.gradeCSP([])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].state, .fail)
    }

    func testGradeCSP_unsafeInlineScriptFails() {
        let result = findings("script-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'")
        XCTAssertTrue(result.contains { $0.directive == "script-src" && $0.state == .fail && $0.message.contains("unsafe-inline") })
    }

    func testGradeCSP_nonceMakesUnsafeInlineHarmless() {
        let result = findings("script-src 'nonce-abc' 'unsafe-inline'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'")
        XCTAssertTrue(result.isEmpty, "got \(result)")
    }

    func testGradeCSP_unsafeEvalWarns() {
        let result = findings("script-src 'self' 'unsafe-eval'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'")
        XCTAssertEqual(result.map(\.state), [.warn])
        XCTAssertTrue(result[0].message.contains("unsafe-eval"))
    }

    func testGradeCSP_wildcardScriptSourceFails() {
        let result = findings("script-src *; object-src 'none'; base-uri 'self'; frame-ancestors 'self'")
        XCTAssertTrue(result.contains { $0.state == .fail && $0.message.contains("wildcard") })
    }

    func testGradeCSP_schemeSourcesFailForScripts() {
        let result = findings("script-src https: data:; object-src 'none'; base-uri 'self'; frame-ancestors 'self'")
        XCTAssertEqual(result.filter { $0.state == .fail }.count, 2)
    }

    func testGradeCSP_wildcardHostWarns() {
        let result = findings("script-src 'self' *.cdn.example; object-src 'none'; base-uri 'self'; frame-ancestors 'self'")
        XCTAssertEqual(result.map(\.state), [.warn])
    }

    func testGradeCSP_defaultSrcCoversScriptsAndObjects() {
        let result = findings("default-src 'self'; base-uri 'self'; frame-ancestors 'self'")
        XCTAssertTrue(result.isEmpty, "got \(result)")
    }

    func testGradeCSP_missingObjectBaseAndFrameAncestorsWarn() {
        let result = findings("script-src 'self'")
        XCTAssertEqual(Set(result.map(\.directive)), ["object-src", "base-uri", "frame-ancestors"])
        XCTAssertTrue(result.allSatisfy { $0.state == .warn })
    }

    func testGradeCSP_noScriptSourceAtAllFails() {
        let result = findings("img-src 'self'")
        XCTAssertTrue(result.contains { $0.directive == "script-src" && $0.state == .fail })
    }

    func testGradeCSP_strictPolicyHasNoFindings() {
        let result = findings("default-src 'none'; script-src 'self' 'nonce-abc'; base-uri 'none'; frame-ancestors 'none'; object-src 'none'")
        XCTAssertTrue(result.isEmpty, "got \(result)")
    }

    func testGradeCSP_reportOnlyIsNeverAPass() {
        let result = findings("default-src 'self'; base-uri 'self'; frame-ancestors 'self'", reportOnly: true)
        XCTAssertEqual(result.first?.state, .warn)
        XCTAssertTrue(result.first?.message.contains("report-only") == true)
    }

    func testGradeCSP_secondEnforcedPolicyResolvesFindings() {
        let loose = OrbitSecurityLogic.parseCSP("script-src 'self' 'unsafe-inline'", reportOnly: false)
        let tight = OrbitSecurityLogic.parseCSP("script-src 'self' 'nonce-abc'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'", reportOnly: false)
        let combined = OrbitSecurityLogic.gradeCSP(loose + tight)
        XCTAssertTrue(combined.isEmpty, "got \(combined)")
    }

    func testGradeCSP_metaPolicyExplainsFrameAncestors() {
        let policy = OrbitSecurityLogic.parseCSP("default-src 'self'; base-uri 'self'", reportOnly: false, fromMeta: true)
        let result = OrbitSecurityLogic.gradeCSP(policy)
        XCTAssertTrue(result.contains { $0.directive == "frame-ancestors" && $0.message.contains("Meta policies") })
    }

    // MARK: - HSTS

    func testParseHSTS_readsAllDirectives() {
        let value = OrbitSecurityLogic.parseHSTS("max-age=31536000; includeSubDomains; preload")
        XCTAssertEqual(value, OrbitSecurityHSTS(maxAge: 31_536_000, includeSubDomains: true, preload: true))
    }

    func testParseHSTS_isCaseInsensitiveAndToleratesQuotes() {
        let value = OrbitSecurityLogic.parseHSTS("Max-Age=\"600\"; IncludeSubdomains")
        XCTAssertEqual(value, OrbitSecurityHSTS(maxAge: 600, includeSubDomains: true, preload: false))
    }

    func testHSTS_strongPolicyPasses() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        XCTAssertEqual(check("hsts", report).state, .pass)
    }

    func testHSTS_missingFails() {
        var headers = goodHeaders
        headers.removeValue(forKey: "strict-transport-security")
        let report = OrbitSecurityLogic.evaluate(input(headers: headers))
        XCTAssertEqual(check("hsts", report).state, .fail)
    }

    func testHSTS_shortMaxAgeWarns() {
        var headers = goodHeaders
        headers["strict-transport-security"] = "max-age=3600; includeSubDomains"
        XCTAssertEqual(check("hsts", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .warn)
    }

    func testHSTS_zeroMaxAgeFails() {
        var headers = goodHeaders
        headers["strict-transport-security"] = "max-age=0"
        XCTAssertEqual(check("hsts", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .fail)
    }

    func testHSTS_withoutIncludeSubDomainsWarns() {
        var headers = goodHeaders
        headers["strict-transport-security"] = "max-age=31536000"
        XCTAssertEqual(check("hsts", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .warn)
    }

    func testHSTS_isNotGradedOnHTTP() {
        let report = OrbitSecurityLogic.evaluate(input(url: "http://example.com/", headers: [:]))
        XCTAssertEqual(check("hsts", report).state, .info)
    }

    func testHSTS_valueIsShownVerbatim() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        XCTAssertEqual(check("hsts", report).value, "max-age=63072000; includeSubDomains; preload")
    }

    // MARK: - Other headers

    func testAllGoodHeadersPass() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        for id in ["hsts", "csp", "xcto", "clickjacking", "referrer", "coop", "coep", "corp", "permissions"] {
            XCTAssertEqual(check(id, report).state, .pass, id)
        }
    }

    func testNoSniff_missingAndWrongValuesFail() {
        var headers = goodHeaders
        headers.removeValue(forKey: "x-content-type-options")
        XCTAssertEqual(check("xcto", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .fail)
        headers["x-content-type-options"] = "sniff"
        XCTAssertEqual(check("xcto", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .fail)
    }

    func testClickjacking_xFrameOptionsAloneIsEnough() {
        var headers = goodHeaders
        headers["content-security-policy"] = "default-src 'self'"
        headers["x-frame-options"] = "DENY"
        XCTAssertEqual(check("clickjacking", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .pass)
    }

    func testClickjacking_neitherHeaderFails() {
        var headers = goodHeaders
        headers["content-security-policy"] = "default-src 'self'"
        XCTAssertEqual(check("clickjacking", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .fail)
    }

    func testClickjacking_allowFromWarnsAndWildcardAncestorsFail() {
        var headers = goodHeaders
        headers["content-security-policy"] = "default-src 'self'"
        headers["x-frame-options"] = "ALLOW-FROM https://a.example"
        XCTAssertEqual(check("clickjacking", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .warn)
        headers["content-security-policy"] = "default-src 'self'; frame-ancestors *"
        XCTAssertEqual(check("clickjacking", OrbitSecurityLogic.evaluate(input(headers: headers))).state, .fail)
    }

    func testClickjacking_metaCSPFrameAncestorsDoesNotCount() {
        var headers = goodHeaders
        headers.removeValue(forKey: "content-security-policy")
        var value = input(headers: headers)
        value.metaCSP = ["default-src 'self'; frame-ancestors 'none'"]
        XCTAssertEqual(check("clickjacking", OrbitSecurityLogic.evaluate(value)).state, .fail)
    }

    func testReferrerPolicy_grades() {
        func state(_ policy: String?) -> OrbitSecurityState {
            var headers = goodHeaders
            if let policy { headers["referrer-policy"] = policy } else { headers.removeValue(forKey: "referrer-policy") }
            return check("referrer", OrbitSecurityLogic.evaluate(input(headers: headers))).state
        }
        XCTAssertEqual(state("no-referrer"), .pass)
        XCTAssertEqual(state("same-origin"), .pass)
        XCTAssertEqual(state("strict-origin-when-cross-origin"), .pass)
        XCTAssertEqual(state("unsafe-url"), .fail)
        XCTAssertEqual(state("no-referrer-when-downgrade"), .warn)
        XCTAssertEqual(state("bogus"), .warn)
        XCTAssertEqual(state(nil), .warn)
        // The last recognised token is the one that applies.
        XCTAssertEqual(state("unsafe-url, no-referrer"), .pass)
    }

    func testReferrerPolicy_metaTagCounts() {
        var value = input(headers: [:])
        value.metaReferrer = "no-referrer"
        XCTAssertEqual(check("referrer", OrbitSecurityLogic.evaluate(value)).state, .pass)
    }

    func testCrossOriginPolicies_grades() {
        var headers = goodHeaders
        headers["cross-origin-opener-policy"] = "unsafe-none"
        headers["cross-origin-embedder-policy"] = "unsafe-none"
        headers["cross-origin-resource-policy"] = "cross-origin"
        let report = OrbitSecurityLogic.evaluate(input(headers: headers))
        XCTAssertEqual(check("coop", report).state, .warn)
        XCTAssertEqual(check("coep", report).state, .warn)
        XCTAssertEqual(check("corp", report).state, .info)

        headers.removeValue(forKey: "cross-origin-opener-policy")
        headers.removeValue(forKey: "cross-origin-embedder-policy")
        headers.removeValue(forKey: "cross-origin-resource-policy")
        let missing = OrbitSecurityLogic.evaluate(input(headers: headers))
        XCTAssertEqual(check("coop", missing).state, .warn)
        XCTAssertEqual(check("coep", missing).state, .warn)
        XCTAssertEqual(check("corp", missing).state, .warn)
    }

    func testPermissionsPolicy_grades() {
        var headers = goodHeaders
        headers["permissions-policy"] = "camera=*, microphone=()"
        let open = check("permissions", OrbitSecurityLogic.evaluate(input(headers: headers)))
        XCTAssertEqual(open.state, .warn)
        XCTAssertEqual(open.findings.count, 1)

        headers.removeValue(forKey: "permissions-policy")
        headers["feature-policy"] = "camera 'none'"
        let legacy = check("permissions", OrbitSecurityLogic.evaluate(input(headers: headers)))
        XCTAssertEqual(legacy.state, .warn)
        XCTAssertTrue(legacy.summary.contains("Feature-Policy"))
    }

    func testHeaders_notCapturedAreNotGradedAsFailures() {
        let report = OrbitSecurityLogic.evaluate(input(headers: nil))
        for id in ["hsts", "csp", "xcto", "clickjacking", "coop", "coep", "corp", "permissions"] {
            XCTAssertEqual(check(id, report).state, .info, id)
        }
    }

    func testHeaders_notApplicableOutsideWebPages() {
        let report = OrbitSecurityLogic.evaluate(input(url: "file:///tmp/index.html"))
        XCTAssertEqual(check("csp", report).state, .info)
        XCTAssertEqual(check("https", report).state, .info)
        XCTAssertEqual(report.overall, .secure)
    }

    func testHeaderRawValueAndAdviceAreAlwaysPresent() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        for item in report.checks(in: .headers) {
            XCTAssertFalse(item.advice.isEmpty, item.id)
            XCTAssertFalse(item.summary.isEmpty, item.id)
            XCTAssertNotNil(item.value, item.id)
        }
    }

    // MARK: - Cookies

    func testCookieRows_wellConfiguredCookiePasses() {
        var value = input(headers: goodHeaders)
        value.cookies = [cookie("session")]
        let row = OrbitSecurityLogic.evaluate(value).cookieRows[0]
        XCTAssertEqual([row.secure, row.httpOnly, row.sameSite], [.pass, .pass, .pass])
        XCTAssertTrue(row.issues.isEmpty)
    }

    func testCookieRows_missingFlagsOnHTTPSFail() {
        var value = input(headers: goodHeaders)
        value.cookies = [cookie("sessionid", secure: false, httpOnly: false, sameSite: "")]
        let row = OrbitSecurityLogic.evaluate(value).cookieRows[0]
        XCTAssertEqual(row.secure, .fail)
        XCTAssertEqual(row.httpOnly, .fail, "a session-looking cookie readable by scripts is a failure")
        XCTAssertEqual(row.sameSite, .warn)
        XCTAssertEqual(row.sameSiteValue, "Not set")
        XCTAssertEqual(row.issues.count, 3)
    }

    func testCookieRows_ordinaryCookieWithoutHttpOnlyOnlyWarns() {
        var value = input(headers: goodHeaders)
        value.cookies = [cookie("theme", httpOnly: false)]
        XCTAssertEqual(OrbitSecurityLogic.evaluate(value).cookieRows[0].httpOnly, .warn)
    }

    func testCookieRows_csrfTokensAreNotTreatedAsSessionCookies() {
        XCTAssertFalse(OrbitSecurityLogic.looksSensitive(cookieName: "csrftoken"))
        XCTAssertFalse(OrbitSecurityLogic.looksSensitive(cookieName: "XSRF-TOKEN"))
        XCTAssertTrue(OrbitSecurityLogic.looksSensitive(cookieName: "auth_token"))
        XCTAssertTrue(OrbitSecurityLogic.looksSensitive(cookieName: "PHPSESSID"))
    }

    func testCookieRows_sameSiteNoneNeedsSecure() {
        var value = input(headers: goodHeaders)
        value.cookies = [cookie("a", secure: false, sameSite: "None"), cookie("b", secure: true, sameSite: "None")]
        let rows = OrbitSecurityLogic.evaluate(value).cookieRows
        XCTAssertEqual(rows.first { $0.name == "a" }?.sameSite, .fail)
        XCTAssertEqual(rows.first { $0.name == "b" }?.sameSite, .info)
    }

    func testCookieRows_hostPrefixRules() {
        var value = input(headers: goodHeaders)
        // Not Secure and carrying a Domain attribute: two ways to break the __Host- contract.
        value.cookies = [cookie("__Host-id", domain: ".example.com", path: "/", secure: false)]
        let row = OrbitSecurityLogic.evaluate(value).cookieRows[0]
        XCTAssertEqual(row.issues.filter { $0.contains("__Host-") }.count, 2)
        let report = OrbitSecurityLogic.evaluate(value)
        XCTAssertEqual(check("cookie-prefix", report).state, .fail)
    }

    func testCookieRows_onlyCookiesForThisPageAreGraded() {
        var value = input(headers: goodHeaders)
        value.cookies = [cookie("mine"), cookie("theirs", domain: "other.test")]
        XCTAssertEqual(OrbitSecurityLogic.evaluate(value).cookieRows.map(\.name), ["mine"])
    }

    func testCookieChecks_aggregateStateIsTheWorstCookie() {
        var value = input(headers: goodHeaders)
        value.cookies = [cookie("good"), cookie("bad", secure: false)]
        let report = OrbitSecurityLogic.evaluate(value)
        let secure = check("cookie-secure", report)
        XCTAssertEqual(secure.state, .fail)
        XCTAssertEqual(secure.findings.map(\.text), ["bad: not Secure"])
        XCTAssertEqual(check("cookie-httponly", report).state, .pass)
    }

    func testCookieChecks_noCookiesIsNotAFailure() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        XCTAssertEqual(check("cookie-secure", report).state, .info)
    }

    func testCookieRows_secureFlagOnHTTPLocalhostIsInformational() {
        var value = input(url: "http://localhost:3000/", headers: [:])
        value.cookies = [cookie("dev", domain: "localhost", secure: false)]
        XCTAssertEqual(OrbitSecurityLogic.evaluate(value).cookieRows[0].secure, .info)
    }

    // MARK: - Certificate formatting

    func testKeyDescription() {
        XCTAssertEqual(OrbitSecurityLogic.keyDescription(type: "RSA", bits: 2048), "RSA 2048-bit")
        XCTAssertEqual(OrbitSecurityLogic.keyDescription(type: "EC", bits: 256), "EC 256-bit")
        XCTAssertEqual(OrbitSecurityLogic.keyDescription(type: "RSA", bits: nil), "RSA")
        XCTAssertEqual(OrbitSecurityLogic.keyDescription(type: nil, bits: 4096), "4096-bit key")
        XCTAssertEqual(OrbitSecurityLogic.keyDescription(type: nil, bits: nil), "Unknown")
    }

    func testKeyTypeName() {
        XCTAssertEqual(OrbitSecurityLogic.keyTypeName(fromAttribute: "42"), "RSA")
        XCTAssertEqual(OrbitSecurityLogic.keyTypeName(fromAttribute: "73"), "EC")
        XCTAssertNil(OrbitSecurityLogic.keyTypeName(fromAttribute: "999"))
    }

    func testSignatureAlgorithmName() {
        XCTAssertEqual(OrbitSecurityLogic.signatureAlgorithmName("1.2.840.113549.1.1.11"), "SHA-256 with RSA")
        XCTAssertEqual(OrbitSecurityLogic.signatureAlgorithmName("1.2.840.10045.4.3.2"), "SHA-256 with ECDSA")
        XCTAssertEqual(OrbitSecurityLogic.signatureAlgorithmName("SHA-256 with RSA Encryption"), "SHA-256 with RSA")
    }

    func testIsWeakSignature() {
        XCTAssertTrue(OrbitSecurityLogic.isWeakSignature("SHA-1 with RSA"))
        XCTAssertTrue(OrbitSecurityLogic.isWeakSignature("MD5 with RSA"))
        XCTAssertFalse(OrbitSecurityLogic.isWeakSignature("SHA-256 with RSA"))
        XCTAssertFalse(OrbitSecurityLogic.isWeakSignature(nil))
    }

    func testHostMatches() {
        XCTAssertTrue(OrbitSecurityLogic.hostMatches(host: "example.com", pattern: "example.com"))
        XCTAssertTrue(OrbitSecurityLogic.hostMatches(host: "WWW.Example.com", pattern: "*.example.com"))
        XCTAssertFalse(OrbitSecurityLogic.hostMatches(host: "example.com", pattern: "*.example.com"))
        XCTAssertFalse(OrbitSecurityLogic.hostMatches(host: "a.b.example.com", pattern: "*.example.com"))
        XCTAssertFalse(OrbitSecurityLogic.hostMatches(host: "evilexample.com", pattern: "*.example.com"))
    }

    func testExpiryDescription() {
        func text(_ offset: TimeInterval) -> String {
            OrbitSecurityLogic.expiryDescription(notAfter: now.addingTimeInterval(offset), now: now)
        }
        XCTAssertEqual(text(82.5 * day), "Expires in 82 days")
        XCTAssertEqual(text(1.5 * day), "Expires tomorrow")
        XCTAssertEqual(text(3600), "Expires today")
        XCTAssertEqual(text(-3600), "Expired today")
        XCTAssertEqual(text(-1.5 * day), "Expired yesterday")
        XCTAssertEqual(text(-10.5 * day), "Expired 10 days ago")
        XCTAssertEqual(OrbitSecurityLogic.expiryDescription(notAfter: nil, now: now), "Expiry date unknown")
    }

    func testValidityDescriptionIsUTC() {
        let from = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01T00:00:00Z
        let to = Date(timeIntervalSince1970: 1_775_001_600)     // 2026-04-01T00:00:00Z
        XCTAssertEqual(OrbitSecurityLogic.validityDescription(notBefore: from, notAfter: to), "2026-01-01 to 2026-04-01 (UTC)")
        XCTAssertEqual(OrbitSecurityLogic.validityDescription(notBefore: nil, notAfter: nil), "unknown to unknown (UTC)")
    }

    func testCertificateRows() {
        let rows = OrbitSecurityLogic.certificateRows(certificate(), now: now)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["Subject"], "example.com")
        XCTAssertEqual(byLabel["Issuer"], "Example CA")
        XCTAssertEqual(byLabel["Expiry"], "Expires in 90 days")
        XCTAssertEqual(byLabel["Public key"], "EC 256-bit")
        XCTAssertEqual(byLabel["Signature"], "SHA-256 with ECDSA")
        XCTAssertEqual(byLabel["Alternative names"], "example.com, www.example.com")
        XCTAssertEqual(byLabel["Serial"], "0A:0B")
    }

    // MARK: - Connection checks

    func testConnection_validCertificatePasses() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        for id in ["https", "trust", "hostname", "expiry", "key", "signature"] {
            XCTAssertEqual(check(id, report).state, .pass, id)
        }
    }

    func testConnection_tlsVersionAndCipherAreNotInvented() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        XCTAssertEqual(check("tls-version", report).value, "Not exposed by WebKit")
        XCTAssertEqual(check("tls-cipher", report).value, "Not exposed by WebKit")
        XCTAssertEqual(check("tls-version", report).state, .info)
    }

    func testConnection_expiredCertificateFailsAndMakesPageNotSecure() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders, certs: [certificate(daysValid: -3, daysAgoIssued: 100)]))
        XCTAssertEqual(check("expiry", report).state, .fail)
        XCTAssertEqual(report.overall, .notSecure)
    }

    func testConnection_expiryWarningWindow() {
        func state(_ days: Double) -> OrbitSecurityState {
            check("expiry", OrbitSecurityLogic.evaluate(input(headers: goodHeaders, certs: [certificate(daysValid: days)]))).state
        }
        XCTAssertEqual(state(10), .fail)
        XCTAssertEqual(state(20), .warn)
        XCTAssertEqual(state(31), .pass)
    }

    func testConnection_nearExpiryFailsButIsNotCritical() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders, certs: [certificate(daysValid: 5)]))
        XCTAssertEqual(check("expiry", report).state, .fail)
        XCTAssertEqual(report.overall, .issues)
    }

    func testConnection_hostnameMismatchFails() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders, certs: [certificate(names: ["other.test"])]))
        XCTAssertEqual(check("hostname", report).state, .fail)
        XCTAssertEqual(report.overall, .notSecure)
    }

    func testConnection_wildcardCertificateCoversSubdomain() {
        let report = OrbitSecurityLogic.evaluate(input(url: "https://app.example.com/", headers: goodHeaders, certs: [certificate(names: ["*.example.com"])]))
        XCTAssertEqual(check("hostname", report).state, .pass)
    }

    func testConnection_untrustedChainFails() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders, trust: .untrusted("Root not trusted")))
        XCTAssertEqual(check("trust", report).state, .fail)
        XCTAssertEqual(check("trust", report).value, "Root not trusted")
        XCTAssertEqual(report.overall, .notSecure)
    }

    func testConnection_noTrustCapturedIsInformational() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders, certs: [], trust: .unavailable))
        XCTAssertEqual(check("trust", report).state, .info)
        XCTAssertNil(report.checks.first { $0.id == "hostname" })
    }

    func testConnection_weakKeysAndSignatures() {
        let weakRSA = OrbitSecurityLogic.evaluate(input(headers: goodHeaders, certs: [certificate(keyType: "RSA", bits: 1024)]))
        XCTAssertEqual(check("key", weakRSA).state, .fail)
        let strongRSA = OrbitSecurityLogic.evaluate(input(headers: goodHeaders, certs: [certificate(keyType: "RSA", bits: 2048)]))
        XCTAssertEqual(check("key", strongRSA).state, .pass)
        let sha1 = OrbitSecurityLogic.evaluate(input(headers: goodHeaders, certs: [certificate(signature: "SHA-1 with RSA")]))
        XCTAssertEqual(check("signature", sha1).state, .fail)
    }

    func testConnection_plainHTTPFails() {
        let report = OrbitSecurityLogic.evaluate(input(url: "http://example.com/", headers: [:]))
        XCTAssertEqual(check("https", report).state, .fail)
        XCTAssertEqual(report.overall, .notSecure)
        XCTAssertNil(report.checks.first { $0.id == "trust" })
    }

    func testConnection_localhostHTTPIsNotAFailure() {
        let report = OrbitSecurityLogic.evaluate(input(url: "http://localhost:3000/", headers: goodHeaders))
        XCTAssertEqual(check("https", report).state, .info)
        XCTAssertNotEqual(report.overall, .notSecure)
        XCTAssertEqual(check("hsts", report).state, .info)
    }

    // MARK: - Content

    func testContent_mixedContentFromNetworkAndDOM() {
        var value = input(headers: goodHeaders)
        value.requests = [
            OrbitSecurityRequest(url: "http://cdn.example.net/a.js", type: "script"),
            OrbitSecurityRequest(url: "https://cdn.example.net/b.js", type: "script"),
            OrbitSecurityRequest(url: "http://localhost:3000/dev.js", type: "script"),
        ]
        value.domReferences = [
            OrbitSecurityRequest(url: "http://cdn.example.net/a.js", type: "script", nodeID: 4, selector: "script"),
            OrbitSecurityRequest(url: "http://img.example.net/x.png", type: "img", nodeID: 9, selector: "img#x"),
        ]
        let mixed = check("mixed-content", OrbitSecurityLogic.evaluate(value))
        XCTAssertEqual(mixed.state, .fail)
        XCTAssertEqual(mixed.findings.count, 2, "duplicates and localhost are not counted")
        XCTAssertEqual(mixed.findings.compactMap(\.nodeID), [9])
    }

    func testContent_noMixedContentPasses() {
        var value = input(headers: goodHeaders)
        value.requests = [OrbitSecurityRequest(url: "https://example.com/a.js", type: "script")]
        XCTAssertEqual(check("mixed-content", OrbitSecurityLogic.evaluate(value)).state, .pass)
    }

    func testContent_webKitSecureContentFlag() {
        var value = input(headers: goodHeaders)
        value.hasOnlySecureContent = false
        let report = OrbitSecurityLogic.evaluate(value)
        XCTAssertEqual(check("secure-content", report).state, .fail)
        XCTAssertEqual(report.overall, .notSecure)
    }

    func testContent_insecureFormActionFails() {
        var value = input(headers: goodHeaders)
        value.forms = [
            OrbitSecurityForm(action: "http://evil.example/login", method: "post", hasPassword: true, nodeID: 3, selector: "form#login"),
            OrbitSecurityForm(action: "https://example.com/search", method: "get", hasPassword: false, nodeID: 5, selector: "form#search"),
        ]
        let forms = check("forms", OrbitSecurityLogic.evaluate(value))
        XCTAssertEqual(forms.state, .fail)
        XCTAssertEqual(forms.findings.count, 1)
        XCTAssertEqual(forms.findings[0].nodeID, 3)
    }

    func testContent_passwordFieldOnHTTPPageFails() {
        var value = input(url: "http://example.com/", headers: [:])
        value.forms = [OrbitSecurityForm(action: "http://example.com/login", method: "post", hasPassword: true, nodeID: 1, selector: "form")]
        XCTAssertEqual(check("forms", OrbitSecurityLogic.evaluate(value)).state, .fail)
    }

    func testContent_passwordFormOnLocalhostIsFine() {
        var value = input(url: "http://localhost:3000/", headers: [:])
        value.forms = [OrbitSecurityForm(action: "http://localhost:3000/login", method: "post", hasPassword: true, nodeID: 1, selector: "form")]
        XCTAssertEqual(check("forms", OrbitSecurityLogic.evaluate(value)).state, .pass)
    }

    func testContent_insecureFrameFailsAndSandboxIsMentioned() {
        var value = input(headers: goodHeaders)
        value.frames = [
            OrbitSecurityFrame(src: "http://ads.example.net/frame", isSandboxed: false, isCrossOrigin: true, nodeID: 7, selector: "iframe#ad"),
            OrbitSecurityFrame(src: "https://maps.example.net/", isSandboxed: false, isCrossOrigin: true, nodeID: 8, selector: "iframe#map"),
        ]
        let frames = check("frames", OrbitSecurityLogic.evaluate(value))
        XCTAssertEqual(frames.state, .fail)
        XCTAssertEqual(frames.findings.map(\.nodeID), [7])

        value.frames = [value.frames[1]]
        let sandbox = check("frames", OrbitSecurityLogic.evaluate(value))
        XCTAssertEqual(sandbox.state, .pass)
        XCTAssertTrue(sandbox.summary.contains("no sandbox"))
    }

    func testContent_relativeFormActionResolvesAgainstThePage() {
        var value = input(url: "https://example.com/a/", headers: goodHeaders)
        value.forms = [OrbitSecurityForm(action: "/submit", method: "post", hasPassword: false, nodeID: 1, selector: "form")]
        XCTAssertEqual(check("forms", OrbitSecurityLogic.evaluate(value)).state, .pass)
    }

    // MARK: - Overall

    func testOverall_cleanPageIsSecure() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        XCTAssertEqual(report.overall, .secure)
        XCTAssertEqual(report.failCount, 0)
        XCTAssertEqual(report.warnCount, 0)
        XCTAssertGreaterThan(report.passCount, 10)
    }

    func testOverall_missingHeadersAreIssuesNotNotSecure() {
        var headers = goodHeaders
        headers.removeValue(forKey: "content-security-policy")
        headers.removeValue(forKey: "x-content-type-options")
        let report = OrbitSecurityLogic.evaluate(input(headers: headers))
        XCTAssertEqual(report.overall, .issues)
        XCTAssertGreaterThanOrEqual(report.failCount, 2)
    }

    func testOverall_countsMatchChecks() {
        var headers = goodHeaders
        headers["referrer-policy"] = "unsafe-url"
        headers.removeValue(forKey: "permissions-policy")
        let report = OrbitSecurityLogic.evaluate(input(headers: headers))
        XCTAssertEqual(report.passCount + report.warnCount + report.failCount + report.infoCount, report.checks.count)
        XCTAssertEqual(report.failCount, report.checks.filter { $0.state == .fail }.count)
    }

    func testSummaryText_listsEverySection() {
        let report = OrbitSecurityLogic.evaluate(input(headers: goodHeaders))
        let text = OrbitSecurityLogic.summaryText(report)
        for section in OrbitSecuritySection.allCases {
            XCTAssertTrue(text.contains(section.title), section.title)
        }
        XCTAssertTrue(text.contains("[pass] Strict-Transport-Security"))
    }

    func testSeverityOrdering() {
        XCTAssertEqual(OrbitSecurityState.worst([.pass, .warn, .info]), .warn)
        XCTAssertEqual(OrbitSecurityState.worst([.pass, .fail, .warn]), .fail)
        XCTAssertEqual(OrbitSecurityState.worst([.info, .pass]), .pass)
        XCTAssertEqual(OrbitSecurityState.worst([]), .info)
    }
}
