// Time to Interactive, TBT's window, main-thread attribution, and the vulnerable-library matcher and its advisory table.

import XCTest

final class OrbitInspectLighthouseMainThreadTests: XCTestCase {

    // MARK: - Time to Interactive

    private func tti(fcp: Double = 1_000, tasks: [(Double, Double)] = [], requests: [LHRequestSpan] = [], until: Double = 30_000) -> (ttiMs: Double, quietStartMs: Double)? {
        OrbitLighthouseLogic.timeToInteractive(fcpMs: fcp, tasks: tasks.map { (startMs: $0.0, endMs: $0.1) },
                                               requests: requests, observedUntilMs: until)
    }

    func testTTI_isFCPWhenNothingBlocksAfterIt() {
        let result = tti()
        XCTAssertEqual(result?.ttiMs, 1_000)
        XCTAssertEqual(result?.quietStartMs, 1_000)
    }

    func testTTI_isTheEndOfTheLastLongTaskBeforeTheQuietWindow() {
        let result = tti(tasks: [(1_200, 1_400), (3_000, 3_300), (9_000, 9_100)])
        XCTAssertEqual(result?.ttiMs, 3_300, "the 5 s from 3.3 s are quiet; the task at 9 s comes after the window")
        XCTAssertEqual(result?.quietStartMs, 3_300)
    }

    func testTTI_aTaskInsideTheWindowPushesItOn() {
        let result = tti(tasks: [(1_200, 1_400), (5_000, 5_100)])
        XCTAssertEqual(result?.ttiMs, 5_100)
    }

    func testTTI_ignoresTasksThatEndedBeforeFCP() {
        XCTAssertEqual(tti(tasks: [(100, 900)])?.ttiMs, 1_000)
    }

    func testTTI_aTaskStraddlingFCPCounts() {
        XCTAssertEqual(tti(tasks: [(900, 1_300)])?.ttiMs, 1_300)
    }

    func testTTI_isUnmeasuredUntilAWholeQuietWindowWasObserved() {
        XCTAssertNil(tti(tasks: [(1_200, 1_400)], until: 6_399), "the window from 1.4 s ends at 6.4 s")
        XCTAssertEqual(tti(tasks: [(1_200, 1_400)], until: 6_400)?.ttiMs, 1_400)
    }

    func testTTI_threeRequestsInFlightAreNotQuietButTwoAre() {
        let three = [LHRequestSpan(startMs: 500, endMs: 4_000), LHRequestSpan(startMs: 600, endMs: 4_000), LHRequestSpan(startMs: 700, endMs: 4_000)]
        let result = tti(requests: three)
        XCTAssertEqual(result?.quietStartMs, 4_000, "busy until the requests finish")
        XCTAssertEqual(result?.ttiMs, 1_000, "no long task, so TTI stays at FCP even though the quiet window starts later")
        XCTAssertEqual(tti(requests: Array(three.prefix(2)))?.quietStartMs, 1_000)
    }

    func testTTI_aRequestStillInFlightKeepsTheNetworkBusy() {
        let pending = [LHRequestSpan(startMs: 500, endMs: nil), LHRequestSpan(startMs: 600, endMs: nil), LHRequestSpan(startMs: 700, endMs: nil)]
        XCTAssertNil(tti(requests: pending, until: 20_000))
    }

    func testMaxInFlight_anEndAndAStartAtOneMomentDoNotOverlap() {
        let back = [LHRequestSpan(startMs: 0, endMs: 100), LHRequestSpan(startMs: 100, endMs: 200)]
        XCTAssertEqual(OrbitLighthouseLogic.maxInFlight(back, from: 0, to: 300, observedUntilMs: 300), 1)
        let overlapping = [LHRequestSpan(startMs: 0, endMs: 150), LHRequestSpan(startMs: 100, endMs: 200)]
        XCTAssertEqual(OrbitLighthouseLogic.maxInFlight(overlapping, from: 0, to: 300, observedUntilMs: 300), 2)
    }

