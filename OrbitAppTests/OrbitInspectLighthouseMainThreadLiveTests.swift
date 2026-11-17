// Lighthouse against real pages whose main-thread work is known in advance: scripts that block for set durations from
// set files, a page that never settles, outdated libraries, and the Timespan and Screen Size menu emulation paths.
// The pages record their own performance.now() spans, so every timing assertion compares Orbit's measurement with
// the page's ground truth under a stated margin instead of with a fixed clock.

import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Orbit

@MainActor
// Excluded on GitHub-hosted runners: hosts a real window, which needs the app open.
final class OrbitInspectLighthouseMainThreadLiveTests: XCTestCase {

    private typealias Route = LiveHTTPTestServer.Route

    private static func html(_ head: String, _ body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><title>Main-thread fixture</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="description" content="A fixture page for Orbit's Lighthouse tests">
        \(head)</head><body><main><h1>Main-thread fixture</h1><div id="grid"></div>\(body)</main></body></html>
        """
    }

    private static func js(_ source: String) -> Route { Route(contentType: "application/javascript", body: source) }
    private static func page(_ source: String) -> Route { Route(contentType: "text/html; charset=utf-8", body: source) }

    /// Each script blocks for a known time and records [start, end] in performance.now() on window.
    private static let heavyRoutes: [String: Route] = [
        "/": page(html("<script src=\"/block.js\"></script>", "<script src=\"/layout.js\"></script><script src=\"/timer.js\"></script>")),
        "/block.js": js("(function () { var t = performance.now(); while (performance.now() - t < 300) {} window.__block = [t, performance.now()]; })();"),
        "/layout.js": js("""
            setTimeout(function () {
              var grid = document.getElementById('grid'), html = '';
              for (var i = 0; i < 4000; i++) html += '<p>Paragraph ' + i + ' with enough words to wrap across a narrow column</p>';
              grid.innerHTML = html;
              var t = performance.now();
              for (var j = 0; j < 20; j++) { grid.style.width = (300 + j * 7) + 'px'; grid.offsetHeight; }
              window.__layout = [t, performance.now()];
            }, 600);
            """),
        "/timer.js": js("setTimeout(function () { var t = performance.now(); while (performance.now() - t < 200) {} window.__timer = [t, performance.now()]; }, 1500);"),
        "/timespan-work.js": js("setTimeout(function () { var t = performance.now(); while (performance.now() - t < 150) {} window.__work = [t, performance.now()]; }, 100);"),
    ]

    private func waitUntil(_ description: String, timeout: Duration = .seconds(10), _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for: \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The tab in the real page pane with DevTools open on Lighthouse.
    private func withPage(
        _ routes: [String: Route], timeout: TimeInterval = 150,
        _ body: @escaping (OrbitInspectSession, WebKitWebContents, OrbitLighthouseModel) async throws -> Void
    ) throws {
        try WebKitLiveEngineHost.runLive(timeout: timeout) {
            let server = try LiveHTTPTestServer(routes: routes)
            let contents = try await WebKitLiveEngineHost.makeContents()
            let size = NSSize(width: 1000, height: 900)
            let host = NSHostingView(rootView: WebContentsHostView(contents: contents).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            contents.setVisible(true)
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            let lighthouse = session.lighthouse
            let savedDevice = lighthouse.device
            let savedCap = lighthouse.ttiObservationCapMs
            defer {
                lighthouse.device = savedDevice
                lighthouse.ttiObservationCapMs = savedCap
                InspectorDeviceMode.shared.setPreset(.desktop, for: contents)
                OrbitDevToolsStore.shared.close(contents)
                server.stop()
                window.orderOut(nil)
                contents.close()
            }
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("agent hello") { session.pageURL.hasPrefix("http") }
            OrbitDevToolsStore.shared.open(contents, panel: .lighthouse, inspectAt: nil, armPicker: false)
            session.dock = .bottom
            session.select(panel: .lighthouse)
            try await body(session, contents, lighthouse)
        }
    }

    private func run(_ lighthouse: OrbitLighthouseModel, mode: LHRunMode, device: LHDevice = .desktop) async throws -> LHReport {
        lighthouse.device = device
        lighthouse.runMode = mode
        lighthouse.runCount = 1
        lighthouse.currentReport = nil
        lighthouse.startRun()
        try await waitUntil("the report", timeout: .seconds(90)) {
            if case .failed(let reason) = lighthouse.runState {
                XCTFail("the run failed: \(reason)")
                throw CancellationError()
            }
            return lighthouse.currentReport != nil
        }
        return try XCTUnwrap(lighthouse.currentReport)
    }

    private func span(_ session: OrbitInspectSession, _ name: String) async throws -> (start: Double, end: Double) {
        let value = try await session.evaluate("window.\(name) || null") as? [Double]
        let pair = try XCTUnwrap(value, "the page did not record \(name)")
        return (pair[0], pair[1])
    }

    func testNavigationMeasuresTTIBlockingIntervalsAndWhatRanInThem() throws {
        try withPage(Self.heavyRoutes) { session, _, lighthouse in
            let report = try await self.run(lighthouse, mode: .navigation)
            // The page's ground truth, read after the run's own reload and the restore are done (desktop needs no restore reload).
            let timer = try await self.span(session, "__timer")
            let block = try await self.span(session, "__block")

            let tti = try XCTUnwrap(report.tti)
            let value = try XCTUnwrap(tti.valueMs, tti.note ?? "no TTI")
            // TTI is the end of the last long task: the 200 ms timer task. The sampler sees its end at its next tick.
            XCTAssertGreaterThanOrEqual(value, timer.end - 5)
            XCTAssertLessThanOrEqual(value, timer.end + 40, "TTI \(value) vs the timer task's end \(timer.end)")
            XCTAssertFalse(tti.capReached)
            XCTAssertEqual(report.metrics.tti, value)
            let quiet = try XCTUnwrap(tti.quietWindowStartMs)
            XCTAssertGreaterThanOrEqual(tti.observedUntilMs, quiet + 5_000, "the quiet window must have been observed in full")

            let thread = try XCTUnwrap(report.mainThread)
            let timerBlock = try XCTUnwrap(thread.intervals.first { $0.startMs < timer.end && $0.endMs > timer.start },
                                           "no blocking interval covers the 200 ms timer task")
            // A lower bound within one 10 ms period, plus timer slack on a busy machine.
            XCTAssertGreaterThanOrEqual(timerBlock.durationMs, (timer.end - timer.start) - 15)
            XCTAssertLessThanOrEqual(timerBlock.durationMs, (timer.end - timer.start) + 60)
            let timerPart = try XCTUnwrap(timerBlock.attribution.first)
            XCTAssertEqual(timerPart.category, "Timer callbacks")
            XCTAssertTrue(timerPart.url?.hasSuffix("/timer.js") == true, "attributed to \(timerPart.url ?? "nothing")")
            XCTAssertFalse(timerPart.approximate)
            XCTAssertGreaterThanOrEqual(timerPart.ms, 180)

            let scriptBlock = try XCTUnwrap(thread.intervals.first { $0.startMs < block.end && $0.endMs > block.start },
                                            "no blocking interval covers the 300 ms script evaluation")
            XCTAssertGreaterThanOrEqual(scriptBlock.durationMs, (block.end - block.start) - 15)
            let evaluation = try XCTUnwrap(scriptBlock.attribution.first { $0.url?.hasSuffix("/block.js") == true },
                                           "block.js evaluation not attributed: \(scriptBlock.attribution)")
            XCTAssertEqual(evaluation.category, OrbitLighthouseLogic.scriptEvaluationCategory)
            XCTAssertTrue(evaluation.approximate)
            XCTAssertGreaterThanOrEqual(evaluation.ms, 250)

            XCTAssertGreaterThanOrEqual(thread.byCategory.first { $0.category == "Timer callbacks" }?.ms ?? 0, 190)
            XCTAssertTrue(thread.byScript.contains { $0.url?.hasSuffix("/timer.js") == true })
            let layout = try XCTUnwrap(thread.forcedLayouts.first { $0.url?.hasSuffix("/layout.js") == true },
                                       "forced layouts in layout.js not seen: \(thread.forcedLayouts)")
            XCTAssertGreaterThanOrEqual(layout.count, 5)

            // TBT counts the timer task (start after FCP, before TTI); the script ran before first paint.
            let tbt = try XCTUnwrap(report.metrics.tbt, "TBT must be measured from the sampler, not left out or zero")
            XCTAssertGreaterThanOrEqual(tbt, (timer.end - timer.start) - 50 - 20)
            let tbtAudit = try XCTUnwrap(report.audits.first { $0.id == "total-blocking-time" })
            XCTAssertTrue(tbtAudit.description.contains("timer loop"))
            XCTAssertEqual(report.audits.first { $0.id == "interactive" }?.numericValue, value)
            XCTAssertNotNil(report.audits.first { $0.id == "mainthread-work-breakdown" })
            XCTAssertTrue(report.audits.first { $0.id == "bootup-time" }?.items.contains { $0.url?.hasSuffix("/timer.js") == true } == true)
            XCTAssertTrue(OrbitLighthouseLogic.generateHTMLReport(report).contains("Blocking intervals"))
        }
    }

    func testAPageThatNeverSettlesReportsTTIAsUnmeasuredAtTheCap() throws {
        let routes: [String: Route] = [
            "/": Self.page(Self.html("", "<script>setInterval(function () { var t = performance.now(); while (performance.now() - t < 80) {} }, 1000);</script>"))
        ]
        try withPage(routes) { session, _, lighthouse in
            lighthouse.ttiObservationCapMs = 6_000
            let report = try await self.run(lighthouse, mode: .navigation)
            let tti = try XCTUnwrap(report.tti)
            XCTAssertNil(tti.valueMs)
            XCTAssertTrue(tti.capReached)
            XCTAssertGreaterThanOrEqual(tti.observedUntilMs, 6_000)
            XCTAssertTrue(tti.note?.contains("No 5 s window") == true, tti.note ?? "")
            XCTAssertNil(report.metrics.tti)
            XCTAssertEqual(report.audits.first { $0.id == "interactive" }?.status, .notApplicable)
            XCTAssertGreaterThan(report.metrics.tbt ?? 0, 0, "the 80 ms tasks after FCP still count towards TBT")
            let thread = try XCTUnwrap(report.mainThread)
            XCTAssertGreaterThanOrEqual(thread.intervals.count, 3)
            let page = session.pageURL
            XCTAssertTrue(thread.byScript.contains { $0.url == page }, "inline timers are charged to the page: \(thread.byScript.map { $0.url ?? "" })")
        }
    }

    func testOutdatedLibrariesAreMatchedAgainstTheAdvisoryTable() throws {
        let routes: [String: Route] = [
            "/": Self.page(Self.html("""
                <script>window.jQuery = function () {}; window.jQuery.fn = { jquery: '1.12.4' };
                window.moment = function () {}; window.moment.version = '2.29.1';</script>
                <script src="/vendor/lodash.min.js"></script>
                """, "")),
            "/vendor/lodash.min.js": Self.js("window._ = { VERSION: '4.17.15', noConflict: function () { return window._; } };"),
        ]
        try withPage(routes) { _, _, lighthouse in
            let report = try await self.run(lighthouse, mode: .snapshot)
            let names = Set((report.libraries ?? []).map(\.name))
            XCTAssertEqual(names, ["jQuery", "Lodash", "Moment.js"], "found \(report.libraries ?? [])")
            let audit = try XCTUnwrap(report.audits.first { $0.id == "no-vulnerable-libraries" })
            XCTAssertEqual(audit.status, .fail)
            let labels = Set(audit.items.compactMap(\.label))
            for expected in ["jQuery 1.12.4: CVE-2015-9251 (Medium)", "jQuery 1.12.4: CVE-2020-11022 (Medium)",
                             "Lodash 4.17.15: CVE-2021-23337 (High)", "Lodash 4.17.15: CVE-2020-8203 (High)",
                             "Moment.js 2.29.1: CVE-2022-31129 (High)", "Moment.js 2.29.1: CVE-2022-24785 (High)"] {
                XCTAssertTrue(labels.contains(expected), "missing \(expected) in \(labels.sorted())")
            }
            XCTAssertFalse(labels.contains("Lodash 4.17.15: CVE-2019-10744 (Critical)"), "4.17.15 is past that fix")
            XCTAssertFalse(labels.contains("Moment.js 2.29.1: CVE-2017-18214 (High)"), "2.29.1 is past that fix")
            XCTAssertTrue(audit.items.allSatisfy { $0.subLabel?.contains("found by") == true }, "every finding says where it was found")
            XCTAssertEqual(report.mainThread, nil, "a snapshot never ran the sampler")
        }
    }

    func testMobileTimespanEmulatesTheDeviceForScriptsAndSaysWhatItCouldNot() throws {
        try withPage(Self.heavyRoutes) { session, contents, lighthouse in
            let before = try await session.evaluate("[innerWidth, screen.width, outerWidth]") as? [Double]
            lighthouse.device = .mobile
            lighthouse.runMode = .timespan
            lighthouse.startTimespan()
            try await self.waitUntil("the phone layout", timeout: .seconds(10)) {
                (try await session.evaluate("innerWidth") as? Double) == 412
            }
            let seen = try await session.evaluate("""
                [screen.width, screen.height, outerWidth, outerHeight, devicePixelRatio,
                 matchMedia('(min-resolution: 1.75dppx)').matches, matchMedia('(min-resolution: 2dppx)').matches,
                 matchMedia('(-webkit-min-device-pixel-ratio: 1.5)').matches, matchMedia('(max-resolution: 168dpi)').matches,
                 matchMedia('(resolution: 1.75x)').matches, matchMedia('(pointer: coarse)').matches, navigator.maxTouchPoints]
                """) as? [Any]
            let values = try XCTUnwrap(seen)
            XCTAssertEqual(values[0] as? Double, 412)
            XCTAssertEqual(values[1] as? Double, 823)
            XCTAssertEqual(values[2] as? Double, 412)
            XCTAssertEqual(values[3] as? Double, 823)
            XCTAssertEqual(values[4] as? Double, 1.75)
            XCTAssertEqual(values[5] as? Bool, true, "min-resolution 1.75dppx")
            XCTAssertEqual(values[6] as? Bool, false, "min-resolution 2dppx")
            XCTAssertEqual(values[7] as? Bool, true, "-webkit-min-device-pixel-ratio 1.5")
            XCTAssertEqual(values[8] as? Bool, true, "max-resolution 168dpi is 1.75 dppx")
            XCTAssertEqual(values[9] as? Bool, true, "resolution 1.75x")
            XCTAssertEqual(values[10] as? Bool, true)
            XCTAssertGreaterThan((values[11] as? Double) ?? 0, 0)

            // The viewport changes before the recording starts in the page; work scheduled earlier is, rightly, not attributed.
            try await self.waitUntil("the recording armed in the page", timeout: .seconds(10)) {
                (try await session.evaluate("String(setTimeout).indexOf('[native code]') < 0") as? Bool) == true
            }
            // Work done during the recording, from a page-loaded script so it can be attributed.
            _ = try await session.evaluate("""
                var s = document.createElement('script'); s.src = '/timespan-work.js'; document.body.appendChild(s); 1
                """)
            try await Task.sleep(for: .milliseconds(1_200))
            lighthouse.stopTimespan()
            try await self.waitUntil("the timespan report", timeout: .seconds(30)) { lighthouse.currentReport != nil }
            let report = try XCTUnwrap(lighthouse.currentReport)
            XCTAssertEqual(report.mode, .timespan)
            let emulation = try XCTUnwrap(report.emulation)
            XCTAssertTrue(emulation.viewportApplied)
            XCTAssertFalse(emulation.documentLoadedUnderAgent)
            XCTAssertTrue(emulation.coverage.contains("the user agent the server saw, because this mode does not reload the page"))
            XCTAssertTrue(emulation.problems.contains { $0.contains("did not reload") })
            let thread = try XCTUnwrap(report.mainThread, "the timespan must run the sampler")
            let work = try await self.span(session, "__work")
            let detail = "work \(work), observed \(thread.observedFromMs)-\(thread.observedToMs), intervals \(thread.intervals.map { ($0.startMs, $0.endMs, $0.attribution.map { ($0.category, $0.url ?? "-", $0.ms) }) }), scripts \(thread.byScript.map { ($0.url ?? "-", $0.ms) }), kinds \(thread.byCategory.map { ($0.category, $0.ms) })"
            let workBlock = thread.intervals.first { $0.startMs < work.end && $0.endMs > work.start }
            XCTAssertNotNil(workBlock, "no interval covers the 150 ms task: " + detail)
            XCTAssertGreaterThanOrEqual(workBlock?.durationMs ?? 0, (work.end - work.start) - 15, detail)
            XCTAssertTrue(workBlock?.attribution.first?.url?.hasSuffix("/timespan-work.js") == true, detail)

            try await self.waitUntil("the tab's own size back", timeout: .seconds(5)) {
                (try await session.evaluate("innerWidth") as? Double) == before?[0]
            }
            let after = try await session.evaluate("[innerWidth, screen.width, outerWidth]") as? [Double]
            XCTAssertEqual(after, before, "screen and outer sizes must be the real ones again")
            XCTAssertFalse(session.device.isActive)
            XCTAssertNotEqual(contents.webView.customUserAgent?.contains("iPhone"), true)
        }
    }

    func testARunPutsBackTheOlderScreenSizeMenu() throws {
        try withPage(Self.heavyRoutes) { session, contents, lighthouse in
            InspectorDeviceMode.shared.setPreset(.iPhone, for: contents)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("the Screen Size menu's iPhone agent") {
                (try await session.evaluate("navigator.userAgent") as? String)?.contains("iPhone") == true
            }
            let agentBefore = contents.webView.customUserAgent

            let report = try await self.run(lighthouse, mode: .snapshot, device: .desktop)
            let emulation = try XCTUnwrap(report.emulation)
            XCTAssertTrue(emulation.viewportApplied, "the Screen Size menu must not shrink the emulated viewport: \(emulation.measuredWidth)")
            XCTAssertEqual(emulation.measuredWidth, 1350)

            XCTAssertEqual(InspectorDeviceMode.shared.preset(for: contents), .iPhone, "the menu's choice must come back")
            XCTAssertEqual(contents.webView.customUserAgent, agentBefore)
            try await self.waitUntil("the page reloaded under the menu's agent", timeout: .seconds(15)) {
                guard !contents.webView.isLoading else { return false }
                return (try await session.evaluate("navigator.userAgent") as? String)?.contains("iPhone") == true
            }
            XCTAssertFalse(session.device.isActive)
        }
    }
}
