// The device a Lighthouse run emulates, what the report says about it, and the history and comparison built on top.

import XCTest

final class OrbitInspectLighthouseEmulationTests: XCTestCase {

    // MARK: - Default device

    func testDevice_defaultsToDesktopButAChoiceTheUserMadeWins() {
        XCTAssertEqual(LHDevice.restored(from: nil), .desktop)
        XCTAssertEqual(LHDevice.restored(from: "desktop"), .desktop)
        XCTAssertEqual(LHDevice.restored(from: "mobile"), .mobile, "a saved Mobile choice must still win")
        XCTAssertEqual(LHDevice.restored(from: "tablet"), .desktop, "an unreadable saved value falls back to the default")
        XCTAssertEqual(LHBundle().device, .desktop)
    }

    func testDevice_emulationMatchesLighthouseScreenEmulation() {
        XCTAssertEqual(LHDevice.mobile.viewportWidth, 412)
        XCTAssertEqual(LHDevice.mobile.viewportHeight, 823)
        XCTAssertEqual(LHDevice.mobile.deviceScaleFactor, 1.75)
        XCTAssertTrue(LHDevice.mobile.usesMobileAgent)
        XCTAssertTrue(LHDevice.mobile.hasTouch)
        XCTAssertEqual(LHDevice.desktop.viewportWidth, 1350)
        XCTAssertEqual(LHDevice.desktop.viewportHeight, 940)
        XCTAssertEqual(LHDevice.desktop.deviceScaleFactor, 1)
        XCTAssertFalse(LHDevice.desktop.usesMobileAgent)
        XCTAssertFalse(LHDevice.desktop.hasTouch)
    }

    // MARK: - Emulation record

    private func emulation(_ device: LHDevice, width: Double? = nil, height: Double? = nil, dpr: Double? = nil,
                           touch: Int? = nil, mobileAgent: Bool? = nil, reloaded: Bool = true) -> LHEmulation {
        LHEmulation(device: device,
                    measuredWidth: width ?? Double(device.viewportWidth),
                    measuredHeight: height ?? Double(device.viewportHeight),
                    measuredDPR: dpr ?? device.deviceScaleFactor,
                    measuredTouchPoints: touch ?? (device.hasTouch ? 5 : 0),
                    measuredMobileAgent: mobileAgent ?? device.usesMobileAgent,
                    documentLoadedUnderAgent: reloaded)
    }

    func testEmulation_aFaithfulMobileRunHasNoProblems() {
        let record = emulation(.mobile)
        XCTAssertTrue(record.viewportApplied)
        XCTAssertEqual(record.problems, [])
        XCTAssertTrue(record.summary.contains("412 \u{00D7} 823"))
        XCTAssertTrue(record.summary.contains("DPR 1.75"))
        XCTAssertTrue(record.summary.contains("mobile user agent"))
    }

    func testEmulation_aRunLaidOutAtTheTabsOwnSizeSaysSo() {
        let record = emulation(.mobile, width: 1200, height: 800)
        XCTAssertFalse(record.viewportApplied)
        XCTAssertEqual(record.problems.count, 1)
        XCTAssertTrue(record.problems[0].contains("1200 \u{00D7} 800"), record.problems[0])
        XCTAssertTrue(record.problems[0].contains("412 \u{00D7} 823"), record.problems[0])
    }

    func testEmulation_aMobileRunWithoutAReloadExplainsTheAgentGap() {
        let record = emulation(.mobile, mobileAgent: false, reloaded: false)
        XCTAssertTrue(record.viewportApplied)
        XCTAssertEqual(record.problems.count, 1)
        XCTAssertTrue(record.problems[0].contains("did not reload"), record.problems[0])
    }

    func testEmulation_reportsADevicePixelRatioOrTouchMismatch() {
        let record = emulation(.mobile, dpr: 2, touch: 0)
        XCTAssertEqual(record.problems.count, 2)
        XCTAssertTrue(record.problems.contains { $0.contains("device pixel ratio of 2") })
        XCTAssertTrue(record.problems.contains { $0.contains("touch") })
    }