    func testTBT_countsOnlyTasksBetweenFCPAndTTI() {
        let tasks = [LHLongTask(startMs: 1_500, durationMs: 150), LHLongTask(startMs: 9_000, durationMs: 400)]
        XCTAssertEqual(OrbitLighthouseLogic.computeTBT(longTasks: tasks, fcpMs: 1_000, apiAvailable: true, ttiMs: 1_650), 100)
        XCTAssertEqual(OrbitLighthouseLogic.computeTBT(longTasks: tasks, fcpMs: 1_000, apiAvailable: true), 450, "with no TTI every observed task after FCP counts")
    }

    // MARK: - Attribution

    func testAttribution_exactCallbacksThenApproximateScriptThenTheRest() {
        let work = [LHWorkSpan(category: "Timer callbacks", url: "https://a.test/t.js", startMs: 100, endMs: 180)]
        let scripts = [LHScriptSpan(url: "https://a.test/big.js", responseEndMs: 150, loadMs: 400)]
        let parts = OrbitLighthouseLogic.attribute(startMs: 100, endMs: 400, work: work, scripts: scripts)
        let script = parts.first { $0.category == OrbitLighthouseLogic.scriptEvaluationCategory }
        XCTAssertEqual(script?.url, "https://a.test/big.js")
        XCTAssertEqual(script?.ms ?? 0, 220, accuracy: 0.001, "300 ms blocked minus 80 ms of timed callback")
        XCTAssertEqual(script?.approximate, true)
        let timer = parts.first { $0.category == "Timer callbacks" }
        XCTAssertEqual(timer?.ms ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(timer?.approximate, false)
        XCTAssertNil(parts.first { $0.category == OrbitLighthouseLogic.unattributedCategory }, "everything was accounted for")
        XCTAssertEqual(parts.first?.category, OrbitLighthouseLogic.scriptEvaluationCategory, "largest share first")
    }

    func testAttribution_leavesWhatNothingExplainsUnattributed() {
        let parts = OrbitLighthouseLogic.attribute(startMs: 0, endMs: 120, work: [], scripts: [])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts.first?.category, OrbitLighthouseLogic.unattributedCategory)
        XCTAssertEqual(parts.first?.ms ?? 0, 120, accuracy: 0.001)
    }

    private func samplerBundle() -> LHBundle {
        var bundle = LHBundle()
        bundle.url = "https://a.test/"
        bundle.mode = .navigation
        bundle.fcpMs = 500
        bundle.samplerAvailable = true
        bundle.samplerFromMs = 0
        bundle.samplerToMs = 9_000
        bundle.samplerIntervals = [LHBlockingInterval(startMs: 1_000, endMs: 1_300, attribution: []),
                                   LHBlockingInterval(startMs: 2_000, endMs: 2_120, attribution: [])]
        bundle.workSpans = [LHWorkSpan(category: "Timer callbacks", url: "https://a.test/t.js", startMs: 2_000, endMs: 2_120)]
        bundle.workTotals = [LHMainThreadRow(category: "Timer callbacks", url: "https://a.test/t.js", ms: 140, count: 3, approximate: false)]
        bundle.scriptSpans = [LHScriptSpan(url: "https://a.test/big.js", responseEndMs: 990, loadMs: 1_310)]
        bundle.forcedLayouts = [LHMainThreadRow(category: "Forced layout", url: "https://a.test/t.js", ms: 30, count: 12, approximate: false)]
        bundle.longTasks = bundle.samplerIntervals.map { LHLongTask(startMs: $0.startMs, durationMs: $0.durationMs) }
        bundle.longTasksAPIAvailable = true
        bundle.longTaskSource = .lagSampler
        bundle.tti = LHTTI(valueMs: 2_120, quietWindowStartMs: 2_120, observedUntilMs: 9_000, capReached: false, note: nil)
        return bundle
    }

    func testMainThread_totalsByKindAndScriptWithApproximationsMarked() throws {
        let thread = try XCTUnwrap(OrbitLighthouseLogic.mainThread(bundle: samplerBundle()))
        let timer = try XCTUnwrap(thread.byCategory.first { $0.category == "Timer callbacks" })
        XCTAssertEqual(timer.ms, 140, "every timed callback counts, short ones too")
        XCTAssertFalse(timer.approximate)
        let eval = try XCTUnwrap(thread.byCategory.first { $0.category == OrbitLighthouseLogic.scriptEvaluationCategory })
        XCTAssertEqual(eval.ms, 300, accuracy: 0.001)
        XCTAssertTrue(eval.approximate)
        XCTAssertEqual(thread.byScript.first?.url, "https://a.test/big.js")
        XCTAssertEqual(thread.intervals.first?.durationMs, 300, "worst first")
        XCTAssertEqual(thread.intervals.last?.attribution.first?.category, "Timer callbacks")
        XCTAssertEqual(thread.forcedLayouts.first?.count, 12)
        XCTAssertNil(OrbitLighthouseLogic.mainThread(bundle: LHBundle()), "no sampler, no breakdown")
    }

