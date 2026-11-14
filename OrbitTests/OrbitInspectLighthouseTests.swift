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
        for check in paneReport.checks where check.weight > 0 && check.state != .info {
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
        let metrics = LHMetrics(fcp: 1, lcp: 2, tbt: 3, cls: 0.4, inp: 5, ttfb: 6, speedIndex: 7)
        XCTAssertEqual(LHMetricKind.allCases.map { $0.value(in: metrics) ?? -1 }, [2, 0.4, 5, 1, 3, 7, 6])
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