    func testEmulation_aDesktopRunExpectsNoMobileAgentOrTouch() {
        XCTAssertEqual(emulation(.desktop, reloaded: false).problems, [])
    }

    func testReport_carriesTheEmulationAndOldHistoryStillDecodes() throws {
        var bundle = LHBundle()
        bundle.url = "https://example.com/"
        bundle.device = .mobile
        bundle.emulation = emulation(.mobile)
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertEqual(report.emulation, bundle.emulation)
        XCTAssertEqual(OrbitLighthouseLogic.deviceLine(report), "Mobile, 412 \u{00D7} 823, DPR 1.75")
        XCTAssertEqual(OrbitLighthouseLogic.emulationProblems(report), [])

        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        XCTAssertEqual(try JSONDecoder().decode(LHReport.self, from: data).emulation, report.emulation)

        // A report saved before emulation existed has no key at all.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "emulation")
        let old = try JSONDecoder().decode(LHReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.emulation)
        XCTAssertEqual(OrbitLighthouseLogic.deviceLine(old), "Mobile scoring, device not emulated")
        XCTAssertEqual(OrbitLighthouseLogic.emulationProblems(old).count, 1)
    }

    func testDeviceLine_namesTheMeasuredSizeWhenEmulationDidNotTakeHold() {
        var bundle = LHBundle()
        bundle.device = .mobile
        bundle.emulation = emulation(.mobile, width: 1000, height: 700)
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertEqual(OrbitLighthouseLogic.deviceLine(report), "Mobile, measured at 1000 \u{00D7} 700, DPR 1.75")
    }

    func testThrottlingNote_isWordedForTheDevice() {
        XCTAssertEqual(OrbitLighthouseLogic.throttlingNote(device: .desktop), "No CPU or network throttling applied; metrics measured on this Mac.")
        let mobile = OrbitLighthouseLogic.throttlingNote(device: .mobile)
        XCTAssertTrue(mobile.contains("mobile viewport"))
        XCTAssertTrue(mobile.contains("no CPU or network throttling"))
        var bundle = LHBundle()
        bundle.device = .mobile
        XCTAssertEqual(OrbitLighthouseLogic.score(bundle: bundle).throttlingNote, mobile)
    }

    func testSummaryAndHTML_stateTheEmulatedDeviceAndItsProblems() {
        var bundle = LHBundle()
        bundle.url = "https://example.com/"
        bundle.device = .mobile
        bundle.emulation = emulation(.mobile, width: 900, height: 700)
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        let summary = OrbitLighthouseLogic.summaryText(report)
        XCTAssertTrue(summary.contains("Mobile, measured at 900 \u{00D7} 700"), summary)
        XCTAssertTrue(summary.contains("Note: The page was measured at 900 \u{00D7} 700"), summary)
        XCTAssertFalse(summary.contains("curves"))
        let html = OrbitLighthouseLogic.generateHTMLReport(report)
        XCTAssertTrue(html.contains("Mobile, measured at 900 \u{00D7} 700, DPR 1.75"))
        XCTAssertTrue(html.contains("The page was measured at 900 \u{00D7} 700"))
    }

    // MARK: - Content width

    private func audit(_ id: String, in report: LHReport) -> LHAuditResult? {
        report.audits.first { $0.id == id }
    }