    func testScore_usesTheSamplerForTBTAndReportsTTIAndTheBreakdown() throws {
        let report = OrbitLighthouseLogic.score(bundle: samplerBundle())
        XCTAssertEqual(report.metrics.tbt, 320, "both blocks start after FCP and before TTI: 250 + 70")
        XCTAssertEqual(report.metrics.tti, 2_120)
        let tbt = try XCTUnwrap(report.audits.first { $0.id == "total-blocking-time" })
        XCTAssertTrue(tbt.description.contains("timer loop"), tbt.description)
        let interactive = try XCTUnwrap(report.audits.first { $0.id == "interactive" })
        XCTAssertEqual(interactive.weight, 0, "shown but not scored, as in Lighthouse")
        XCTAssertEqual(interactive.numericValue, 2_120)
        XCTAssertNotNil(interactive.score)
        let long = try XCTUnwrap(report.audits.first { $0.id == "long-tasks" })
        XCTAssertEqual(long.items.count, 2)
        XCTAssertTrue(long.items[0].subLabel?.contains("big.js") == true, long.items[0].subLabel ?? "")
        XCTAssertTrue(long.items[0].subLabel?.contains("approximate") == true)
        XCTAssertNotNil(report.audits.first { $0.id == "mainthread-work-breakdown" })
        XCTAssertNotNil(report.audits.first { $0.id == "bootup-time" })
        XCTAssertEqual(report.mainThread?.intervals.count, 2)
        XCTAssertTrue(OrbitLighthouseLogic.generateHTMLReport(report).contains("Main thread"))

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(LHReport.self, from: data)
        XCTAssertEqual(decoded.mainThread, report.mainThread)
        XCTAssertEqual(decoded.tti, report.tti)
        XCTAssertEqual(decoded.metrics.tti, 2_120)
    }

    func testScore_withNoLongTaskSourceTBTIsNotMeasuredRatherThanZero() throws {
        var bundle = LHBundle()
        bundle.mode = .navigation
        bundle.fcpMs = 500
        bundle.longTasksAPIAvailable = false
        bundle.longTaskSource = .none
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertNil(report.metrics.tbt)
        XCTAssertEqual(report.audits.first { $0.id == "total-blocking-time" }?.status, .notApplicable)
        let interactive = try XCTUnwrap(report.audits.first { $0.id == "interactive" })
        XCTAssertEqual(interactive.status, .notApplicable)
        XCTAssertTrue(interactive.description.contains("sampler did not run"), interactive.description)
    }

    func testScore_anUnmeasuredTTISaysWhy() throws {
        var bundle = samplerBundle()
        bundle.tti = LHTTI(valueMs: nil, quietWindowStartMs: nil, observedUntilMs: 20_000, capReached: true,
                           note: "No 5 s window was seen within 20 s.")
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        XCTAssertNil(report.metrics.tti)
        let interactive = try XCTUnwrap(report.audits.first { $0.id == "interactive" })
        XCTAssertEqual(interactive.status, .notApplicable)
        XCTAssertTrue(interactive.description.hasPrefix("No 5 s window was seen within 20 s."))
        XCTAssertEqual(report.metrics.tbt, 320, "with no TTI every block after FCP counts: 250 + 70")
        XCTAssertTrue(OrbitLighthouseLogic.generateHTMLReport(report).contains("Time to Interactive not measured"))
    }

    func testComparison_includesTTI() {
        func report(_ tti: Double) -> LHReport {
            LHReport(id: UUID(), url: "https://a.test/", pageTitle: "", timestamp: Date(), mode: .navigation, device: .desktop,
                     runCount: 1, enabledCategories: LHCategory.allCases, scores: LHScores(),
                     metrics: LHMetrics(tti: tti), audits: [], throttlingNote: "")
        }
        let comparison = OrbitLighthouseLogic.compare(base: report(5_000), target: report(3_000))
        XCTAssertEqual(comparison.metrics.first { $0.kind == .tti }?.delta, -2_000)
    }

