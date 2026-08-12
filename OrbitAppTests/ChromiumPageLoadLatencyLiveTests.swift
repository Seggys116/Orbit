//  Real navigation latency through the real content-blocking URLLoaderFactory --
//  a bug serializing subresources on the browser UI thread shows up as cumulative latency.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumPageLoadLatencyLiveTests: XCTestCase {

    private func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    // A real, active (non-matching for these fixtures) blocker: the
    // per-request interceptor only installs when a blocker is active, and
    // Orbit ships with content blocking on by default.
    private func makeActiveBlocker() -> ContentBlocker {
        var ruleSet = ContentBlockerRuleSet()
        ruleSet.add(listText: "||orbit-latency-test-nonmatching-domain.example^\n", listID: "OrbitLatencyTestList")
        let blocker = ContentBlocker()
        blocker.setRuleSet(ruleSet)
        blocker.isEnabled = true
        return blocker
    }

    // MARK: - Sanity floor: a single-resource page must stay fast regardless of subresource count

    func testSingleResourcePageLoadsWithinATightBudget() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let elapsed = try LiveChromiumEngineHost.runLive { () -> Double in
            let page = LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-latency-single</body></html>")
            let server = try LiveHTTPTestServer(routes: ["/": page, "/warmup": page])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            await engine.applyContentBlocker(self.makeActiveBlocker(), session: engine.defaultSession)
            defer { Task { await engine.applyContentBlocker(nil, session: engine.defaultSession) } }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            // Warm-up: isolates the timed navigation from one-time renderer
            // spawn cost, so the budget measures steady-state behaviour, not process start-up.
            contents.load(server.baseURL.appendingPathComponent("warmup"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let start = ContinuousClock.now
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            return self.elapsedSeconds(since: start)
        }

        XCTAssertLessThan(elapsed, 2.0, "a single local subresource-free navigation took \(elapsed)s — even a wholesale engine-wide stall should still fail this before the many-subresource budget below")
    }

    // MARK: - The actual regression: many subresources must not serialize into a slow page

    func testPageWithManySubresourcesLoadsWithinBudget() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let subresourceCount = 40
        let elapsed = try LiveChromiumEngineHost.runLive { () -> Double in
            var routes: [String: LiveHTTPTestServer.Route] = [:]
            var scriptTags = ""
            for index in 0..<subresourceCount {
                routes["/r\(index).js"] = LiveHTTPTestServer.Route(contentType: "application/javascript", body: "// orbit-latency-resource-\(index)\n")
                scriptTags += "<script src=\"/r\(index).js\"></script>\n"
            }
            routes["/"] = LiveHTTPTestServer.Route(
                contentType: "text/html",
                body: "<html><body>\(scriptTags)<div id=\"orbit-latency-done\">done</div></body></html>"
            )
            routes["/warmup"] = LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>warm</body></html>")
            let server = try LiveHTTPTestServer(routes: routes)
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            await engine.applyContentBlocker(self.makeActiveBlocker(), session: engine.defaultSession)
            defer { Task { await engine.applyContentBlocker(nil, session: engine.defaultSession) } }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }

            // Warm-up on the same server/host, so connection set-up cost is
            // already paid before the timer starts.
            contents.load(server.baseURL.appendingPathComponent("warmup"))
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let start = ContinuousClock.now
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            return self.elapsedSeconds(since: start)
        }

        XCTAssertLessThan(
            elapsed, 6.0,
            "a page with \(subresourceCount) trivial same-host local subresources took \(elapsed)s to finish loading. "
                + "All \(subresourceCount) requests are local loopback with instant responses; this budget is already "
                + "several times a healthy load's expected time, so a miss here means something is serializing "
                + "per-request work (e.g. every subresource's content-blocking decision round-tripping through the "
                + "browser UI thread one at a time) rather than pipelining them."
        )
    }
}
