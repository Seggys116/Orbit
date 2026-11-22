// Unit tests for OrbitLighthouseLogic; the OrbitInspect*Logic and OrbitInspectDecode sources it needs are compiled in directly.

import XCTest

final class OrbitInspectLighthouseTests: XCTestCase {

    // MARK: - Log-normal CDF score

    func testLogNormal_medianScoresHalf() {
        // At the median, score should be 0.5
        let score = OrbitLighthouseLogic.logNormalScore(value: 3000, p10: 1800, median: 3000)
        XCTAssertEqual(score, 0.5, accuracy: 0.01)
    }

    func testLogNormal_p10ScoresNinetyPercent() {
        // At the p10 point, score should be 0.9
        let score = OrbitLighthouseLogic.logNormalScore(value: 1800, p10: 1800, median: 3000)
        XCTAssertEqual(score, 0.9, accuracy: 0.01)
    }

    func testLogNormal_veryLowValueScoresNearOne() {
        let score = OrbitLighthouseLogic.logNormalScore(value: 100, p10: 1800, median: 3000)
        XCTAssertGreaterThan(score, 0.99)
    }

    func testLogNormal_veryHighValueScoresNearZero() {
        let score = OrbitLighthouseLogic.logNormalScore(value: 30_000, p10: 1800, median: 3000)
        XCTAssertLessThan(score, 0.01)
    }

    func testLogNormal_clsMedian() {
        let score = OrbitLighthouseLogic.logNormalScore(value: 0.25, p10: 0.1, median: 0.25)
        XCTAssertEqual(score, 0.5, accuracy: 0.01)
    }

    func testLogNormal_clsP10() {
        let score = OrbitLighthouseLogic.logNormalScore(value: 0.1, p10: 0.1, median: 0.25)
        XCTAssertEqual(score, 0.9, accuracy: 0.01)
    }

    func testLogNormal_lcpDesktopP10() {
        let score = OrbitLighthouseLogic.logNormalScore(value: 1200, p10: 1200, median: 2400)
        XCTAssertEqual(score, 0.9, accuracy: 0.01)
    }

    func testLogNormal_tbtMobileMedian() {
        let score = OrbitLighthouseLogic.logNormalScore(value: 600, p10: 200, median: 600)
        XCTAssertEqual(score, 0.5, accuracy: 0.01)
    }

    func testLogNormal_scoreClampedToZeroOne() {
        let high = OrbitLighthouseLogic.logNormalScore(value: 0.001, p10: 1800, median: 3000)
        XCTAssertLessThanOrEqual(high, 1.0)
        XCTAssertGreaterThanOrEqual(high, 0.0)

        let low = OrbitLighthouseLogic.logNormalScore(value: 999_999, p10: 1800, median: 3000)
        XCTAssertLessThanOrEqual(low, 1.0)
        XCTAssertGreaterThanOrEqual(low, 0.0)
    }

    // MARK: - Colour contrast

    func testRelativeLuminance_white() {
        let l = OrbitLighthouseLogic.relativeLuminance(r: 255, g: 255, b: 255)
        XCTAssertEqual(l, 1.0, accuracy: 0.001)
    }

    func testRelativeLuminance_black() {
        let l = OrbitLighthouseLogic.relativeLuminance(r: 0, g: 0, b: 0)
        XCTAssertEqual(l, 0.0, accuracy: 0.001)
    }

    func testContrastRatio_blackOnWhite() {
        let ratio = OrbitLighthouseLogic.contrastRatioOpaque(fg: [0, 0, 0], bg: [255, 255, 255])
        XCTAssertEqual(ratio, 21.0, accuracy: 0.1)
    }

    func testContrastRatio_whiteOnWhite() {
        let ratio = OrbitLighthouseLogic.contrastRatioOpaque(fg: [255, 255, 255], bg: [255, 255, 255])
        XCTAssertEqual(ratio, 1.0, accuracy: 0.01)
    }

    func testContrastRatio_wcagAA_pass() {
        // Dark gray on white: should pass 4.5:1
        let ratio = OrbitLighthouseLogic.contrastRatioOpaque(fg: [70, 70, 70], bg: [255, 255, 255])
        XCTAssertGreaterThan(ratio, 4.5)
    }

    func testContrastRatio_lightGrayFail() {
        // Very light gray text on white: should fail
        let ratio = OrbitLighthouseLogic.contrastRatioOpaque(fg: [220, 220, 220], bg: [255, 255, 255])
        XCTAssertLessThan(ratio, 4.5)
    }

    func testCompositeOver_opaqueTop() {
        let result = OrbitLighthouseLogic.compositeOver(top: [255, 0, 0, 1], bottom: [0, 0, 255, 1])
        XCTAssertEqual(result[0], 255, accuracy: 1)
        XCTAssertEqual(result[1], 0,   accuracy: 1)
        XCTAssertEqual(result[2], 0,   accuracy: 1)
    }

    func testCompositeOver_halfAlpha() {
        let result = OrbitLighthouseLogic.compositeOver(top: [100, 100, 100, 0.5], bottom: [200, 200, 200, 1])
        XCTAssertEqual(result[0], 150, accuracy: 2)
    }

    // MARK: - TBT

    func testTBT_noTasks() {
        let tasks: [LHLongTask] = []
        let tbt = OrbitLighthouseLogic.computeTBT(longTasks: tasks, fcpMs: 1000, apiAvailable: true)
        XCTAssertEqual(tbt, 0)
    }

    func testTBT_taskBeforeFCP_excluded() {
        let tasks = [LHLongTask(startMs: 500, durationMs: 200)]   // 200-50 = 150, but starts before FCP
        let tbt = OrbitLighthouseLogic.computeTBT(longTasks: tasks, fcpMs: 1000, apiAvailable: true)
        XCTAssertEqual(tbt, 0)
    }

    func testTBT_taskAfterFCP() {
        let tasks = [LHLongTask(startMs: 1500, durationMs: 200)]  // after FCP; blocking = 200-50=150
        let tbt = OrbitLighthouseLogic.computeTBT(longTasks: tasks, fcpMs: 1000, apiAvailable: true)
        XCTAssertEqual(tbt ?? .nan, 150, accuracy: 0.1)
    }

    func testTBT_multipleTasks() {
        let tasks = [
            LHLongTask(startMs: 1500, durationMs: 100),  // blocking = 50
            LHLongTask(startMs: 2000, durationMs: 300),  // blocking = 250
            LHLongTask(startMs: 2500, durationMs: 60),   // blocking = 10
        ]
        let tbt = OrbitLighthouseLogic.computeTBT(longTasks: tasks, fcpMs: 1000, apiAvailable: true)
        XCTAssertEqual(tbt ?? .nan, 310, accuracy: 0.1)
    }

    func testTBT_apiUnavailable_returnsNil() {
        let tasks = [LHLongTask(startMs: 1500, durationMs: 200)]
        let tbt = OrbitLighthouseLogic.computeTBT(longTasks: tasks, fcpMs: 1000, apiAvailable: false)
        XCTAssertNil(tbt)
    }

    func testTBT_noFCP_returnsNil() {
        let tasks = [LHLongTask(startMs: 1500, durationMs: 200)]
        let tbt = OrbitLighthouseLogic.computeTBT(longTasks: tasks, fcpMs: nil, apiAvailable: true)
        XCTAssertNil(tbt)
    }

    // MARK: - Speed Index

    func testSpeedIndex_insufficientFrames() {
        let si = OrbitLighthouseLogic.computeSpeedIndex(frames: [(ms: 0, completeness: 0)])
        XCTAssertNil(si)
    }

    func testSpeedIndex_instantLoad() {
        // First frame already 100% complete
        let frames: [(ms: Double, completeness: Double)] = [
            (ms: 0, completeness: 1.0),
            (ms: 100, completeness: 1.0),
            (ms: 200, completeness: 1.0),
        ]
        let si = OrbitLighthouseLogic.computeSpeedIndex(frames: frames)
        XCTAssertNotNil(si)
        XCTAssertEqual(si!, 0, accuracy: 0.1)  // fully complete from start => SI ≈ 0
    }

    func testSpeedIndex_linearProgress() {
        // Progress ramps from 0 to 1 over 1000 ms
        var frames: [(ms: Double, completeness: Double)] = []
        for i in 0 ..< 11 {
            frames.append((ms: Double(i * 100), completeness: Double(i) / 10.0))
        }
        let si = OrbitLighthouseLogic.computeSpeedIndex(frames: frames)
        XCTAssertNotNil(si)
        // Integral of (1-completeness) from 0..1000 with linear progress = 500 ms
        XCTAssertEqual(si!, 500, accuracy: 20)
    }

    // MARK: - Category score

    func testCategoryScore_allFailing() {
        let audits = [
            LHAuditResult(id: "a", category: .accessibility, title: "", description: "",
                          status: .fail, score: 0, weight: 10, displayValue: "", items: []),
            LHAuditResult(id: "b", category: .accessibility, title: "", description: "",
                          status: .fail, score: 0, weight: 10, displayValue: "", items: []),
        ]
        let score = OrbitLighthouseLogic.categoryScore(audits, category: .accessibility)
        XCTAssertEqual(score, 0)
    }

    func testCategoryScore_allPassing() {
        let audits = [
            LHAuditResult(id: "a", category: .seo, title: "", description: "",
                          status: .pass, score: 1, weight: 9, displayValue: "", items: []),
            LHAuditResult(id: "b", category: .seo, title: "", description: "",
                          status: .pass, score: 1, weight: 9, displayValue: "", items: []),
        ]
        let score = OrbitLighthouseLogic.categoryScore(audits, category: .seo)
        XCTAssertEqual(score, 100)
    }