    // MARK: - Semver

    func testSemver_parsesAndOrdersLikeSemver() {
        XCTAssertEqual(LHSemver("1.12.4"), LHSemver(1, 12, 4))
        XCTAssertEqual(LHSemver("v3.5"), LHSemver(3, 5, 0))
        XCTAssertEqual(LHSemver("4"), LHSemver(4, 0, 0))
        XCTAssertEqual(LHSemver("3.5.0-rc.1")?.prerelease, "rc.1")
        XCTAssertEqual(LHSemver("2.29.4+build.7"), LHSemver(2, 29, 4))
        XCTAssertNil(LHSemver(""))
        XCTAssertNil(LHSemver("abc"))
        XCTAssertNil(LHSemver("1.2.3.4"))
        XCTAssertNil(LHSemver("1..2"))
        XCTAssertLessThan(LHSemver("1.9.1")!, LHSemver("1.12.0")!, "numeric, not string, order")
        XCTAssertLessThan(LHSemver("3.5.0-rc.1")!, LHSemver("3.5.0")!)
        XCTAssertLessThan(LHSemver("3.5.0-alpha")!, LHSemver("3.5.0-beta")!)
        XCTAssertLessThan(LHSemver("3.5.0-rc.2")!, LHSemver("3.5.0-rc.10")!)
        XCTAssertLessThan(LHSemver("3.5.0-1")!, LHSemver("3.5.0-alpha")!)
        XCTAssertFalse(LHSemver("3.5.0")! < LHSemver("3.5.0")!)
    }

    func testVersionRange_boundsAreInclusiveBelowAndExclusiveAbove() {
        let range = LHVersionRange(atLeast: LHSemver("1.2.0"), below: LHSemver("3.5.0"))
        XCTAssertFalse(range.contains(LHSemver("1.1.9")!))
        XCTAssertTrue(range.contains(LHSemver("1.2.0")!))
        XCTAssertTrue(range.contains(LHSemver("3.4.9")!))
        XCTAssertFalse(range.contains(LHSemver("3.5.0")!))
        XCTAssertEqual(range.text, ">= 1.2.0, < 3.5.0")
        XCTAssertTrue(LHVersionRange(atLeast: nil, below: nil).contains(LHSemver("99.0.0")!))
        XCTAssertEqual(LHVersionRange(atLeast: nil, below: nil).text, "all versions")
    }

    // MARK: - Advisory table

    /// Every row as published: library, identifier, severity, affected range and fixed version.
    func testAdvisoryTable_rowsAreExactlyThePublishedOnes() {
        let expected: [(String, String, LHSeverity, String, String?)] = [
            ("jQuery", "CVE-2015-9251", .medium, "< 3.0.0", "3.0.0"),
            ("jQuery", "CVE-2019-11358", .medium, "< 3.4.0", "3.4.0"),
            ("jQuery", "CVE-2020-11022", .medium, ">= 1.2.0, < 3.5.0", "3.5.0"),
            ("jQuery", "CVE-2020-11023", .medium, ">= 1.0.3, < 3.5.0", "3.5.0"),
            ("Bootstrap", "CVE-2019-8331", .medium, "< 3.4.1 or >= 4.0.0, < 4.3.1", "3.4.1 or 4.3.1"),
            ("Lodash", "CVE-2019-10744", .critical, "< 4.17.12", "4.17.12"),
            ("Lodash", "CVE-2020-8203", .high, "< 4.17.19", "4.17.19"),
            ("Lodash", "CVE-2020-28500", .medium, "< 4.17.21", "4.17.21"),
            ("Lodash", "CVE-2021-23337", .high, "< 4.17.21", "4.17.21"),
            ("Moment.js", "CVE-2017-18214", .high, "< 2.19.3", "2.19.3"),
            ("Moment.js", "CVE-2022-24785", .high, "< 2.29.2", "2.29.2"),
            ("Moment.js", "CVE-2022-31129", .high, ">= 2.18.0, < 2.29.4", "2.29.4"),
            ("AngularJS", "CVE-2019-10768", .high, "< 1.7.9", "1.7.9"),
            ("AngularJS", "CVE-2020-7676", .medium, "< 1.8.0", "1.8.0"),
            ("AngularJS", "CVE-2022-25869", .medium, "all versions", nil),
        ]
        let rows = OrbitLighthouseLogic.advisories
        XCTAssertEqual(rows.count, expected.count)
        for (row, want) in zip(rows, expected) {
            XCTAssertEqual(row.library, want.0)
            XCTAssertEqual(row.id, want.1)
            XCTAssertEqual(row.severity, want.2, row.id)
            XCTAssertEqual(row.rangeText, want.3, row.id)
            XCTAssertEqual(row.fixedIn, want.4, row.id)
            XCTAssertTrue(row.id.hasPrefix("CVE-"), row.id)
            XCTAssertFalse(row.summary.isEmpty)
        }
    }