    func testContentWidth_passesWhenThePageFitsTheViewport() {
        var bundle = LHBundle()
        bundle.viewportWidth = 412
        bundle.documentScrollWidth = 412
        let result = OrbitLighthouseLogic.contentWidthAudit(bundle: bundle)
        XCTAssertEqual(result.status, .pass)
        XCTAssertEqual(result.score, 1)
        XCTAssertEqual(result.category, .bestPractices)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testContentWidth_failsWithTheElementsThatStickOut() {
        var bundle = LHBundle()
        bundle.device = .mobile
        bundle.viewportWidth = 412
        bundle.documentScrollWidth = 640
        bundle.overflowNodes = [LHOverflowNode(selector: "div.wide", nodeID: 42, right: 640, snippet: "<div class=\"wide\">")]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        let result = try? XCTUnwrap(audit("content-width", in: report))
        XCTAssertEqual(result?.status, .fail)
        XCTAssertEqual(result?.score, 0)
        XCTAssertEqual(result?.numericValue, 640)
        XCTAssertEqual(result?.displayValue, "640 px wide in a 412 px viewport")
        XCTAssertEqual(result?.items.first?.nodeID, 42, "the offending element must be revealable in Elements")
        XCTAssertEqual(result?.items.first?.label, "Extends to 640 px, 228 px past the edge")
        XCTAssertNotNil(result?.howToFix)
    }

    func testContentWidth_isNotApplicableWithoutMeasurements() {
        let result = OrbitLighthouseLogic.contentWidthAudit(bundle: LHBundle())
        XCTAssertEqual(result.status, .notApplicable)
        XCTAssertNil(result.score)
    }

    func testFontSize_isOnlyScoredInMobileRuns() {
        var bundle = LHBundle()
        bundle.totalTextNodes = 10
        bundle.smallFontNodes = (0..<8).map { LHSmallFontNode(selector: "p:nth-child(\($0))", nodeID: $0 + 1, fontSize: 9, snippet: "<p>") }
        bundle.device = .desktop
        XCTAssertEqual(audit("font-size", in: OrbitLighthouseLogic.score(bundle: bundle))?.status, .notApplicable)
        bundle.device = .mobile
        let mobile = audit("font-size", in: OrbitLighthouseLogic.score(bundle: bundle))
        XCTAssertEqual(mobile?.status, .fail)
        XCTAssertEqual(mobile?.items.count, 8)
    }

    // MARK: - History and comparison

    private func report(url: String = "https://example.com/", device: LHDevice = .mobile, mode: LHRunMode = .navigation,
                        at seconds: TimeInterval, perf: Int = 80, lcp: Double = 2_000, cls: Double = 0.05,
                        audits: [LHAuditResult] = []) -> LHReport {
        LHReport(
            id: UUID(), url: url, pageTitle: "Example", timestamp: Date(timeIntervalSince1970: seconds),
            mode: mode, device: device, runCount: 1, enabledCategories: LHCategory.allCases,
            scores: LHScores(performance: perf, accessibility: 90, bestPractices: 80, seo: 85),
            metrics: LHMetrics(fcp: 1_000, lcp: lcp, tbt: 100, cls: cls, ttfb: 300, speedIndex: 1_500),
            audits: audits, throttlingNote: ""
        )
    }

    private func check(_ id: String, _ status: LHAuditStatus, score: Double?, value: String = "") -> LHAuditResult {
        LHAuditResult(id: id, category: .accessibility, title: id, description: "", status: status, score: score,
                      weight: 1, displayValue: value, items: [])
    }

    func testTrimmedHistory_keepsTheNewestRunsPerPageAndDevice() {
        var reports: [LHReport] = []
        for i in 0..<12 { reports.append(report(device: .mobile, at: Double(i))) }
        for i in 0..<3 { reports.append(report(device: .desktop, at: Double(100 + i))) }
        let kept = OrbitLighthouseLogic.trimmedHistory(reports, perPage: 10, total: 20)
        XCTAssertEqual(kept.filter { $0.device == .mobile }.count, 10)
        XCTAssertEqual(kept.filter { $0.device == .desktop }.count, 3, "a busy mobile history must not push desktop runs out")
        XCTAssertEqual(kept.first?.timestamp, Date(timeIntervalSince1970: 102), "newest first")
        XCTAssertFalse(kept.contains { $0.timestamp == Date(timeIntervalSince1970: 0) }, "the oldest mobile runs go first")
        XCTAssertEqual(OrbitLighthouseLogic.trimmedHistory(reports, perPage: 10, total: 5).count, 5)
    }

    func testComparisonBaseline_isTheLatestEarlierRunOfTheSamePageDeviceAndMode() {
        let target = report(at: 500)
        let older = report(at: 100)
        let previous = report(at: 400)
        let otherDevice = report(device: .desktop, at: 450)
        let otherPage = report(url: "https://example.com/about", at: 460)
        let otherMode = report(mode: .snapshot, at: 470)
        let later = report(at: 600)
        let history = [later, target, otherMode, otherPage, otherDevice, previous, older]
        XCTAssertEqual(OrbitLighthouseLogic.comparisonBaseline(for: target, in: history)?.id, previous.id)
        XCTAssertNil(OrbitLighthouseLogic.comparisonBaseline(for: older, in: history))
    }

    func testCompare_reportsScoreMetricAndAuditMovement() {
        let base = report(at: 100, perf: 70, lcp: 3_000, cls: 0.05, audits: [
            check("image-alt", .fail, score: 0, value: "2 images"),
            check("label", .pass, score: 1),
            check("link-name", .pass, score: 1),
            check("bypass", .notApplicable, score: nil)
        ])
        let target = report(at: 200, perf: 85, lcp: 2_000, cls: 0.055, audits: [
            check("image-alt", .pass, score: 1, value: "All have alt"),
            check("label", .fail, score: 0, value: "1 input"),
            check("link-name", .pass, score: 1),
            check("bypass", .fail, score: 0)
        ])
        let comparison = OrbitLighthouseLogic.compare(base: base, target: target)

        let perf = comparison.scores.first { $0.category == .performance }
        XCTAssertEqual(perf?.before, 70)
        XCTAssertEqual(perf?.after, 85)
        XCTAssertEqual(perf?.delta, 15)

        let lcp = try? XCTUnwrap(comparison.metrics.first { $0.kind == .lcp })
        XCTAssertEqual(lcp?.delta, -1_000)
        XCTAssertEqual(lcp?.improved, true)
        XCTAssertEqual(lcp?.isSignificant, true)
        XCTAssertEqual(lcp?.ratingBefore, .needsImprovement)
        XCTAssertEqual(lcp?.ratingAfter, .good)
        XCTAssertEqual(comparison.metrics.first { $0.kind == .cls }?.isSignificant, false, "0.005 of CLS is noise")

        XCTAssertEqual(comparison.fixes.map(\.id), ["image-alt"])
        XCTAssertEqual(comparison.fixes.first?.beforeValue, "2 images")
        XCTAssertEqual(comparison.fixes.first?.afterValue, "All have alt")
        XCTAssertEqual(comparison.regressions.map(\.id), ["label"], "an audit that was not applicable before has no earlier verdict to regress from")
        XCTAssertEqual(comparison.caveats, [])
    }

    func testCompare_metricNoiseFloor() {
        func change(_ before: Double, _ after: Double, _ kind: LHMetricKind = .lcp) -> LHComparison.MetricChange {
            LHComparison.MetricChange(kind: kind, before: before, after: after)
        }
        XCTAssertFalse(change(2_000, 2_040).isSignificant, "under 50 ms")
        XCTAssertFalse(change(2_000, 2_150).isSignificant, "under 10 percent")
        XCTAssertTrue(change(2_000, 2_250).isSignificant)
        XCTAssertTrue(change(200, 120, .tbt).isSignificant)
        XCTAssertTrue(change(0.05, 0.2, .cls).isSignificant)
        XCTAssertEqual(change(2_000, 2_250).deltaText, "+" + LHMetricKind.lcp.format(250))
        XCTAssertEqual(change(2_250, 2_000).deltaText, "\u{2212}" + LHMetricKind.lcp.format(250))
    }

    func testCompare_namesWhyTwoRunsMayNotBeComparable() {
        var base = report(device: .mobile, at: 100)
        base.emulation = LHEmulation(device: .mobile, measuredWidth: 1200, measuredHeight: 800, measuredDPR: 1.75,
                                     measuredTouchPoints: 5, measuredMobileAgent: true, documentLoadedUnderAgent: true)
        var target = report(url: "https://example.com/other", device: .desktop, mode: .snapshot, at: 200)
        target.runCount = 3
        let comparison = OrbitLighthouseLogic.compare(base: base, target: target)
        XCTAssertEqual(comparison.caveats.count, 5, comparison.caveats.joined(separator: "\n"))
        XCTAssertTrue(comparison.caveats.contains { $0.contains("Mobile") && $0.contains("Desktop") })
        XCTAssertTrue(comparison.metrics.isEmpty, "a snapshot measured no load metrics to compare")
    }
}