    func testCategoryScore_weighted() {
        let audits = [
            LHAuditResult(id: "a", category: .performance, title: "", description: "",
                          status: .pass, score: 1.0, weight: 25, displayValue: "", items: []),
            LHAuditResult(id: "b", category: .performance, title: "", description: "",
                          status: .fail, score: 0.0, weight: 75, displayValue: "", items: []),
        ]
        let score = OrbitLighthouseLogic.categoryScore(audits, category: .performance)
        // weighted: (1.0 * 25 + 0.0 * 75) / 100 = 0.25 → 25
        XCTAssertEqual(score, 25)
    }

    func testCategoryScore_nilScoreExcluded() {
        let audits = [
            LHAuditResult(id: "a", category: .performance, title: "", description: "",
                          status: .pass, score: 1.0, weight: 25, displayValue: "", items: []),
            LHAuditResult(id: "b", category: .performance, title: "", description: "",
                          status: .notApplicable, score: nil, weight: 30, displayValue: "", items: []),
        ]
        let score = OrbitLighthouseLogic.categoryScore(audits, category: .performance)
        // Only audit 'a' counts: 1.0 * 25 / 25 = 1.0 → 100
        XCTAssertEqual(score, 100)
    }

    func testCategoryScore_noAudits_returnsNil() {
        let score = OrbitLighthouseLogic.categoryScore([], category: .seo)
        XCTAssertNil(score)
    }

    // MARK: - Median report

    func testMedianReport_singleRun() {
        let report = makeReport(perfScore: 75)
        let result = OrbitLighthouseLogic.medianReport(runs: [report])
        XCTAssertEqual(result.scores.performance, 75)
    }

    func testMedianReport_threeRuns_oddCount() {
        let runs = [makeReport(perfScore: 70), makeReport(perfScore: 80), makeReport(perfScore: 60)]
        let result = OrbitLighthouseLogic.medianReport(runs: runs)
        XCTAssertEqual(result.scores.performance, 70)  // median of [60, 70, 80]
        XCTAssertEqual(result.runCount, 3)
    }

    // MARK: - robots.txt

    func testRobotsTxt_allowAll() {
        let txt = "User-agent: *\nAllow: /"
        let blocked = OrbitLighthouseLogic.robotsTxtDisallows(txt: txt, path: "/page")
        XCTAssertFalse(blocked)
    }

    func testRobotsTxt_disallowAll() {
        let txt = "User-agent: *\nDisallow: /"
        let blocked = OrbitLighthouseLogic.robotsTxtDisallows(txt: txt, path: "/page")
        XCTAssertTrue(blocked)
    }

    func testRobotsTxt_disallowSpecificPath() {
        let txt = "User-agent: *\nDisallow: /private/"
        XCTAssertTrue(OrbitLighthouseLogic.robotsTxtDisallows(txt: txt, path: "/private/page"))
        XCTAssertFalse(OrbitLighthouseLogic.robotsTxtDisallows(txt: txt, path: "/public/page"))
    }

    func testRobotsTxt_emptyDisallow_allowsAll() {
        let txt = "User-agent: *\nDisallow: "
        let blocked = OrbitLighthouseLogic.robotsTxtDisallows(txt: txt, path: "/page")
        XCTAssertFalse(blocked)
    }

    func testRobotsTxt_specificAgent_notBlocked() {
        let txt = "User-agent: Bingbot\nDisallow: /\n"
        // Googlebot not mentioned → not blocked
        let blocked = OrbitLighthouseLogic.robotsTxtDisallows(txt: txt, userAgent: "Googlebot", path: "/")
        XCTAssertFalse(blocked)
    }

    // MARK: - Language tag validation

    func testLangValid_en() {
        XCTAssertTrue(OrbitLighthouseLogic.isValidLangTag("en"))
    }

    func testLangValid_enUS() {
        XCTAssertTrue(OrbitLighthouseLogic.isValidLangTag("en-US"))
    }

    func testLangValid_zhHant() {
        XCTAssertTrue(OrbitLighthouseLogic.isValidLangTag("zh-Hant"))
    }

    func testLangInvalid_empty() {
        XCTAssertFalse(OrbitLighthouseLogic.isValidLangTag(""))
    }

    func testLangInvalid_singleChar() {
        XCTAssertFalse(OrbitLighthouseLogic.isValidLangTag("x"))
    }

    func testLangInvalid_numbers() {
        XCTAssertFalse(OrbitLighthouseLogic.isValidLangTag("12"))
    }

    // MARK: - Network helpers

    func testIsCompressible_javascript() {
        XCTAssertTrue(OrbitLighthouseLogic.isCompressible(mimeType: "application/javascript"))
    }

    func testIsCompressible_json() {
        XCTAssertTrue(OrbitLighthouseLogic.isCompressible(mimeType: "application/json"))
    }

    func testIsCompressible_image_not() {
        XCTAssertFalse(OrbitLighthouseLogic.isCompressible(mimeType: "image/png"))
    }

    func testIsModernImage_webp() {
        XCTAssertTrue(OrbitLighthouseLogic.isModernImageFormat(mimeType: "image/webp"))
    }

    func testIsModernImage_jpeg_not() {
        XCTAssertFalse(OrbitLighthouseLogic.isModernImageFormat(mimeType: "image/jpeg"))
    }

    // MARK: - Report JSON round-trip