    private func justBelow(_ v: LHSemver) -> LHSemver {
        if v.patch > 0 { return LHSemver(v.major, v.minor, v.patch - 1) }
        if v.minor > 0 { return LHSemver(v.major, v.minor - 1, 999) }
        return LHSemver(v.major - 1, 999, 999)
    }

    private func justAbove(_ v: LHSemver) -> LHSemver { LHSemver(v.major, v.minor, v.patch + 1) }

    /// For every range of every row: just below the fix is affected, the fix itself and just above it are not; the
    /// lower bound itself is affected and just below it is not.
    func testAdvisoryTable_everyRangeBoundary() {
        for advisory in OrbitLighthouseLogic.advisories {
            for range in advisory.ranges {
                if let upper = range.below {
                    XCTAssertTrue(range.contains(justBelow(upper)), "\(advisory.id) just below \(upper)")
                    XCTAssertFalse(range.contains(upper), "\(advisory.id) at \(upper)")
                    XCTAssertFalse(range.contains(justAbove(upper)), "\(advisory.id) just above \(upper)")
                }
                if let lower = range.atLeast {
                    XCTAssertTrue(range.contains(lower), "\(advisory.id) at lower bound \(lower)")
                    XCTAssertTrue(range.contains(justAbove(lower)), "\(advisory.id) just above lower bound \(lower)")
                    XCTAssertFalse(range.contains(justBelow(lower)), "\(advisory.id) just below lower bound \(lower)")
                }
                if range.atLeast == nil && range.below == nil {
                    XCTAssertTrue(range.contains(LHSemver(1, 8, 3)), "\(advisory.id) has no fixed release")
                }
            }
        }
        // Bootstrap's two ranges leave 3.4.1 to 3.x and 4.3.1 on clear, and 4.0.0 to 4.3.0 affected.
        let bootstrap = OrbitLighthouseLogic.advisories.first { $0.id == "CVE-2019-8331" }!
        XCTAssertTrue(bootstrap.affects(LHSemver("3.3.7")!))
        XCTAssertFalse(bootstrap.affects(LHSemver("3.4.1")!))
        XCTAssertFalse(bootstrap.affects(LHSemver("3.999.999")!))
        XCTAssertTrue(bootstrap.affects(LHSemver("4.0.0")!))
        XCTAssertTrue(bootstrap.affects(LHSemver("4.3.0")!))
        XCTAssertFalse(bootstrap.affects(LHSemver("4.3.1")!))
    }

    func testVulnerabilities_matchByVersionAndNeverGuessAMissingOne() {
        let libraries = [
            LHLibrary(name: "jQuery", version: "1.12.4", evidence: ["global jQuery"]),
            LHLibrary(name: "Lodash", version: "4.17.15", evidence: ["loads lodash.min.js"]),
            LHLibrary(name: "Moment.js", version: nil, evidence: ["loads moment.min.js"]),
            LHLibrary(name: "Bootstrap", version: "5.3.2", evidence: ["global bootstrap"]),
            LHLibrary(name: "Lodash / Underscore", version: "1.13.6", evidence: ["global _ 1.13.6"]),
        ]
        let (findings, unversioned) = OrbitLighthouseLogic.vulnerabilities(in: libraries)
        XCTAssertEqual(Set(findings.filter { $0.library == "jQuery" }.map(\.advisoryID)),
                       ["CVE-2015-9251", "CVE-2019-11358", "CVE-2020-11022", "CVE-2020-11023"])
        XCTAssertEqual(Set(findings.filter { $0.library == "Lodash" }.map(\.advisoryID)),
                       ["CVE-2020-8203", "CVE-2020-28500", "CVE-2021-23337"], "4.17.15 is past the 4.17.12 fix")
        XCTAssertTrue(findings.allSatisfy { $0.library != "Bootstrap" }, "5.3.2 is not affected")
        XCTAssertTrue(findings.allSatisfy { $0.library != "Lodash / Underscore" }, "an ambiguous `_` is never matched against Lodash")
        XCTAssertEqual(unversioned.map(\.name), ["Moment.js"])
        XCTAssertEqual(findings.first?.severity, .high, "worst first")
        XCTAssertEqual(findings.first { $0.advisoryID == "CVE-2020-11022" }?.evidence, ["global jQuery"])
    }

