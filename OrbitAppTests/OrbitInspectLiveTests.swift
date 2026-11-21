// Drives every inspector tool against real WebKit and a real HTTP page, then renders each panel to a PNG.

import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class OrbitInspectLiveTests: XCTestCase {

    private func waitUntil(
        _ description: String, timeout: Duration = .seconds(10), _ predicate: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for: \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testEveryToolSeesARealPage() throws {
        try WebKitLiveEngineHost.runLive(timeout: 180) {
            let server = try LiveHTTPTestServer(routes: OrbitInspectFixture.routes())
            let contents = try await WebKitLiveEngineHost.makeContents()
            let window = LiveContextMenuGesture.host(contents)
            defer {
                server.stop()
                window.orderOut(nil)
                contents.close()
            }

            // Native network capture and the early console stub record the page load while DevTools is closed.
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            try await self.waitUntil("network records", timeout: .seconds(8)) {
                session.network.records.contains { $0.url.hasSuffix("/api/data.json") && $0.status == 200 }
            }
            let css = try XCTUnwrap(session.network.records.first { $0.url.hasSuffix("/app.css") })
            XCTAssertEqual(css.status, 200)
            XCTAssertEqual(css.resourceType, "stylesheet")
            XCTAssertFalse(css.requestHeaders.isEmpty, "native capture must include request headers for a stylesheet load")
            XCTAssertNotNil(css.responseHeader("Content-Type"))
            let document = try XCTUnwrap(
                session.network.records.first { $0.resourceType == "document" },
                "expected a document record, got \(session.network.records.map { "\($0.resourceType) \($0.status) \($0.url)" })"
            )
            XCTAssertEqual(document.responseHeader("X-Powered-By"), "Next.js",
                           "headers: \(document.responseHeaders.map { "\($0.name)=\($0.value)" })")
            let fetched = try XCTUnwrap(session.network.records.first { $0.url.hasSuffix("/api/data.json") })
            XCTAssertEqual(fetched.requestHeader("X-Fixture"), "yes", "a custom request header must show up")

            try await self.waitUntil("uncaught exception buffered while DevTools is closed", timeout: .seconds(8)) {
                (try await session.evaluate("""
                    window.__orbitInspectEarly?.con.some(entry =>
                        entry.level === 'exception' && entry.args[0].v.includes('late failure')) === true
                    """) as? Bool) == true
            }
            OrbitDevToolsStore.shared.open(contents, panel: .elements, inspectAt: nil, armPicker: false)
            XCTAssertTrue(session.isPresented)
            try await self.waitUntil("historical console errors", timeout: .seconds(8)) { session.console.errorCount >= 2 }
            XCTAssertTrue(session.console.errorMessages.contains { $0.contains("late failure") },
                          "an uncaught exception from before opening must appear. Got: \(session.console.errorMessages)")
            XCTAssertGreaterThanOrEqual(session.console.entries.count, 5)

            session.refresh(force: true)
            try await self.waitUntil("elements tree", timeout: .seconds(8)) { !session.elements.visibleRows.isEmpty }
            session.inspect(at: CGPoint(x: 40, y: 30))
            try await self.waitUntil("selected node", timeout: .seconds(8)) { session.elements.selectedID != nil }
            let selected = try XCTUnwrap(session.elements.selectedID.flatMap { session.elements.nodes[$0] })
            XCTAssertEqual(selected.name, "header", "the point (40,30) is inside the header. Got \(selected.name)")
            try await self.waitUntil("matched rules", timeout: .seconds(8)) {
                session.elements.styleRules.contains { $0.selector.contains(".card") }
            }
            let rule = try XCTUnwrap(session.elements.styleRules.first { $0.selector == ".card" && $0.mediaQuery != nil })
            session.elements.setRuleProperty(
                sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath,
                property: "padding-top", value: "37px"
            )
            try await self.waitUntil("live CSS edit applied", timeout: .seconds(5)) {
                let value = try await session.evaluate("getComputedStyle(document.getElementById('top')).paddingTop") as? String
                return value == "37px"
            }
            // The highlight must not be stuck on the page while nothing is being picked or hovered.
            let visibleLayers = try await session.evaluate("""
                (function(){ var h = document.getElementById('orbit-inspect-root'); if (!h || !h.shadowRoot) return 0;
                return Array.prototype.filter.call(h.shadowRoot.querySelectorAll('[data-part]'), function(l){ return l.dataset.part !== 'shield' && getComputedStyle(l).display !== 'none'; }).length; })()
                """) as? Int
            XCTAssertEqual(visibleLayers ?? 0, 0, "no highlight should be drawn when nothing is hovered or picked")

            session.select(panel: .sources)
            try await self.waitUntil("source files", timeout: .seconds(8)) {
                session.sources.files.contains { $0.url.hasSuffix("/app.js") }
            }
            let appJS = try XCTUnwrap(session.sources.files.first { $0.url.hasSuffix("/app.js") })
            session.sources.openFile(id: appJS.id)
            try await self.waitUntil("app.js text", timeout: .seconds(8)) {
                session.sources.loadStates[appJS.id]?.text?.contains("fixture loaded") == true
            }

            // MARK: Application: storage and native cookies including HttpOnly
            session.select(panel: .application)
            session.refresh(force: true)
            try await self.waitUntil("local storage", timeout: .seconds(8)) {
                session.application.localStorageEntries.contains { $0.key == "theme" }
            }
            try await self.waitUntil("native cookies", timeout: .seconds(8)) {
                session.application.cookieRecords.contains { $0.name == "sid" }
            }
            let sid = try XCTUnwrap(session.application.cookieRecords.first { $0.name == "sid" })
            XCTAssertTrue(sid.isHTTPOnly, "the HttpOnly session cookie must be visible, which page script can never do")

            session.select(panel: .frameworks)
            session.refresh(force: true)
            try await self.waitUntil("framework detection", timeout: .seconds(8)) { session.frameworks.primaryName != nil }
            XCTAssertTrue(session.frameworks.primaryName?.contains("Next") == true, "got \(session.frameworks.primaryName ?? "nil")")

            session.select(panel: .animations)
            try await self.waitUntil("animations", timeout: .seconds(8)) { !session.animations.records.isEmpty }

            session.select(panel: .performance)
            let vitals = await session.performance.collectVitalsNow()
            XCTAssertNotNil(vitals.ttfb, "navigation timing must be available")

            // MARK: Lighthouse: scores must be reproducible for the same page
            session.select(panel: .lighthouse)
            session.lighthouse.runMode = .snapshot
            session.lighthouse.startRun()
            try await self.waitUntil("first audit", timeout: .seconds(40)) { session.lighthouse.currentReport != nil }
            let first = try XCTUnwrap(session.lighthouse.currentReport)
            let firstA11y = first.scores.accessibility
            let firstSEO = first.scores.seo
            session.lighthouse.currentReport = nil
            session.lighthouse.startRun()
            try await self.waitUntil("second audit", timeout: .seconds(40)) { session.lighthouse.currentReport != nil }
            let second = try XCTUnwrap(session.lighthouse.currentReport)
            XCTAssertEqual(second.scores.accessibility, firstA11y, "accessibility must not change between identical runs")
            XCTAssertEqual(second.scores.seo, firstSEO, "SEO must not change between identical runs")
            XCTAssertNotNil(firstA11y)
            XCTAssertFalse(first.audits.isEmpty)

            var written: [String] = []
            for panel in OrbitInspectPanel.allCases {
                session.select(panel: panel)
                try await Task.sleep(for: .milliseconds(400))
                if let url = OrbitInspectFixture.snapshot(OrbitInspectView(session: session), size: CGSize(width: 560, height: 760), name: panel.rawValue) {
                    written.append(url.lastPathComponent)
                }
            }
            XCTAssertEqual(written.count, OrbitInspectPanel.allCases.count)
        }
    }
}