    func testReportJSONRoundTrip() throws {
        let original = makeReport(perfScore: 82)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(original)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(LHReport.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.scores.performance, original.scores.performance)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.mode, original.mode)
    }

    // MARK: - score() pure function determinism

    func testScoreDeterminism() {
        var bundle = LHBundle()
        bundle.url = "https://example.com"
        bundle.mode = .navigation
        bundle.device = .mobile
        bundle.fcpMs = 1800
        bundle.lcpMs = 2500
        bundle.clsScore = 0.05
        bundle.ttfbMs = 400
        bundle.longTasksAPIAvailable = true
        bundle.longTasks = []
        bundle.documentTitle = "Example"
        bundle.htmlLang = "en"
        bundle.hasDoctype = true
        bundle.hasViewport = true

        let report1 = OrbitLighthouseLogic.score(bundle: bundle)
        let report2 = OrbitLighthouseLogic.score(bundle: bundle)

        // Scores must be identical for the same input
        XCTAssertEqual(report1.scores.performance, report2.scores.performance)
        XCTAssertEqual(report1.scores.accessibility, report2.scores.accessibility)
        XCTAssertEqual(report1.scores.seo, report2.scores.seo)
    }

    func testScorePerformance_goodPage_highScore() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.device = .mobile
        bundle.fcpMs = 900          // well below p10=1800
        bundle.lcpMs = 1500         // well below p10=2500
        bundle.clsScore = 0.01      // well below p10=0.1
        bundle.ttfbMs = 200
        bundle.longTasksAPIAvailable = true
        bundle.longTasks = []
        bundle.siFrames = [         // fast visual progress
            (ms: 0, completeness: 0.9),
            (ms: 100, completeness: 1.0),
        ]

        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertNotNil(report.scores.performance)
        XCTAssertGreaterThan(report.scores.performance!, 85)
    }

    func testScorePerformance_slowPage_lowScore() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.device = .mobile
        bundle.fcpMs = 6000         // way past poor threshold
        bundle.lcpMs = 10000
        bundle.clsScore = 0.5
        bundle.longTasksAPIAvailable = true
        bundle.longTasks = [LHLongTask(startMs: 1000, durationMs: 500)]

        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertNotNil(report.scores.performance)
        XCTAssertLessThan(report.scores.performance!, 40)
    }

    // MARK: - Security category

    private let securityNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func goodSecurityInput() -> OrbitSecurityInput {
        var input = OrbitSecurityInput()
        input.pageURL = "https://example.com/"
        input.now = securityNow
        input.trust = .trusted
        input.hasOnlySecureContent = true
        input.certificates = [OrbitSecurityCertificate(
            subject: "example.com", issuer: "Example CA",
            notBefore: securityNow.addingTimeInterval(-86_400 * 10), notAfter: securityNow.addingTimeInterval(86_400 * 80),
            serialNumber: nil, subjectAlternativeNames: ["example.com"],
            keyType: "EC", keySizeBits: 256, signatureAlgorithm: "SHA-256 with ECDSA"
        )]
        input.documentHeaders = [
            "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
            "content-security-policy": "default-src 'none'; script-src 'self' 'nonce-abc'; base-uri 'none'; frame-ancestors 'none'; object-src 'none'",
            "x-content-type-options": "nosniff",
            "referrer-policy": "no-referrer",
            "cross-origin-opener-policy": "same-origin",
            "cross-origin-embedder-policy": "require-corp",
            "cross-origin-resource-policy": "same-origin",
            "permissions-policy": "camera=()",
        ]
        return input
    }

    private func securityBundle(_ input: OrbitSecurityInput?) -> LHBundle {
        var bundle = LHBundle()
        bundle.url = "https://example.com/"
        bundle.mode = .snapshot
        bundle.security = input
        return bundle
    }

    func testSecurityCategory_fullyHardenedPageScoresHundred() {
        let report = OrbitLighthouseLogic.score(bundle: securityBundle(goodSecurityInput()))
        XCTAssertEqual(report.scores.security, 100)
        let audits = report.audits.filter { $0.category == .security }
        XCTAssertFalse(audits.isEmpty)
        XCTAssertTrue(audits.allSatisfy { $0.status != .fail && $0.status != .warning })
    }

    func testSecurityCategory_missingHeadersLowerTheScore() {
        var input = goodSecurityInput()
        input.documentHeaders?.removeValue(forKey: "content-security-policy")
        input.documentHeaders?.removeValue(forKey: "x-content-type-options")
        let report = OrbitLighthouseLogic.score(bundle: securityBundle(input))
        let score = report.scores.security ?? 100
        XCTAssertLessThan(score, 100)
        XCTAssertGreaterThan(score, 0)
        XCTAssertEqual(report.audits.first { $0.id == "security-csp" }?.status, .fail)
        XCTAssertEqual(report.audits.first { $0.id == "security-xcto" }?.status, .fail)
        XCTAssertEqual(report.audits.first { $0.id == "security-hsts" }?.status, .pass)
    }

    func testSecurityCategory_weightedMeanMatchesTheChecks() {
        var input = goodSecurityInput()
        input.documentHeaders?["x-content-type-options"] = "wrong"
        let report = OrbitLighthouseLogic.score(bundle: securityBundle(input))
        let audits = report.audits.filter { $0.category == .security && $0.score != nil && $0.weight > 0 }
        let total = audits.reduce(0.0) { $0 + $1.weight }
        let earned = audits.reduce(0.0) { $0 + $1.weight * ($1.score ?? 0) }
        XCTAssertEqual(report.scores.security, Int((earned / total * 100).rounded()))
        XCTAssertEqual(OrbitLighthouseLogic.categoryScore(report.audits, category: .security), report.scores.security)
    }

    func testSecurityCategory_warningScoresHalfCredit() {
        var input = goodSecurityInput()
        input.documentHeaders?.removeValue(forKey: "permissions-policy")
        let report = OrbitLighthouseLogic.score(bundle: securityBundle(input))
        let audit = report.audits.first { $0.id == "security-permissions" }
        XCTAssertEqual(audit?.status, .warning)
        XCTAssertEqual(audit?.score, 0.5)
        XCTAssertEqual(audit?.band, .warning)
    }

    func testSecurityCategory_agreesWithTheSecurityPane() {
        var input = goodSecurityInput()
        input.documentHeaders?["referrer-policy"] = "unsafe-url"
        let paneReport = OrbitSecurityLogic.evaluate(input)
        let lighthouse = OrbitLighthouseLogic.score(bundle: securityBundle(input))
        XCTAssertNil(lighthouse.audits.first { $0.id == "security-libraries" }, "Best Practices already grades vulnerable libraries.")
        for check in paneReport.checks where check.weight > 0 && check.state != .info && check.id != "libraries" {
            let audit = lighthouse.audits.first { $0.id == "security-\(check.id)" }
            XCTAssertNotNil(audit, check.id)
            XCTAssertEqual(audit?.weight, check.weight, check.id)
            switch check.state {
            case .pass: XCTAssertEqual(audit?.status, .pass, check.id)
            case .warn: XCTAssertEqual(audit?.status, .warning, check.id)
            case .fail: XCTAssertEqual(audit?.status, .fail, check.id)
            case .info: break
            }
        }
    }

    func testSecurityCategory_isNilWithoutEvidence() {
        let report = OrbitLighthouseLogic.score(bundle: securityBundle(nil))
        XCTAssertNil(report.scores.security)
        XCTAssertTrue(report.audits.filter { $0.category == .security }.isEmpty)
    }

    func testSecurityCategory_tlsRowsAreNotAudits() {
        let report = OrbitLighthouseLogic.score(bundle: securityBundle(goodSecurityInput()))
        XCTAssertNil(report.audits.first { $0.id == "security-tls-version" })
        XCTAssertNil(report.audits.first { $0.id == "security-tls-cipher" })
    }

    func testSecurityCategory_failuresCarryEvidenceItems() {
        var input = goodSecurityInput()
        input.forms = [OrbitSecurityForm(action: "http://evil.example/", method: "post", hasPassword: true, nodeID: 12, selector: "form#login")]
        let report = OrbitLighthouseLogic.score(bundle: securityBundle(input))
        let audit = report.audits.first { $0.id == "security-forms" }
        XCTAssertEqual(audit?.status, .fail)
        XCTAssertEqual(audit?.items.first?.nodeID, 12)
        XCTAssertEqual(audit?.items.first?.selector, "form#login")
    }

    func testSecurityCategory_canBeDisabled() {
        var bundle = securityBundle(goodSecurityInput())
        bundle.enabledCategories = [.performance, .seo]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertNil(report.scores.security)
        XCTAssertTrue(report.audits.filter { $0.category == .security }.isEmpty)
    }

    func testScores_subscriptCoversEveryCategory() {
        let scores = LHScores(performance: 1, accessibility: 2, bestPractices: 3, seo: 4, security: 5)
        XCTAssertEqual(LHCategory.allCases.compactMap { scores[$0] }, [1, 2, 3, 4, 5])
        XCTAssertEqual(LHCategory.security.title, "Security")
    }

    func testScores_oldHistoryWithoutSecurityStillDecodes() throws {
        let json = #"{"performance":90,"accessibility":80}"#
        let decoded = try JSONDecoder().decode(LHScores.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.performance, 90)
        XCTAssertNil(decoded.security)
    }

    func testScoreBands_followLighthouseThresholds() {
        XCTAssertEqual(LHScores.band(for: 100), .good)
        XCTAssertEqual(LHScores.band(for: 90), .good)
        XCTAssertEqual(LHScores.band(for: 89), .needsImprovement)
        XCTAssertEqual(LHScores.band(for: 50), .needsImprovement)
        XCTAssertEqual(LHScores.band(for: 49), .poor)
        XCTAssertEqual(LHScores.band(for: 0), .poor)
    }

    // MARK: - Audit bands and metric ratings

    private func audit(_ status: LHAuditStatus, score: Double?, id: String = "a", weight: Double = 0) -> LHAuditResult {
        LHAuditResult(id: id, category: .performance, title: id, description: "", status: status, score: score,
                      weight: weight, displayValue: "", items: [])
    }

    func testAuditBand() {
        XCTAssertEqual(audit(.pass, score: 1).band, .passed)
        XCTAssertEqual(audit(.warning, score: 0.5).band, .warning)
        XCTAssertEqual(audit(.fail, score: 0).band, .failed)
        XCTAssertEqual(audit(.fail, score: nil).band, .failed)
        XCTAssertEqual(audit(.fail, score: 0.7).band, .warning, "a metric between 0.5 and 0.9 is a warning")
        XCTAssertEqual(audit(.informative, score: nil).band, .informative)
        XCTAssertEqual(audit(.manual, score: nil).band, .informative)
        XCTAssertEqual(audit(.notApplicable, score: nil).band, .notApplicable)
    }

    func testMetricRating_thresholds() {
        XCTAssertEqual(LHMetricKind.lcp.rating(for: 2_500), .good)
        XCTAssertEqual(LHMetricKind.lcp.rating(for: 2_501), .needsImprovement)
        XCTAssertEqual(LHMetricKind.lcp.rating(for: 4_000), .needsImprovement)
        XCTAssertEqual(LHMetricKind.lcp.rating(for: 4_001), .poor)
        XCTAssertEqual(LHMetricKind.cls.rating(for: 0.1), .good)
        XCTAssertEqual(LHMetricKind.cls.rating(for: 0.25), .needsImprovement)
        XCTAssertEqual(LHMetricKind.cls.rating(for: 0.26), .poor)
        XCTAssertEqual(LHMetricKind.inp.rating(for: 200), .good)
        XCTAssertEqual(LHMetricKind.inp.rating(for: 501), .poor)
    }

    func testMetricKind_coreWebVitalsAndThresholdText() {
        XCTAssertEqual(LHMetricKind.allCases.filter(\.isCoreWebVital), [.lcp, .cls, .inp])
        XCTAssertTrue(LHMetricKind.cls.thresholdText.contains("0.100"))
        XCTAssertTrue(LHMetricKind.cls.thresholdText.contains("0.250"))
        XCTAssertEqual(LHMetricKind.cls.format(0.05), "0.050")
    }

    func testMetricKind_readsValuesFromMetrics() {
        let metrics = LHMetrics(fcp: 1, lcp: 2, tbt: 3, cls: 0.4, inp: 5, ttfb: 6, speedIndex: 7, tti: 8)
        XCTAssertEqual(LHMetricKind.allCases.map { $0.value(in: metrics) ?? -1 }, [2, 0.4, 5, 1, 3, 7, 6, 8])
    }

    // MARK: - Opportunities

    private func image(
        natural: (Int, Int), shown: (Int, Int), size: Int, mime: String = "image/jpeg"
    ) -> LHImage {
        LHImage(src: "https://example.com/a.jpg", alt: "", naturalWidth: natural.0, naturalHeight: natural.1,
                displayWidth: shown.0, displayHeight: shown.1, hasWidthAttr: true, hasHeightAttr: true,
                loading: "", nodeID: 1, selector: "img", snippet: "", isAboveFold: true,
                transferSize: size, mimeType: mime)
    }

    func testOversizedImage_wastedBytesScaleWithUnusedPixels() {
        // 2000x1000 shown at 500x250 on a 1x display: a sixteenth of the pixels are needed.
        let wasted = OrbitLighthouseLogic.oversizedImageWaste(image: image(natural: (2000, 1000), shown: (500, 250), size: 160_000), devicePixelRatio: 1)
        XCTAssertEqual(wasted, 150_000)
    }

    func testOversizedImage_retinaDisplaysNeedMorePixels() {
        // At 2x the same image needs a quarter of its pixels.
        let wasted = OrbitLighthouseLogic.oversizedImageWaste(image: image(natural: (2000, 1000), shown: (500, 250), size: 160_000), devicePixelRatio: 2)
        XCTAssertEqual(wasted, 120_000)
    }

    func testOversizedImage_closeEnoughIsNotWaste() {
        XCTAssertNil(OrbitLighthouseLogic.oversizedImageWaste(image: image(natural: (1100, 550), shown: (1000, 500), size: 200_000), devicePixelRatio: 1))
    }

    func testOversizedImage_ignoresSmallSavingsSVGAndUnknownSizes() {
        XCTAssertNil(OrbitLighthouseLogic.oversizedImageWaste(image: image(natural: (2000, 1000), shown: (500, 250), size: 3_000), devicePixelRatio: 1))
        XCTAssertNil(OrbitLighthouseLogic.oversizedImageWaste(image: image(natural: (2000, 1000), shown: (500, 250), size: 90_000, mime: "image/svg+xml"), devicePixelRatio: 1))
        XCTAssertNil(OrbitLighthouseLogic.oversizedImageWaste(image: image(natural: (2000, 1000), shown: (500, 250), size: 0), devicePixelRatio: 1))
        XCTAssertNil(OrbitLighthouseLogic.oversizedImageWaste(image: image(natural: (2000, 1000), shown: (0, 0), size: 90_000), devicePixelRatio: 1))
    }

    func testOversizedImages_appearAsAnOpportunity() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.images = [image(natural: (2000, 1000), shown: (500, 250), size: 160_000)]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        let audit = report.audits.first { $0.id == "uses-responsive-images" }
        XCTAssertEqual(audit?.savingsBytes, 150_000)
        XCTAssertNotNil(audit?.savingsMs)
        XCTAssertEqual(audit?.items.first?.nodeID, 1)
    }

    func testModernFormatSavingsFraction() {
        XCTAssertEqual(OrbitLighthouseLogic.modernFormatSavingsFraction(mimeType: "image/jpeg"), 0.30)
        XCTAssertEqual(OrbitLighthouseLogic.modernFormatSavingsFraction(mimeType: "IMAGE/PNG"), 0.40)
        XCTAssertEqual(OrbitLighthouseLogic.modernFormatSavingsFraction(mimeType: "image/gif"), 0.50)
        XCTAssertEqual(OrbitLighthouseLogic.modernFormatSavingsFraction(mimeType: "image/webp"), 0)
    }

    private func record(
        _ url: String, type: String = "script", mime: String = "application/javascript",
        size: Int = 50_000, headers: [String: String] = [:]
    ) -> LHNetRecord {
        LHNetRecord(id: url, url: url, resourceType: type, mimeType: mime, status: 200, transferSize: size, bodySize: size,
                    startMs: 0, durationMs: 10, fromCache: false, failed: false, protocolName: "h2",
                    requestHeaders: [:], responseHeaders: headers, initiatorURL: nil)
    }

    func testImageFormatAudit_estimatesSavingsPerFormat() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.networkRecords = [
            record("https://example.com/a.jpg", type: "image", mime: "image/jpeg", size: 100_000),
            record("https://example.com/b.png", type: "image", mime: "image/png", size: 100_000),
        ]
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "uses-webp-images" }
        XCTAssertEqual(audit?.savingsBytes, 70_000)
        XCTAssertEqual(audit?.items.first?.wastedBytes, 40_000, "the PNG saves more, so it ranks first")
        XCTAssertNotNil(audit?.savingsNote)
    }

    func testTextCompressionAudit_estimatesSavings() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.networkRecords = [record("https://example.com/app.js", size: 100_000)]
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "uses-text-compression" }
        XCTAssertEqual(audit?.savingsBytes, 65_000)
    }

    func testCacheTTLSeconds() {
        XCTAssertEqual(OrbitLighthouseLogic.cacheTTLSeconds(cacheControl: "public, max-age=31536000, immutable", expires: nil), 31_536_000)
        XCTAssertEqual(OrbitLighthouseLogic.cacheTTLSeconds(cacheControl: "max-age=60, s-maxage=600", expires: nil), 600)
        XCTAssertEqual(OrbitLighthouseLogic.cacheTTLSeconds(cacheControl: "no-store", expires: nil), 0)
        XCTAssertEqual(OrbitLighthouseLogic.cacheTTLSeconds(cacheControl: "max-age=3600, no-cache", expires: nil), 0)
        XCTAssertNil(OrbitLighthouseLogic.cacheTTLSeconds(cacheControl: nil, expires: nil))
        XCTAssertEqual(
            OrbitLighthouseLogic.cacheTTLSeconds(cacheControl: nil, expires: "Wed, 21 Oct 2026 08:00:00 GMT", date: "Wed, 21 Oct 2026 07:00:00 GMT"),
            3_600
        )
        XCTAssertEqual(OrbitLighthouseLogic.cacheTTLSeconds(cacheControl: nil, expires: "0"), 0)
    }

    func testFormatTTL() {
        XCTAssertEqual(OrbitLighthouseLogic.formatTTL(nil), "no cache headers")
        XCTAssertEqual(OrbitLighthouseLogic.formatTTL(0), "not cached")
        XCTAssertEqual(OrbitLighthouseLogic.formatTTL(600), "10 min")
        XCTAssertEqual(OrbitLighthouseLogic.formatTTL(7_200), "2 h")
        XCTAssertEqual(OrbitLighthouseLogic.formatTTL(172_800), "2 days")
    }

    func testCacheAudit_flagsShortLivedAssetsAndSkipsLongLivedOnes() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.networkRecords = [
            record("https://example.com/short.js", size: 40_000, headers: ["cache-control": "max-age=3600"]),
            record("https://example.com/none.css", type: "stylesheet", mime: "text/css", size: 10_000),
            record("https://example.com/long.js", size: 90_000, headers: ["cache-control": "public, max-age=31536000, immutable"]),
        ]
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "uses-long-cache-ttl" }
        XCTAssertEqual(audit?.items.map(\.url), ["https://example.com/short.js", "https://example.com/none.css"])
        XCTAssertEqual(audit?.savingsBytes, 50_000)
        XCTAssertNil(audit?.savingsMs, "caching helps repeat visits, so it gets no load-time estimate")
    }

    func testRenderBlockingSavings_isTheSlowestBlockerCappedAtFCP() {
        let blockers = [
            LHRenderBlocker(url: "a", type: "script", wastedMs: 120, transferSize: 1),
            LHRenderBlocker(url: "b", type: "stylesheet", wastedMs: 300, transferSize: 1),
        ]
        XCTAssertEqual(OrbitLighthouseLogic.renderBlockingSavingsMs(blockers, fcpMs: nil), 300)
        XCTAssertEqual(OrbitLighthouseLogic.renderBlockingSavingsMs(blockers, fcpMs: 200), 200)
        XCTAssertEqual(OrbitLighthouseLogic.renderBlockingSavingsMs(blockers, fcpMs: 900), 300)
        XCTAssertEqual(OrbitLighthouseLogic.renderBlockingSavingsMs([], fcpMs: 900), 0)
    }

    func testRenderBlockingAudit_reportsSavingsFromTheSlowestBlocker() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.renderBlockers = [
            LHRenderBlocker(url: "https://example.com/a.css", type: "stylesheet", wastedMs: 80, transferSize: 100),
            LHRenderBlocker(url: "https://example.com/b.js", type: "script", wastedMs: 250, transferSize: 100),
        ]
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "render-blocking-resources" }
        XCTAssertEqual(audit?.savingsMs, 250)
    }

    func testEstimatedSavings_bytesBecomeTimeAtTheAssumedLinkSpeed() {
        let bytes = audit(.fail, score: 0, id: "x")
        var withBytes = bytes
        withBytes.savingsBytes = 200_000
        let mobile = OrbitLighthouseLogic.withEstimatedSavings(withBytes, device: .mobile)
        let desktop = OrbitLighthouseLogic.withEstimatedSavings(withBytes, device: .desktop)
        XCTAssertEqual(mobile.savingsMs ?? 0, 1_000, accuracy: 0.001)
        XCTAssertEqual(desktop.savingsMs ?? 0, 160, accuracy: 0.001)
        XCTAssertNotNil(mobile.savingsNote)
    }

    func testEstimatedSavings_leavesMeasuredAndWeightedAuditsAlone() {
        var measured = audit(.fail, score: 0, id: "x")
        measured.savingsMs = 42
        measured.savingsBytes = 1_000_000
        XCTAssertEqual(OrbitLighthouseLogic.withEstimatedSavings(measured, device: .mobile).savingsMs, 42)
        var weighted = audit(.fail, score: 0, id: "y", weight: 10)
        weighted.savingsBytes = 1_000
        XCTAssertNil(OrbitLighthouseLogic.withEstimatedSavings(weighted, device: .mobile).savingsMs)
    }

    func testRankedOpportunities_largestSavingFirstAndStable() {
        var small = audit(.fail, score: 0, id: "small"); small.savingsMs = 100
        var big = audit(.fail, score: 0, id: "big"); big.savingsMs = 900
        var bytesOnlyA = audit(.fail, score: 0, id: "bytesA"); bytesOnlyA.savingsBytes = 10
        var bytesOnlyB = audit(.fail, score: 0, id: "bytesB"); bytesOnlyB.savingsBytes = 10
        let passed = audit(.pass, score: 1, id: "passed")
        let ranked = OrbitLighthouseLogic.rankedOpportunities([small, bytesOnlyA, passed, big, bytesOnlyB])
        XCTAssertEqual(ranked.map(\.id), ["big", "small", "bytesA", "bytesB"])
    }

    func testUnusedCSS_wasteIsScaledToTransferSize() {
        var bundle = LHBundle()
        bundle.unusedCSS = [
            LHUnusedCSS(url: "https://example.com/app.css", totalBytes: 100_000, unusedBytes: 60_000, unusedRules: 300, nodeID: 5, selector: "link"),
            LHUnusedCSS(url: "", totalBytes: 10_000, unusedBytes: 500, unusedRules: 2, nodeID: 0, selector: "style"),
        ]
        bundle.networkRecords = [record("https://example.com/app.css", type: "stylesheet", mime: "text/css", size: 20_000)]
        let waste = OrbitLighthouseLogic.unusedCSSWaste(bundle: bundle)
        XCTAssertEqual(waste.count, 1, "the second sheet wastes under 2 KB")
        XCTAssertEqual(waste[0].wasted, 12_000)
    }

    func testUnusedCSSAudit_statesItsMethodAndSkippedSheets() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.cssSkipped = 2
        bundle.unusedCSS = [LHUnusedCSS(url: "", totalBytes: 20_000, unusedBytes: 10_000, unusedRules: 40, nodeID: 3, selector: "style")]
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "unused-css-rules" }
        XCTAssertEqual(audit?.savingsBytes, 10_000)
        XCTAssertTrue(audit?.description.contains("not a coverage trace") == true)
        XCTAssertTrue(audit?.description.contains("2 stylesheet(s) could not be read") == true)
        XCTAssertEqual(audit?.items.first?.nodeID, 3)
    }

    func testUnusedJavaScript_isNeverClaimedAsMeasured() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.networkRecords = [record("https://example.com/big.js", size: 400_000), record("https://example.com/small.js", size: 5_000)]
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "unused-javascript" }
        XCTAssertEqual(audit?.status, .manual)
        XCTAssertNil(audit?.score)
        XCTAssertNil(audit?.savingsBytes)
        XCTAssertEqual(audit?.items.map(\.url), ["https://example.com/big.js"])
        XCTAssertTrue(audit?.description.contains("no JavaScript coverage API") == true)
    }

    func testBestPractices_noLongerDuplicatesSecurityHeaderRows() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.networkRecords = [record("https://example.com/", type: "document", mime: "text/html", headers: ["content-security-policy": "default-src 'self'"])]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertTrue(report.audits.filter { $0.id.hasPrefix("security-header-") }.isEmpty)
    }

    func testSummaryText_includesSecurityScore() {
        var report = makeReport(perfScore: 90)
        report.scores.security = 77
        let line = OrbitLighthouseLogic.summaryText(report).split(separator: "\n").first { $0.hasPrefix("Security:") }
        XCTAssertTrue(line?.hasSuffix("77/100") == true)
    }

    // MARK: - Layout shifts

    func testCLSSessionWindow_groupsShiftsByGapAndTakesTheLargest() {
        let shifts: [(startMs: Double, value: Double)] = [(0, 0.1), (500, 0.05), (3_000, 0.2)]
        XCTAssertEqual(OrbitLighthouseLogic.clsSessionWindowMax(shifts), 0.2, accuracy: 1e-9)
        let burst: [(startMs: Double, value: Double)] = [(0, 0.1), (500, 0.1), (900, 0.1), (5_000, 0.05)]
        XCTAssertEqual(OrbitLighthouseLogic.clsSessionWindowMax(burst), 0.3, accuracy: 1e-9)
        XCTAssertEqual(OrbitLighthouseLogic.clsSessionWindowMax([]), 0)
    }

    func testCLSSessionWindow_endsAfterFiveSecondsEvenWithoutAGap() {
        let shifts: [(startMs: Double, value: Double)] = stride(from: 0.0, through: 5_400, by: 900).map { ($0, 0.1) }
        // Shifts at 0 to 4500 ms fill one window; 5400 ms starts the next.
        XCTAssertEqual(OrbitLighthouseLogic.clsSessionWindowMax(shifts), 0.6, accuracy: 1e-9)
    }

    func testCLSSessionWindow_sortsUnorderedShifts() {
        let shifts: [(startMs: Double, value: Double)] = [(3_000, 0.2), (0, 0.1), (500, 0.05)]
        XCTAssertEqual(OrbitLighthouseLogic.clsSessionWindowMax(shifts), 0.2, accuracy: 1e-9)
    }

    func testEffectiveCLS_usesTheWorstBurstOnlyWhenEveryShiftIsTimedAndNoneWasDropped() {
        var bundle = LHBundle()
        bundle.clsScore = 0.9
        XCTAssertEqual(OrbitLighthouseLogic.effectiveCLS(bundle), 0.9, "no shifts reported, so the running total stands")
        bundle.clsShifts = [LHClsShift(value: 0.1, sources: [], startMs: 0), LHClsShift(value: 0.2, sources: [], startMs: 9_000)]
        XCTAssertEqual(OrbitLighthouseLogic.effectiveCLS(bundle), 0.2, accuracy: 1e-9)
        bundle.clsShiftsTruncated = true
        XCTAssertEqual(OrbitLighthouseLogic.effectiveCLS(bundle), 0.9, "a truncated list cannot be windowed")
        bundle.clsShiftsTruncated = false
        bundle.clsShifts[1].startMs = nil
        XCTAssertEqual(OrbitLighthouseLogic.effectiveCLS(bundle), 0.9, "an untimed shift cannot be windowed")
    }

    func testCLSCulprits_splitEachShiftByMovedAreaAndMergeAcrossShifts() {
        let big = LHRect(x: 0, y: 0, width: 100, height: 100)
        let small = LHRect(x: 0, y: 0, width: 50, height: 50)
        let shifts = [
            LHLayoutShift(value: 0.3, sources: ["div.ad", "p.text"], startMs: 100, details: [
                LHShiftSource(selector: "div.ad", nodeID: 4, previous: big, current: big, live: big),
                LHShiftSource(selector: "p.text", previous: small, current: small),
            ]),
            LHLayoutShift(value: 0.1, sources: ["p.text"], startMs: 900, details: [LHShiftSource(selector: "p.text", nodeID: 5)]),
        ]
        let culprits = OrbitLighthouseLogic.clsCulprits(shifts)
        XCTAssertEqual(culprits.map(\.selector), ["div.ad", "p.text"])
        XCTAssertEqual(culprits[0].value, 0.24, accuracy: 1e-9)
        XCTAssertEqual(culprits[1].value, 0.06 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(culprits[0].nodeID, 4)
        XCTAssertEqual(culprits[1].nodeID, 5)
        XCTAssertEqual(culprits[1].shiftCount, 2)
        XCTAssertEqual(culprits[0].live, big)
        XCTAssertEqual(culprits.reduce(0) { $0 + $1.value }, 0.4, accuracy: 1e-9, "the attributed values add back to the shift totals")
    }

    func testCLSCulprits_fallBackToNamesWhenThereAreNoRectangles() {
        let culprits = OrbitLighthouseLogic.clsCulprits([LHLayoutShift(value: 0.2, sources: ["a", "b"])])
        XCTAssertEqual(culprits.map(\.value), [0.1, 0.1])
        XCTAssertTrue(OrbitLighthouseLogic.clsCulprits([LHLayoutShift(value: 0.2, sources: [])]).isEmpty)
    }

    func testCLSAudit_listsTheElementsThatMovedWithTheirNodes() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.clsScore = 0.2
        bundle.clsShifts = [LHClsShift(value: 0.2, sources: ["div.ad"], startMs: 500, details: [
            LHShiftSource(selector: "div.ad", nodeID: 9, previous: LHRect(x: 0, y: 0, width: 100, height: 100),
                          current: LHRect(x: 0, y: 50, width: 100, height: 100))
        ])]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        let audit = report.audits.first { $0.id == "cumulative-layout-shift" }
        XCTAssertEqual(audit?.items.first?.nodeID, 9)
        XCTAssertEqual(audit?.items.first?.selector, "div.ad")
        XCTAssertEqual(report.metrics.cls ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(report.metrics.clsShifts.first?.details?.first?.nodeID, 9)
        XCTAssertNotNil(audit?.howToFix, "a failing metric explains how to fix it")
    }

    // MARK: - LCP and TTFB breakdown

    func testLCPPhases_addUpToTheLCPTime() {
        let phases = OrbitLighthouseLogic.lcpPhases(lcpMs: 3_000, ttfbMs: 400, resourceStartMs: 900, resourceEndMs: 2_200)
        XCTAssertEqual(phases.map(\.name), ["Time to first byte", "Resource load delay", "Resource load time", "Element render delay"])
        XCTAssertEqual(phases.map(\.ms), [400, 500, 1_300, 800])
        XCTAssertEqual(phases.reduce(0) { $0 + $1.ms }, 3_000, accuracy: 1e-9)
    }

    func testLCPPhases_withoutAResourceTheRestIsRenderDelay() {
        let phases = OrbitLighthouseLogic.lcpPhases(lcpMs: 3_000, ttfbMs: 400, resourceStartMs: nil, resourceEndMs: nil)
        XCTAssertEqual(phases, [LHTimingPart(name: "Time to first byte", ms: 400), LHTimingPart(name: "Element render delay", ms: 2_600)])
    }

    func testLCPPhases_clampAwkwardTimingsSoTheyStillAddUp() {
        let early = OrbitLighthouseLogic.lcpPhases(lcpMs: 1_000, ttfbMs: 5_000, resourceStartMs: 200, resourceEndMs: 100)
        XCTAssertEqual(early.reduce(0) { $0 + $1.ms }, 1_000, accuracy: 1e-9)
        XCTAssertTrue(early.allSatisfy { $0.ms >= 0 })
        let late = OrbitLighthouseLogic.lcpPhases(lcpMs: 1_000, ttfbMs: nil, resourceStartMs: 50, resourceEndMs: 4_000)
        XCTAssertEqual(late.reduce(0) { $0 + $1.ms }, 1_000, accuracy: 1e-9)
        XCTAssertTrue(OrbitLighthouseLogic.lcpPhases(lcpMs: 0, ttfbMs: 10, resourceStartMs: nil, resourceEndMs: nil).isEmpty)
    }

    func testTTFBBreakdown_addsWhatTheNamedPartsDoNotExplain() {
        let parts = [LHTimingPart(name: "DNS lookup", ms: 30), LHTimingPart(name: "Waiting for the server", ms: 300), LHTimingPart(name: "Tiny", ms: 0.1)]
        let result = OrbitLighthouseLogic.ttfbBreakdown(parts: parts, ttfbMs: 400)
        XCTAssertEqual(result.map(\.name), ["DNS lookup", "Waiting for the server", "Queueing and other"])
        XCTAssertEqual(result.last?.ms ?? 0, 70, accuracy: 1e-9)
        XCTAssertEqual(OrbitLighthouseLogic.ttfbBreakdown(parts: parts, ttfbMs: 330).map(\.name), ["DNS lookup", "Waiting for the server"])
        XCTAssertEqual(OrbitLighthouseLogic.ttfbBreakdown(parts: parts, ttfbMs: nil).count, 2)
    }

    func testLCPAudit_carriesTheElementItsPhasesAndAFix() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.fcpMs = 1_000
        bundle.lcpMs = 3_000
        bundle.ttfbMs = 400
        bundle.lcpSelector = "img.hero"
        bundle.lcpDetail = LHLCPDetail(
            selector: "img.hero", tag: "img", nodeID: 7, snippet: "<img class=\"hero\">", url: "https://example.com/hero.jpg",
            rect: LHRect(x: 10, y: 20, width: 300, height: 200),
            phases: OrbitLighthouseLogic.lcpPhases(lcpMs: 3_000, ttfbMs: 400, resourceStartMs: 900, resourceEndMs: 2_200)
        )
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        let audit = report.audits.first { $0.id == "largest-contentful-paint" }
        XCTAssertEqual(audit?.items.first?.nodeID, 7)
        XCTAssertEqual(audit?.items.first?.selector, "img.hero")
        XCTAssertEqual(audit?.items.first?.url, "https://example.com/hero.jpg")
        XCTAssertEqual(audit?.items.dropFirst().compactMap(\.label).count, 4)
        XCTAssertEqual(report.metrics.lcpDetail?.nodeID, 7)
        XCTAssertEqual(report.metrics.lcpElement, "img.hero")
        XCTAssertNotNil(audit?.howToFix)
    }

    func testLCPLazyLoaded_isFlaggedAsAnAudit() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.lcpDetail = LHLCPDetail(selector: "img.hero", tag: "img", nodeID: 3, isLazyLoaded: true)
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "lcp-lazy-loaded" }
        XCTAssertEqual(audit?.status, .fail)
        XCTAssertEqual(audit?.items.first?.nodeID, 3)
        XCTAssertNotNil(audit?.howToFix)
    }

    func testTBTAudit_listsTheBlockingTasksLongestFirst() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.fcpMs = 1_000
        bundle.longTasksAPIAvailable = true
        bundle.longTasks = [
            LHLongTask(startMs: 500, durationMs: 900),     // before FCP, not counted
            LHLongTask(startMs: 1_500, durationMs: 120),
            LHLongTask(startMs: 2_000, durationMs: 400),
            LHLongTask(startMs: 3_000, durationMs: 40),    // under 50 ms, not a task that blocks
        ]
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "total-blocking-time" }
        XCTAssertEqual(audit?.items.map(\.wastedMs) ?? [], [350, 70])
        XCTAssertEqual(audit?.numericValue ?? 0, 420, accuracy: 1e-9, "the evidence adds up to the metric")
    }

    func testTTFBAudit_showsWhereTheTimeWent() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.ttfbMs = 1_200
        bundle.ttfbParts = [LHTimingPart(name: "Waiting for the server", ms: 1_000)]
        let audit = OrbitLighthouseLogic.score(bundle: bundle).audits.first { $0.id == "server-response-time" }
        XCTAssertEqual(audit?.items.map(\.label) ?? [], ["Waiting for the server", "Queueing and other"])
        XCTAssertEqual(audit?.status, .fail)
        XCTAssertNotNil(audit?.howToFix)
    }

    // MARK: - Filmstrip and screenshot

    func testFilmstripSelection_dropsNearDuplicatesAndKeepsTheEnds() {
        XCTAssertEqual(OrbitLighthouseLogic.filmstripSelection(completeness: [0, 0.01, 0.5, 0.505, 0.9, 1.0], maxFrames: 8), [0, 2, 4, 5])
        XCTAssertEqual(OrbitLighthouseLogic.filmstripSelection(completeness: [1, 1, 1, 1], maxFrames: 8), [0, 3])
        XCTAssertEqual(OrbitLighthouseLogic.filmstripSelection(completeness: [nil, nil, nil], maxFrames: 8), [0, 1, 2], "frames of unknown completeness are all kept")
    }

    func testFilmstripSelection_thinsEvenlyToTheLimit() {
        let picks = OrbitLighthouseLogic.filmstripSelection(completeness: [0, 0.2, 0.4, 0.6, 0.8, 1.0], maxFrames: 3)
        XCTAssertEqual(picks, [0, 3, 5])
        XCTAssertEqual(OrbitLighthouseLogic.filmstripSelection(completeness: [0, 0.5, 1.0], maxFrames: 1), [2])
        XCTAssertEqual(OrbitLighthouseLogic.filmstripSelection(completeness: [], maxFrames: 4), [])
        XCTAssertEqual(OrbitLighthouseLogic.filmstripSelection(completeness: [0.5], maxFrames: 4), [0])
    }

    func testFilmstripMilestones_tagTheFirstFrameAtOrAfterEachPaint() {
        let tags = OrbitLighthouseLogic.filmstripMilestones(frameMs: [100, 600, 1_100, 1_600], fcpMs: 500, lcpMs: 1_100)
        XCTAssertEqual(tags, [[], ["FCP"], ["LCP"], []])
        let same = OrbitLighthouseLogic.filmstripMilestones(frameMs: [100, 600], fcpMs: 550, lcpMs: 560)
        XCTAssertEqual(same, [[], ["FCP", "LCP"]])
        let missing = OrbitLighthouseLogic.filmstripMilestones(frameMs: [100, 600], fcpMs: nil, lcpMs: 9_000)
        XCTAssertEqual(missing, [[], []])
    }

    func testFractionalRect_clipsToTheViewportAndRejectsWhatIsOutside() {
        let viewport = LHRect(x: 0, y: 0, width: 1_000, height: 500)
        let inside = OrbitLighthouseLogic.fractionalRect(LHRect(x: 100, y: 50, width: 200, height: 100), in: viewport)
        XCTAssertEqual(inside, LHRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let partial = OrbitLighthouseLogic.fractionalRect(LHRect(x: 900, y: 400, width: 400, height: 400), in: viewport)
        XCTAssertEqual(partial, LHRect(x: 0.9, y: 0.8, width: 0.1, height: 0.2))
        XCTAssertNil(OrbitLighthouseLogic.fractionalRect(LHRect(x: 0, y: 900, width: 50, height: 50), in: viewport))
        XCTAssertNil(OrbitLighthouseLogic.fractionalRect(LHRect(x: 0, y: 0, width: 5, height: 5), in: LHRect(x: 0, y: 0, width: 0, height: 0)))
    }

    private func shot(pixels: (Int, Int) = (720, 450), viewport: (Double, Double) = (1_440, 900), scrollY: Double = 0) -> LHScreenshot {
        LHScreenshot(jpeg: Data([1, 2, 3]), pixelWidth: pixels.0, pixelHeight: pixels.1,
                     viewportWidth: viewport.0, viewportHeight: viewport.1, scrollY: scrollY)
    }

    func testScreenshot_onlyAlignsWhenThePictureHasThePageShape() {
        XCTAssertTrue(shot().alignsWithViewport)
        XCTAssertTrue(shot(pixels: (1_440, 910)).alignsWithViewport, "a small difference in shape is tolerated")
        XCTAssertFalse(shot(pixels: (720, 600)).alignsWithViewport)
        XCTAssertFalse(shot(viewport: (0, 0)).alignsWithViewport)
    }

    func testVisuals_splitMarksIntoDrawnAndListedOnly() {
        let inside = LHShotMark(kind: .lcp, label: "LCP element", selector: "img", rect: LHRect(x: 10, y: 10, width: 100, height: 100))
        let below = LHShotMark(kind: .layoutShift, label: "Shifted", selector: "div", rect: LHRect(x: 10, y: 2_000, width: 100, height: 100))
        var visuals = LHVisuals(screenshot: shot(), marks: [inside, below])
        XCTAssertEqual(visuals.drawnMarks.map(\.selector), ["img"])
        XCTAssertEqual(visuals.undrawnMarks.map(\.selector), ["div"])
        visuals.screenshot = shot(pixels: (720, 600))
        XCTAssertTrue(visuals.drawnMarks.isEmpty, "misaligned pictures draw nothing rather than draw in the wrong place")
        XCTAssertEqual(visuals.undrawnMarks.count, 2)
    }

    func testScore_buildsVisualsWithMarksFromTheLCPElementAndTheShifters() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.screenshot = shot()
        bundle.filmstrip = [LHFilmstripFrame(ms: 100, completeness: 0.4, jpeg: Data([9]))]
        bundle.lcpDetail = LHLCPDetail(selector: "img.hero", tag: "img", nodeID: 7, rect: LHRect(x: 0, y: 0, width: 400, height: 300))
        bundle.clsScore = 0.2
        bundle.clsShifts = [LHClsShift(value: 0.2, sources: ["div.ad"], startMs: 100, details: [
            LHShiftSource(selector: "div.ad", nodeID: 9, current: LHRect(x: 0, y: 300, width: 400, height: 100),
                          live: LHRect(x: 0, y: 320, width: 400, height: 100)),
            LHShiftSource(selector: "p.gone", current: LHRect(x: 0, y: 0, width: 10, height: 10)),
        ])]
        let visuals = OrbitLighthouseLogic.score(bundle: bundle).visuals
        XCTAssertEqual(visuals?.filmstrip.count, 1)
        let marks = visuals?.marks ?? []
        XCTAssertEqual(marks.map(\.kind), [.lcp, .layoutShift, .layoutShift])
        XCTAssertEqual(marks[1].rect, LHRect(x: 0, y: 320, width: 400, height: 100), "a live position wins over the one at the shift")
        XCTAssertNotNil(marks[2].detail, "a removed element is shown at where it shifted and says so")
    }

    func testScore_doesNotOfferWherePositionsAfterThePageScrolled() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.screenshot = shot(scrollY: 800)
        bundle.clsScore = 0.2
        bundle.clsShifts = [LHClsShift(value: 0.2, sources: ["p.gone"], startMs: 100, details: [
            LHShiftSource(selector: "p.gone", current: LHRect(x: 0, y: 0, width: 10, height: 10)),
        ])]
        XCTAssertEqual(OrbitLighthouseLogic.score(bundle: bundle).visuals?.marks.count, 0)
    }

    func testScore_hasNoVisualsWhenNothingWasCaptured() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        XCTAssertNil(OrbitLighthouseLogic.score(bundle: bundle).visuals)
        bundle.screenshotNote = "The tab was hidden."
        XCTAssertEqual(OrbitLighthouseLogic.score(bundle: bundle).visuals?.note, "The tab was hidden.")
    }

    func testVisuals_roundTripAndAreStrippedForSavedHistory() throws {
        var report = makeReport(perfScore: 80)
        report.visuals = LHVisuals(screenshot: shot(), filmstrip: [LHFilmstripFrame(ms: 5, jpeg: Data([7, 8]))],
                                   marks: [LHShotMark(kind: .lcp, label: "LCP element", selector: "img", rect: LHRect(x: 1, y: 2, width: 3, height: 4))])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(LHReport.self, from: data)
        XCTAssertEqual(decoded.visuals?.screenshot?.jpeg, Data([1, 2, 3]))
        XCTAssertEqual(decoded.visuals?.marks.first?.rect, LHRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertNil(report.strippingVisuals().visuals)
        XCTAssertEqual(report.strippingVisuals().scores.performance, 80)
    }

    func testOldSavedReports_stillDecodeWithoutTheNewFields() throws {
        let metrics = try JSONDecoder().decode(LHMetrics.self, from: Data(#"{"fcp":1000,"clsShifts":[{"value":0.1,"sources":["a"]}]}"#.utf8))
        XCTAssertEqual(metrics.fcp, 1_000)
        XCTAssertNil(metrics.lcpDetail)
        XCTAssertNil(metrics.clsShifts.first?.details)
        let audit = try JSONDecoder().decode(
            LHAuditResult.self,
            from: Data(#"{"id":"a","category":"seo","title":"t","description":"d","status":"fail","weight":1,"displayValue":"v","items":[]}"#.utf8)
        )
        XCTAssertNil(audit.howToFix)
    }

    // MARK: - Decoding the page's wire format

    func testDecodeRect_acceptsFourNumbersOnly() {
        XCTAssertEqual(OrbitLighthouseLogic.decodeRect([1.5, 2, 3, 4] as [Any]), LHRect(x: 1.5, y: 2, width: 3, height: 4))
        XCTAssertNil(OrbitLighthouseLogic.decodeRect([1, 2, 3] as [Any]))
        XCTAssertNil(OrbitLighthouseLogic.decodeRect(["a", 2, 3, 4] as [Any]))
        XCTAssertNil(OrbitLighthouseLogic.decodeRect(NSNull()))
        XCTAssertNil(OrbitLighthouseLogic.decodeRect(nil))
    }

    func testDecodeShifts_readsTimesSourcesAndPositions() {
        let wire: [[String: Any]] = [[
            "v": 0.12, "t": 840.5, "srcs": ["div.ad"],
            "det": [["sel": "div.ad", "id": 14, "prev": [0, 0, 10, 10], "cur": [0, 5, 10, 10], "live": NSNull()] as [String: Any]],
        ]]
        let shifts = OrbitLighthouseLogic.decodeShifts(wire)
        XCTAssertEqual(shifts.count, 1)
        XCTAssertEqual(shifts[0].value, 0.12, accuracy: 1e-9)
        XCTAssertEqual(shifts[0].startMs, 840.5)
        XCTAssertEqual(shifts[0].details.first?.nodeID, 14)
        XCTAssertEqual(shifts[0].details.first?.current, LHRect(x: 0, y: 5, width: 10, height: 10))
        XCTAssertNil(shifts[0].details.first?.live)
    }

    func testDecodeLCPDetail_buildsPhasesFromTheResourceTiming() {
        let wire: [String: Any] = [
            "sel": "img.hero", "tag": "img", "id": 5, "snip": "<img>", "url": "https://e.com/a.jpg",
            "rect": [1, 2, 3, 4], "load": 2_200.0, "render": 2_900.0, "lazy": true, "resStart": 900.0, "resEnd": 2_200.0,
        ]
        let detail = OrbitLighthouseLogic.decodeLCPDetail(wire, lcpMs: 3_000, ttfbMs: 400)
        XCTAssertEqual(detail?.nodeID, 5)
        XCTAssertEqual(detail?.isLazyLoaded, true)
        XCTAssertEqual(detail?.phases.map(\.ms) ?? [], [400, 500, 1_300, 800])
        XCTAssertNil(OrbitLighthouseLogic.decodeLCPDetail(wire, lcpMs: nil, ttfbMs: 400))
        XCTAssertNil(OrbitLighthouseLogic.decodeLCPDetail(nil, lcpMs: 3_000, ttfbMs: 400))
    }

    func testDecodeLCPDetail_textElementsHaveNoResourcePhases() {
        let wire: [String: Any] = ["sel": "h1", "tag": "h1", "id": 0, "url": "", "resStart": 10.0, "resEnd": 20.0]
        let detail = OrbitLighthouseLogic.decodeLCPDetail(wire, lcpMs: 1_000, ttfbMs: 100)
        XCTAssertNil(detail?.nodeID)
        XCTAssertNil(detail?.url)
        XCTAssertEqual(detail?.phases.map(\.name) ?? [], ["Time to first byte", "Element render delay"])
    }

    func testDecodeEvidenceAndTimingParts() {
        let nodes = OrbitLighthouseLogic.decodeEvidence([["sel": "a > b", "id": 3, "snip": "<b>"]])
        XCTAssertEqual(nodes.first?.selector, "a > b")
        XCTAssertEqual(nodes.first?.nodeID, 3)
        let parts = OrbitLighthouseLogic.decodeTimingParts([["n": "DNS lookup", "ms": 12.5], ["n": "bad"]])
        XCTAssertEqual(parts, [LHTimingPart(name: "DNS lookup", ms: 12.5)])
    }

    func testAccessibilityAudits_showWhichElementsFailed() {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.nestedInteractiveCount = 1
        bundle.nestedInteractiveNodes = [LHEvidenceNode(selector: "a.card", nodeID: 21, snippet: "<a class=\"card\">")]
        bundle.positiveTabindexCount = 1
        bundle.positiveTabindexNodes = [LHEvidenceNode(selector: "#go", nodeID: 22, snippet: "<a id=\"go\" tabindex=\"3\">")]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertEqual(report.audits.first { $0.id == "nested-interactive" }?.items.first?.nodeID, 21)
        XCTAssertEqual(report.audits.first { $0.id == "tabindex" }?.items.first?.selector, "#go")
        XCTAssertNotNil(report.audits.first { $0.id == "tabindex" }?.howToFix)
    }

    // MARK: - Score breakdown

    private func weighted(_ id: String, score: Double?, weight: Double) -> LHAuditResult {
        LHAuditResult(id: id, category: .performance, title: id, description: "",
                      status: score == nil ? .notApplicable : (score! >= 0.9 ? .pass : .fail),
                      score: score, weight: weight, displayValue: "v", items: [])
    }

    func testScoreBreakdown_pointsAddUpToTheCategoryScore() {
        let audits = [weighted("fcp", score: 1, weight: 10), weighted("lcp", score: 0.6, weight: 25),
                      weighted("tbt", score: nil, weight: 30), weighted("cls", score: 0, weight: 25)]
        let rows = OrbitLighthouseLogic.scoreBreakdown(audits, category: .performance)
        XCTAssertEqual(rows.map(\.id), ["cls", "lcp", "fcp", "tbt"], "largest loss first, unmeasured last")
        let measured = rows.filter(\.measured)
        XCTAssertEqual(measured.reduce(0) { $0 + $1.maxPoints }, 100, accuracy: 1e-9)
        // (10 * 1 + 25 * 0.6 + 25 * 0) / 60 of 100 points.
        XCTAssertEqual(measured.reduce(0) { $0 + $1.points }, 25 / 60.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(Int(measured.reduce(0) { $0 + $1.points }.rounded()), OrbitLighthouseLogic.categoryScore(audits, category: .performance))
        XCTAssertEqual(rows[1].maxPoints, 25 / 60.0 * 100, accuracy: 1e-9, "an unmeasured weight is shared among the rest")
        XCTAssertEqual(rows[1].points, rows[1].maxPoints * 0.6, accuracy: 1e-9)
        XCTAssertFalse(rows[3].measured)
        XCTAssertEqual(rows[3].maxPoints, 0)
    }

    func testScoreBreakdown_ignoresUnweightedAndOtherCategories() {
        var other = weighted("seo-thing", score: 0, weight: 5)
        other.category = .seo
        let audits = [weighted("diag", score: 0, weight: 0), other, weighted("fcp", score: 1, weight: 10)]
        XCTAssertEqual(OrbitLighthouseLogic.scoreBreakdown(audits, category: .performance).map(\.id), ["fcp"])
        XCTAssertTrue(OrbitLighthouseLogic.scoreBreakdown([], category: .performance).isEmpty)
    }

    func testScoreBreakdown_matchesAFullReport() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.fcpMs = 2_000
        bundle.lcpMs = 3_500
        bundle.clsScore = 0.2
        bundle.longTasksAPIAvailable = true
        bundle.longTasks = [LHLongTask(startMs: 2_500, durationMs: 350)]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        let rows = OrbitLighthouseLogic.scoreBreakdown(report.audits, category: .performance)
        let total = rows.reduce(0) { $0 + $1.points }
        XCTAssertEqual(Int(total.rounded()), report.scores.performance)
        XCTAssertTrue(rows.contains { !$0.measured && $0.id == "speed-index" })
    }

    // MARK: - Metric explanations

    func testMetricAssessment_statesTheReasonForEachBand() {
        XCTAssertTrue(LHMetricKind.lcp.assessment(for: 2_000).contains("within the good limit"))
        XCTAssertTrue(LHMetricKind.lcp.assessment(for: 2_000).contains("500 ms to spare"))
        XCTAssertTrue(LHMetricKind.lcp.assessment(for: 3_000).contains("over the good limit"))
        XCTAssertTrue(LHMetricKind.lcp.assessment(for: 3_000).contains("under the poor limit"))
        XCTAssertTrue(LHMetricKind.lcp.assessment(for: 5_000).contains("past the poor limit"))
        XCTAssertTrue(LHMetricKind.cls.assessment(for: 0.15).contains("0.050 over the good limit of 0.100"))
    }

    func testMetricKinds_haveGuidanceAndTheScoredOnesWeighToOneHundred() {
        for kind in LHMetricKind.allCases {
            XCTAssertFalse(kind.explanation.isEmpty, kind.rawValue)
            XCTAssertFalse(kind.improvement.isEmpty, kind.rawValue)
            XCTAssertFalse(kind.auditID.isEmpty, kind.rawValue)
        }
        XCTAssertEqual(Set(LHMetricKind.allCases.map(\.auditID)).count, LHMetricKind.allCases.count)
        XCTAssertEqual(LHMetricKind.allCases.reduce(0) { $0 + $1.scoreWeight }, 100)
        XCTAssertEqual(LHMetricKind.inp.scoreWeight, 0)
        XCTAssertEqual(LHMetricKind.ttfb.scoreWeight, 0)
    }

    func testMetricAuditWeights_matchTheKindWeights() {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.fcpMs = 1_000
        bundle.lcpMs = 1_000
        bundle.longTasksAPIAvailable = true
        bundle.siFrames = [(ms: 0, completeness: 0.5), (ms: 100, completeness: 1)]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        for kind in LHMetricKind.allCases where kind.scoreWeight > 0 {
            XCTAssertEqual(report.audits.first { $0.id == kind.auditID }?.weight, kind.scoreWeight, kind.rawValue)
        }
    }

    // MARK: - How to fix

    func testGuidance_isAddedOnlyToFailedAndWarningAudits() {
        var failed = audit(.fail, score: 0, id: "image-alt")
        failed.category = .accessibility
        XCTAssertNotNil(OrbitLighthouseLogic.withGuidance(failed).howToFix)
        var warning = failed
        warning.status = .warning
        XCTAssertNotNil(OrbitLighthouseLogic.withGuidance(warning).howToFix)
        var passed = failed
        passed.status = .pass
        XCTAssertNil(OrbitLighthouseLogic.withGuidance(passed).howToFix)
        XCTAssertNil(OrbitLighthouseLogic.withGuidance(audit(.fail, score: 0, id: "no-such-audit")).howToFix)
        var already = failed
        already.howToFix = "Keep this."
        XCTAssertEqual(OrbitLighthouseLogic.withGuidance(already).howToFix, "Keep this.")
    }

    func testGuidance_isSetOnFailingAuditsInAFullReport() throws {
        var bundle = LHBundle()
        bundle.mode = .snapshot
        bundle.images = [image(natural: (2000, 1000), shown: (500, 250), size: 160_000)]
        bundle.renderBlockers = [LHRenderBlocker(url: "https://example.com/a.css", type: "stylesheet", wastedMs: 80, transferSize: 100)]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        let mustFail = ["uses-responsive-images", "render-blocking-resources", "html-has-lang", "document-title", "meta-description"]
        let failingIDs = Set(report.audits.filter { $0.status == .fail }.map(\.id))
        XCTAssertTrue(Set(mustFail).isSubset(of: failingIDs), "missing from the failing audits: \(Set(mustFail).subtracting(failingIDs).sorted())")
        for id in mustFail {
            let audit = try XCTUnwrap(report.audits.first { $0.id == id }, id)
            let fix = try XCTUnwrap(audit.howToFix, id)
            XCTAssertFalse(fix.isEmpty, id)
        }
    }

    // MARK: - Reports

    func testSummaryText_listsMetricsAndTheLCPElement() {
        var report = makeReport(perfScore: 90)
        report.metrics.lcpDetail = LHLCPDetail(selector: "img.hero", tag: "img")
        let lines = OrbitLighthouseLogic.summaryText(report).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.hasPrefix("LCP 2.50 s (good)") })
        XCTAssertTrue(lines.contains("LCP element: img.hero"))
        var snapshot = report
        snapshot.mode = .snapshot
        XCTAssertFalse(OrbitLighthouseLogic.summaryText(snapshot).contains("LCP 2.50 s"), "a snapshot measured no load metrics")
    }

    func testHTMLReport_embedsThePicturesOnceAndExplainsFailures() {
        var report = makeReport(perfScore: 70)
        report.visuals = LHVisuals(
            screenshot: LHScreenshot(jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01]), pixelWidth: 720, pixelHeight: 450, viewportWidth: 1_440, viewportHeight: 900),
            filmstrip: [LHFilmstripFrame(ms: 200, completeness: 0.5, jpeg: Data([0xFF, 0xD8, 0xFF, 0xE1, 0x02]))],
            marks: [LHShotMark(kind: .lcp, label: "LCP element", selector: "img.hero", rect: LHRect(x: 0, y: 0, width: 100, height: 100))]
        )
        var failing = audit(.fail, score: 0, id: "image-alt")
        failing.title = "Image elements have [alt] text"
        failing.howToFix = "Add alt text."
        failing.items = [LHAuditItem(selector: "img.hero", url: "https://example.com/hero.jpg")]
        report.audits = [failing]
        let html = OrbitLighthouseLogic.generateHTMLReport(report)
        let shotBase64 = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01]).base64EncodedString()
        XCTAssertEqual(html.components(separatedBy: shotBase64).count - 1, 1, "the picture is in the page once, not again in the raw JSON")
        XCTAssertTrue(html.contains("Visual evidence"))
        XCTAssertTrue(html.contains("Filmstrip"))
        XCTAssertTrue(html.contains("LCP element"))
        XCTAssertTrue(html.contains("How to fix:</b> Add alt text."))
        XCTAssertTrue(html.contains("img.hero | https://example.com/hero.jpg") || html.contains("https://example.com/hero.jpg | img.hero"))
    }

    // MARK: - Helpers

    private func makeReport(perfScore: Int) -> LHReport {
        LHReport(
            id: UUID(),
            url: "https://example.com",
            pageTitle: "Example",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            mode: .navigation,
            device: .mobile,
            runCount: 1,
            enabledCategories: LHCategory.allCases,
            scores: LHScores(performance: perfScore, accessibility: 90, bestPractices: 80, seo: 85),
            metrics: LHMetrics(fcp: 1800, lcp: 2500, lcpElement: nil, tbt: 200, cls: 0.05,
                               clsShifts: [], inp: nil, ttfb: 400, speedIndex: 3500, longTaskCount: 1),
            audits: [],
            throttlingNote: "No throttling.",
            redistributionNote: nil
        )
    }
}