    func testVulnerableLibrariesAudit_listsFindingsTheCaveatAndUnknownVersions() throws {
        var bundle = LHBundle()
        bundle.libraries = [
            LHLibrary(name: "jQuery", version: "3.4.1", evidence: ["jQuery.fn.jquery = 3.4.1"]),
            LHLibrary(name: "Moment.js", version: nil, evidence: ["loads moment.min.js"]),
            LHLibrary(name: "AngularJS", version: "1.8.3", evidence: ["global angular 1.8.3"]),
        ]
        let report = OrbitLighthouseLogic.score(bundle: bundle)
        let audit = try XCTUnwrap(report.audits.first { $0.id == "no-vulnerable-libraries" })
        XCTAssertEqual(audit.category, .bestPractices)
        XCTAssertEqual(audit.status, .fail)
        XCTAssertTrue(audit.description.contains("back-ported or patched build"))
        let labels = audit.items.compactMap(\.label)
        XCTAssertTrue(labels.contains("jQuery 3.4.1: CVE-2020-11022 (Medium)"), labels.joined(separator: "\n"))
        XCTAssertTrue(labels.contains("AngularJS 1.8.3: CVE-2022-25869 (Medium)"))
        XCTAssertTrue(labels.contains("AngularJS 1.8.3: end of life"))
        XCTAssertTrue(labels.contains("Moment.js: version not detected"))
        let item = try XCTUnwrap(audit.items.first { $0.label == "jQuery 3.4.1: CVE-2020-11022 (Medium)" })
        XCTAssertEqual(item.subLabel, "Affected >= 1.2.0, < 3.5.0; fixed in 3.5.0; found by jQuery.fn.jquery = 3.4.1")
        XCTAssertNotNil(audit.howToFix)

        var clean = LHBundle()
        clean.libraries = [LHLibrary(name: "jQuery", version: "3.7.1", evidence: [])]
        let passed = OrbitLighthouseLogic.vulnerableLibrariesAudit(bundle: clean)
        XCTAssertEqual(passed.status, .pass)
        XCTAssertEqual(passed.displayValue, "No known vulnerabilities")
        XCTAssertEqual(OrbitLighthouseLogic.vulnerableLibrariesAudit(bundle: LHBundle()).displayValue, "No libraries detected")
    }

    // MARK: - Emulation coverage

    func testCoverage_statesWhatEachModeEmulated() {
        let snapshot = LHEmulation(device: .mobile, measuredWidth: 412, measuredHeight: 823, measuredDPR: 1.75,
                                   measuredTouchPoints: 5, measuredMobileAgent: false, documentLoadedUnderAgent: false)
        XCTAssertTrue(snapshot.coverage.contains("Not emulated: the user agent the server saw, because this mode does not reload the page"), snapshot.coverage)
        XCTAssertTrue(snapshot.coverage.contains("matchMedia resolution queries"))
        XCTAssertTrue(snapshot.coverage.contains("srcset"))
        XCTAssertTrue(snapshot.coverage.contains("CPU and network speed"))
        let navigation = LHEmulation(device: .mobile, measuredWidth: 412, measuredHeight: 823, measuredDPR: 1.75,
                                     measuredTouchPoints: 5, measuredMobileAgent: true, documentLoadedUnderAgent: true)
        XCTAssertTrue(navigation.coverage.contains("the user agent sent to the server"))
        XCTAssertFalse(navigation.coverage.contains("server saw"))
    }
}
