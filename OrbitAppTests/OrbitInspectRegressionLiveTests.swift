// Regressions found using the inspector on real pages; each test drives real WebKit against a local HTTP page.

import AppKit
import JavaScriptCore
import SwiftUI
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class OrbitInspectRegressionLiveTests: XCTestCase {

    private static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Orbit inspector regressions</title>
      <link rel="stylesheet" href="/plain.css">
      <link rel="stylesheet" href="/modern.css">
      <link rel="stylesheet" href="/authored.css">
    </head>
    <body>
      <div id="target" class="plain layered contained nested">target</div>
      <section id="box" style="display:flex"><span id="inner">a</span><span>b</span></section>
      <div class="frame"><div id="sized" class="contained">sized</div></div>
      <div id="card" class="card">card</div>
      <iframe id="child" src="/frame.html" width="200" height="60"></iframe>
      <img src="/pixel.png" alt="pixel" width="4" height="4">
      <script src="/app.js"></script>
    </body>
    </html>
    """

    private static let plainCSS = """
    .plain { margin: 3px; }
    """

    // Cascade layers, container queries and nesting are how current frameworks (Tailwind v4 among them) ship CSS.
    private static let modernCSS = """
    @layer base { .layered { padding: 5px; } }
    .frame { container-type: inline-size; }
    @container (min-width: 10px) { .contained { border-top-width: 2px; } }
    .nested { & { letter-spacing: 1px; } }
    """

    private static let authoredCSS = """
    .card { padding: 12px 16px; border: 1px solid #ddd; margin: 8px; background: #f3f4f6; }
    @media (max-width: 1px) { .card { color: red; } }
    @media (min-width: 1px) { .card { letter-spacing: 1px; } }
    @supports (not-a-real-property: 1) { .card { outline: 1px solid red; } }
    """

    private static let frameHTML = """
    <!DOCTYPE html>
    <html><body><p>frame</p>
    <script>
    setTimeout(function () {
      var p = document.createElement("p"); p.id = "from-frame"; document.body.appendChild(p);
      history.pushState({}, "", "#moved");
    }, 400);
    </script>
    </body></html>
    """

    private static let js = """
    fetch("/api/one.json").then(function (r) { return r.text(); });
    fetch("/api/two.json").then(function (r) { return r.text(); });
    var xhr = new XMLHttpRequest(); xhr.open("GET", "/api/three.json"); xhr.send();
    """

    private static func routes() -> [String: LiveHTTPTestServer.Route] {
        [
            "/": .init(contentType: "text/html; charset=utf-8", body: html),
            "/plain.css": .init(contentType: "text/css", body: plainCSS),
            "/modern.css": .init(contentType: "text/css", body: modernCSS),
            "/authored.css": .init(contentType: "text/css", body: authoredCSS),
            "/frame.html": .init(contentType: "text/html; charset=utf-8", body: frameHTML),
            "/big-closed.txt": .init(contentType: "text/plain", body: String(repeating: "0123456789", count: 10_000)),
            "/big-open.txt": .init(contentType: "text/plain", body: String(repeating: "0123456789", count: 10_000)),
            // An event stream that keeps trickling for minutes: no inspector read may wait for its end.
            "/stream": .init(contentType: "text/event-stream", data: Data(String(repeating: "data: tick\n\n", count: 20_000).utf8),
                             throttle: (chunkSize: 64, delay: 0.05)),
            "/app.js": .init(contentType: "application/javascript", body: js),
            "/api/one.json": .init(contentType: "application/json", body: "{\"one\":1}"),
            "/api/two.json": .init(contentType: "application/json", body: "{\"two\":2}"),
            "/api/three.json": .init(contentType: "application/json", body: "{\"three\":3}"),
            "/pixel.png": .init(contentType: "image/png", data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!),
        ]
    }

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

    /// Loads the page and opens the inspector on Elements, the way a person does: page first, then the panel.
    private func openInspector(
        _ body: @escaping (OrbitInspectSession, WebKitWebContents, NSWindow) async throws -> Void
    ) throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let server = try LiveHTTPTestServer(routes: Self.routes())
            let contents = try await WebKitLiveEngineHost.makeContents()
            let window = LiveContextMenuGesture.host(contents)
            defer {
                OrbitDevToolsStore.shared.close(contents)
                server.stop()
                window.orderOut(nil)
                contents.close()
            }
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("agent hello") { session.pageURL.hasPrefix("http") }
            OrbitDevToolsStore.shared.open(contents, panel: .elements, inspectAt: nil, armPicker: false)
            try await body(session, contents, window)
        }
    }

    private func node(_ session: OrbitInspectSession, id: String) -> ElNodeInfo? {
        session.elements.nodes.values.first { $0.attrs["id"] == id }
    }


    /// One syntax error anywhere in the assembled agent kills every tool, so the whole source must compile.
    func testAssembledAgentSourceCompiles() {
        let context = JSContext()!
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.setObject(OrbitInspectAgent.source, forKeyedSubscript: "agentSource" as NSString)
        context.evaluateScript("new Function(agentSource);")
        XCTAssertNil(exception, "the injected agent does not parse: \(exception ?? "")")
    }

    func testLiveMetricsSamplerStopsAndAnOldRunCannotStopItsReplacement() throws {
        try openInspector { session, _, _ in
            let first = UUID()
            let second = UUID()
            _ = try await session.evaluate(OrbitLivePageSample.script(runID: first, includeNodes: false))
            _ = try await session.evaluate(OrbitLivePageSample.script(runID: second, includeNodes: false))
            _ = try await session.evaluate(OrbitLivePageSample.stopScript(runID: first))
            let activeID = try await session.evaluate("window.__orbitLiveStats?.id") as? String
            XCTAssertEqual(activeID, second.uuidString)

            _ = try await session.evaluate(OrbitLivePageSample.stopScript(runID: second))
            let stopped = try await session.evaluate("!window.__orbitLiveStats") as? Bool
            XCTAssertEqual(stopped, true)

            let live = session.performance.live
            let polling = Task { await live.run(session: session) }
            defer { polling.cancel() }
            try await self.waitUntil("live metrics sampler installed") {
                try await session.evaluate("!!window.__orbitLiveStats") as? Bool == true
            }
            polling.cancel()
            await polling.value
            let stoppedOnExit = try await session.evaluate("!window.__orbitLiveStats") as? Bool
            XCTAssertEqual(stoppedOnExit, true)
        }
    }

    func testClosedInspectorCommitFinishesRecordingWithoutReinjectingAgent() throws {
        try openInspector { session, contents, _ in
            let originalURL = session.pageURL
            let nextURL = try XCTUnwrap(contents.webView.url?.appendingPathComponent("next-document"))
            let performance = session.performance
            session.select(panel: .performance)
            performance.startRecording()
            XCTAssertEqual(performance.recordingState, .recording)

            OrbitDevToolsStore.shared.close(contents)
            XCTAssertFalse(session.isPresented)
            // Deliver the commit in the same main-actor turn as close, while the stop flush is pending.
            session.documentDidCommit(url: nextURL)
            XCTAssertFalse(session.agentReady, "a closed inspector must leave the new document on the stub")

            try await self.waitUntil("performance recording finished") { performance.recordingState == .idle }
            XCTAssertEqual(performance.recordings.count, 1)
            XCTAssertEqual(performance.selectedRecording?.url, originalURL)
        }
    }

    func testDockedNetworkPanelCatchesUpAfterTheTabReturns() throws {
        try openInspector { session, contents, _ in
            session.setDock(.right)
            session.select(panel: .network)
            session.network.flushIfDirty()
            contents.setVisible(false)
            XCTAssertFalse(session.isPanelVisible)

            var record = NetRecord(id: "background-request")
            record.url = "https://example.test/background.js"
            session.network.nativeRequestSent(record)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(session.network.records.contains { $0.id == record.id })
            XCTAssertFalse(session.network.filteredRecords.contains { $0.id == record.id })

            contents.setVisible(true)
            XCTAssertTrue(session.isPanelVisible)
            XCTAssertTrue(session.network.filteredRecords.contains { $0.id == record.id })
            XCTAssertEqual(session.panel, .network)
        }
    }


    func testClickingARowShowsMatchedRulesFromEveryKindOfStylesheetRule() throws {
        try openInspector { session, _, _ in
            let elements = session.elements
            try await self.waitUntil("target row") { self.node(session, id: "target") != nil }
            let target = try XCTUnwrap(self.node(session, id: "target"))
            elements.selectRow(nodeID: target.id)
            try await self.waitUntil("plain rule", timeout: .seconds(8)) {
                elements.styleRules.contains { $0.selector == ".plain" }
            }
            try await Task.sleep(for: .milliseconds(300))
            let selectors = elements.styleRules.map(\.selector)
            XCTAssertTrue(selectors.contains(".layered"), "a rule inside @layer must be listed. Got \(selectors)")
            XCTAssertTrue(selectors.contains(".contained"), "a rule inside @container must be listed. Got \(selectors)")
            XCTAssertTrue(selectors.contains("&"), "a nested style rule must be listed. Got \(selectors)")
            XCTAssertNil(session.notice, "the agent reported an error: \(session.notice ?? "")")

            let layered = try XCTUnwrap(elements.styleRules.first { $0.selector == ".layered" })
            XCTAssertEqual(layered.declarations.first?.property, "padding", "the shorthand as written")
            elements.setRuleProperty(sheetIdx: layered.sheetIdx, ruleIdx: layered.ruleIdx, rulePath: layered.rulePath,
                                     property: "padding-top", value: "9px")
            try await self.waitUntil("layered rule edit applied", timeout: .seconds(5)) {
                let value = try await session.evaluate("getComputedStyle(document.getElementById('target')).paddingTop") as? String
                return value == "9px"
            }
        }
    }

    /// A rule lists what the author wrote, shorthands with their longhands, both editable; rules whose condition fails stay hidden until "Show all".
    func testStylesShowAuthoredShorthandsAndOnlyActiveConditions() throws {
        try openInspector { session, _, _ in
            let elements = session.elements
            try await self.waitUntil("card row") { self.node(session, id: "card") != nil }
            let card = try XCTUnwrap(self.node(session, id: "card"))
            elements.selectRow(nodeID: card.id)
            try await self.waitUntil("card rule", timeout: .seconds(8)) {
                elements.styleRules.contains { $0.selector == ".card" && $0.groupingRules.isEmpty }
            }
            let rule = try XCTUnwrap(elements.styleRules.first { $0.selector == ".card" && $0.groupingRules.isEmpty })
            let names = rule.declarations.map(\.property)
            XCTAssertEqual(Array(names.prefix(3)), ["padding", "border", "margin"], "declared order, as written. Got \(names)")
            XCTAssertTrue(names.contains { $0.hasPrefix("background") }, "\(names)")
            XCTAssertFalse(names.contains("padding-top"), "longhands must not be listed at the top level. Got \(names)")
            let padding = try XCTUnwrap(rule.declarations.first { $0.property == "padding" })
            XCTAssertEqual(padding.value, "12px 16px")
            XCTAssertEqual(padding.longhands.map(\.property), ["padding-top", "padding-right", "padding-bottom", "padding-left"])
            XCTAssertEqual(padding.longhands.first?.value, "12px")

            // (max-width: 1px) and the unsupported @supports match the element but do not apply, so they stay hidden.
            let displayed = elements.displayedStyleRules
            XCTAssertTrue(displayed.contains { $0.declarations.contains { $0.property == "letter-spacing" } })
            XCTAssertFalse(displayed.contains { $0.declarations.contains { $0.property == "color" } && $0.selector == ".card" })
            XCTAssertFalse(displayed.contains { $0.declarations.contains { $0.property == "outline" } })
            XCTAssertEqual(elements.inactiveRuleCount, 2, "\(elements.styleRules.map { "\($0.selector) \($0.conditionLines) inactive=\($0.isInactive)" })")
            elements.showInactiveRules = true
            XCTAssertEqual(elements.displayedStyleRules.count, elements.styleRules.count)
            elements.showInactiveRules = false
            let colorRule = try XCTUnwrap(elements.styleRules.first { $0.isInactive && $0.declarations.contains { $0.property == "color" } })
            XCTAssertFalse(colorRule.declarations.isEmpty)

            elements.setRuleProperty(sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath,
                                     property: "padding", value: "3px 4px")
            try await self.waitUntil("shorthand edit applied", timeout: .seconds(5)) {
                let value = try await session.evaluate("getComputedStyle(document.getElementById('card')).paddingLeft") as? String
                return value == "4px"
            }
            elements.setRuleProperty(sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath,
                                     property: "padding-top", value: "9px")
            try await self.waitUntil("longhand edit applied", timeout: .seconds(5)) {
                let value = try await session.evaluate("getComputedStyle(document.getElementById('card')).paddingTop") as? String
                return value == "9px"
            }
            try await self.waitUntil("styles refreshed after the edits", timeout: .seconds(5)) {
                let refreshed = elements.styleRules.first { $0.selector == ".card" && $0.groupingRules.isEmpty }
                return refreshed?.declarations.first { $0.property == "padding" }?.longhands.first?.value == "9px"
            }

            // The tree shows only listed nodes, and nothing the snapshot already had is flashed as a change.
            XCTAssertFalse(elements.visibleRows.contains { $0.node.kind == "text" && $0.node.text.isEmpty },
                           "whitespace-only text nodes must not appear as rows")
            let bodyRow = try XCTUnwrap(elements.visibleRows.first { $0.node.name == "body" })
            XCTAssertFalse(elements.flashedNodes.contains(bodyRow.nodeID), "the body was flashed as if it had just been added")
            elements.detailTab = .styles
            _ = OrbitInspectFixture.snapshot(OrbitInspectView(session: session), size: CGSize(width: 560, height: 760), name: "regression-styles")
        }
    }

    /// Unchecking takes a declaration out of the page but keeps it listed across refreshes; checking restores it in place; undo and redo replay both.
    func testUncheckedDeclarationStaysListedAndComesBackInPlace() throws {
        try openInspector { session, _, _ in
            let elements = session.elements
            try await self.waitUntil("card row") { self.node(session, id: "card") != nil }
            let card = try XCTUnwrap(self.node(session, id: "card"))
            @MainActor func cardRule() -> ElStyleRule? {
                elements.styleRules.first { $0.selector == ".card" && $0.groupingRules.isEmpty }
            }
            @MainActor func borderTop() async throws -> String? {
                try await session.evaluate("getComputedStyle(document.getElementById('card')).borderTopWidth") as? String
            }
            elements.selectRow(nodeID: card.id)
            try await self.waitUntil("card rule", timeout: .seconds(8)) { cardRule() != nil }
            let original = try XCTUnwrap(cardRule()).declarations.map(\.property)
            let borderAt = try XCTUnwrap(original.firstIndex(of: "border"))
            let currentBorder = try await borderTop()
            XCTAssertEqual(currentBorder, "1px")

            elements.setDeclarationEnabled(false, property: "border", in: try XCTUnwrap(cardRule()))
            try await self.waitUntil("border off in the page", timeout: .seconds(5)) { try await borderTop() == "0px" }
            try await self.waitUntil("border listed as disabled", timeout: .seconds(5)) {
                cardRule()?.declarations.first { $0.property == "border" }?.disabled == true
            }
            XCTAssertEqual(cardRule()?.declarations.map(\.property), original, "the disabled declaration moved or vanished")

            let target = try XCTUnwrap(self.node(session, id: "target"))
            elements.selectRow(nodeID: target.id)
            try await self.waitUntil("other element's styles", timeout: .seconds(5)) {
                elements.styleRules.contains { $0.selector == ".plain" }
            }
            elements.selectRow(nodeID: card.id)
            try await self.waitUntil("card rule again", timeout: .seconds(5)) { cardRule() != nil }
            XCTAssertEqual(cardRule()?.declarations.first { $0.property == "border" }?.disabled, true,
                           "the disabled declaration did not survive a refresh")
            XCTAssertEqual(cardRule()?.declarations.map(\.property), original)

            elements.setDeclarationEnabled(true, property: "border", in: try XCTUnwrap(cardRule()))
            try await self.waitUntil("border back in the page", timeout: .seconds(5)) { try await borderTop() == "1px" }
            try await self.waitUntil("border listed as enabled", timeout: .seconds(5)) {
                cardRule()?.declarations.first { $0.property == "border" }?.disabled == false
            }
            XCTAssertEqual(cardRule()?.declarations.map(\.property), original)
            XCTAssertEqual(cardRule()?.declarations.firstIndex { $0.property == "border" }, borderAt)
            let sheetOrder = try await session.evaluate("""
                (function () { var s = Array.prototype.find.call(document.styleSheets, function (x) { return /authored/.test(x.href); });
                  return s.cssRules[0].style.cssText; })()
                """) as? String
            let text = sheetOrder ?? ""
            let positions = ["padding", "border", "margin"].compactMap { text.range(of: $0)?.lowerBound }
            XCTAssertEqual(positions.count, 3, "stylesheet text: \(text)")
            XCTAssertEqual(positions, positions.sorted(), "re-enabled out of place in the stylesheet: \(text)")

            elements.undo()
            try await self.waitUntil("undo enable", timeout: .seconds(5)) { try await borderTop() == "0px" }
            try await self.waitUntil("undo shows disabled", timeout: .seconds(5)) {
                cardRule()?.declarations.first { $0.property == "border" }?.disabled == true
            }
            elements.undo()
            try await self.waitUntil("undo disable", timeout: .seconds(5)) { try await borderTop() == "1px" }
            elements.redo()
            try await self.waitUntil("redo disable", timeout: .seconds(5)) { try await borderTop() == "0px" }
            try await self.waitUntil("redo shows disabled in place", timeout: .seconds(5)) {
                cardRule()?.declarations.map(\.property) == original
                    && cardRule()?.declarations.first { $0.property == "border" }?.disabled == true
            }

            _ = OrbitInspectFixture.snapshot(OrbitInspectView(session: session), size: CGSize(width: 560, height: 760), name: "regression-styles-disabled")

            _ = try await session.evaluate("document.getElementById('card').style.cssText = 'outline-width: 3px; word-spacing: 2px'; 1")
            elements.selectRow(nodeID: card.id)
            try await self.waitUntil("inline rule", timeout: .seconds(5)) {
                elements.styleRules.first { $0.ruleType == "inline" }?.declarations.count == 2
            }
            let inline = try XCTUnwrap(elements.styleRules.first { $0.ruleType == "inline" })
            elements.setDeclarationEnabled(false, property: "outline-width", in: inline)
            try await self.waitUntil("inline declaration disabled and listed first", timeout: .seconds(5)) {
                let decls = elements.styleRules.first { $0.ruleType == "inline" }?.declarations ?? []
                return decls.map(\.property) == ["outline-width", "word-spacing"] && decls.first?.disabled == true
            }
            let inlineText = try await session.evaluate("document.getElementById('card').style.cssText") as? String
            XCTAssertEqual(inlineText, "word-spacing: 2px;")
            elements.setDeclarationEnabled(true, property: "outline-width", in: inline)
            try await self.waitUntil("inline declaration back first", timeout: .seconds(5)) {
                (try await session.evaluate("document.getElementById('card').style.cssText") as? String) == "outline-width: 3px; word-spacing: 2px;"
            }
        }
    }

    /// Editing an unchecked declaration changes the kept value, not the page; checking applies it; renaming works either way; all undoable.
    func testEditingAnUncheckedDeclarationKeepsItUnchecked() throws {
        try openInspector { session, _, _ in
            let elements = session.elements
            try await self.waitUntil("card row") { self.node(session, id: "card") != nil }
            let card = try XCTUnwrap(self.node(session, id: "card"))
            @MainActor func cardRule() -> ElStyleRule? {
                elements.styleRules.first { $0.selector == ".card" && $0.groupingRules.isEmpty }
            }
            @MainActor func decl(_ property: String) -> ElDeclaration? {
                cardRule()?.declarations.first { $0.property == property }
            }
            @MainActor func computed(_ property: String) async throws -> String? {
                try await session.evaluate("getComputedStyle(document.getElementById('card')).\(property)") as? String
            }
            @MainActor func ruleText() async throws -> String {
                try await session.evaluate("""
                    Array.prototype.find.call(document.styleSheets, function (x) { return /authored/.test(x.href); }).cssRules[0].style.cssText
                    """) as? String ?? ""
            }
            elements.selectRow(nodeID: card.id)
            try await self.waitUntil("card rule", timeout: .seconds(8)) { cardRule() != nil }
            let order = try XCTUnwrap(cardRule()).declarations.map(\.property)

            elements.setDeclarationEnabled(false, property: "margin", in: try XCTUnwrap(cardRule()))
            try await self.waitUntil("margin unchecked", timeout: .seconds(5)) { decl("margin")?.disabled == true }
            let textWhileOff = try await ruleText()

            let rule = try XCTUnwrap(cardRule())
            elements.setRuleProperty(sheetIdx: rule.sheetIdx, ruleIdx: rule.ruleIdx, rulePath: rule.rulePath,
                                     property: "margin", value: "21px")
            try await self.waitUntil("edited value kept", timeout: .seconds(5)) { decl("margin")?.value == "21px" }
            XCTAssertEqual(decl("margin")?.disabled, true, "editing an unchecked declaration turned it back on")
            let textAfterEdit = try await ruleText()
            XCTAssertEqual(textAfterEdit, textWhileOff, "editing an unchecked declaration wrote it into the stylesheet")
            let marginOff = try await computed("marginTop")
            XCTAssertEqual(marginOff, "0px")
            XCTAssertEqual(cardRule()?.declarations.map(\.property), order)

            elements.undo()
            try await self.waitUntil("undo restores the kept value", timeout: .seconds(5)) { decl("margin")?.value == "8px" }
            XCTAssertEqual(decl("margin")?.disabled, true)
            elements.redo()
            try await self.waitUntil("redo reapplies the kept value", timeout: .seconds(5)) { decl("margin")?.value == "21px" }

            elements.setDeclarationEnabled(true, property: "margin", in: try XCTUnwrap(cardRule()))
            try await self.waitUntil("edited value applied", timeout: .seconds(5)) { try await computed("marginTop") == "21px" }
            try await self.waitUntil("margin checked", timeout: .seconds(5)) { decl("margin")?.disabled == false }
            XCTAssertEqual(cardRule()?.declarations.map(\.property), order)

            elements.setDeclarationEnabled(false, property: "margin", in: try XCTUnwrap(cardRule()))
            try await self.waitUntil("margin unchecked again", timeout: .seconds(5)) { decl("margin")?.disabled == true }
            elements.renameDeclaration(from: "margin", to: "padding-bottom", in: try XCTUnwrap(cardRule()))
            try await self.waitUntil("unchecked declaration renamed", timeout: .seconds(5)) {
                decl("padding-bottom")?.disabled == true && decl("margin") == nil
            }
            XCTAssertEqual(cardRule()?.declarations.firstIndex { $0.property == "padding-bottom" }, order.firstIndex(of: "margin"))
            XCTAssertEqual(decl("padding-bottom")?.value, "21px")
            let paddingBottomOff = try await computed("paddingBottom")
            XCTAssertEqual(paddingBottomOff, "12px", "the renamed unchecked declaration reached the page")
            elements.undo()
            try await self.waitUntil("undo rename", timeout: .seconds(5)) { decl("margin")?.disabled == true }

            elements.renameDeclaration(from: "border", to: "outline", in: try XCTUnwrap(cardRule()))
            try await self.waitUntil("checked declaration renamed", timeout: .seconds(5)) {
                decl("outline") != nil && decl("border") == nil
            }
            XCTAssertEqual(cardRule()?.declarations.firstIndex { $0.property == "outline" }, order.firstIndex(of: "border"))
            let outlineWidth = try await computed("outlineWidth")
            XCTAssertEqual(outlineWidth, "1px")
            let borderAfterRename = try await computed("borderTopWidth")
            XCTAssertEqual(borderAfterRename, "0px")
            elements.undo()
            try await self.waitUntil("undo checked rename", timeout: .seconds(5)) { try await computed("borderTopWidth") == "1px" }
        }
    }

    /// A child frame's agent numbers its own nodes, so its mutation and soft-navigation messages must not graft into or wipe the main tree.
    func testChildFrameMessagesLeaveTheMainTreeAlone() throws {
        try openInspector { session, _, _ in
            let elements = session.elements
            try await self.waitUntil("target row") { self.node(session, id: "target") != nil }
            let target = try XCTUnwrap(self.node(session, id: "target"))
            elements.selectRow(nodeID: target.id)
            // The frame acts 400 ms after it loads; give it time to report.
            try await Task.sleep(for: .milliseconds(1500))
            let fromFrame = try await session.evaluate(
                "document.getElementById('child').contentDocument.getElementById('from-frame') ? 1 : 0") as? Int
            XCTAssertEqual(fromFrame, 1, "the frame's script did not run, so this test proves nothing")
            XCTAssertEqual(elements.selectedID, target.id, "a soft navigation inside the frame cleared the main tree")
            XCTAssertFalse(elements.nodes.values.contains { $0.attrs["id"] == "from-frame" },
                           "a node added inside the frame was grafted into the main tree")
            XCTAssertNotNil(self.node(session, id: "target"))
        }
    }

    /// Hosts one tree row in its own window and clicks it through real AppKit hit testing, so an overlapping target swallows the click as in the app.
    private final class HostedRow {
        let window: NSWindow
        let size: NSSize

        @MainActor
        init(_ row: ElFlatRow, session: OrbitInspectSession) async throws {
            // Wide enough for the row to print in full: rows no longer truncate, so the layout badge follows the text.
            size = NSSize(width: max(420, ElTreeRowView.contentWidth(of: row)), height: InspectChrome.rowHeight)
            let host = NSHostingView(rootView: ElTreeRowView(row: row, session: session).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
        }

        /// `x` is measured from the row's leading edge.
        @MainActor
        func click(atX x: CGFloat) throws {
            let point = NSPoint(x: x, y: size.height / 2)
            let resolved = try XCTUnwrap(window.contentView?.superview?.hitTest(point), "nothing under x=\(x)")
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                ))
            }
            resolved.mouseDown(with: try event(.leftMouseDown))
            resolved.mouseUp(with: try event(.leftMouseUp))
        }

        @MainActor
        func close() { window.orderOut(nil) }
    }

    /// The chevron must expand a collapsed row and load its children; the tag must still select it and the layout badge toggle its overlay.
    func testClickingTheDisclosureChevronExpandsTheNode() throws {
        try openInspector { session, _, _ in
            let elements = session.elements
            try await self.waitUntil("box row") {
                elements.visibleRows.contains { $0.node.attrs["id"] == "box" && !$0.isClosingTag }
            }
            let row = try XCTUnwrap(elements.visibleRows.first { $0.node.attrs["id"] == "box" && !$0.isClosingTag })
            XCTAssertTrue(row.hasChildren)
            XCTAssertFalse(row.isExpanded)
            try await self.waitUntil("flex badge for the box") { elements.layoutKinds[row.nodeID] != nil }

            let hosted = try await HostedRow(row, session: session)
            defer { hosted.close() }

            // The chevron is centred in the 16pt column after the indent guides (16pt per level).
            try hosted.click(atX: CGFloat(row.depth) * 16 + 8)
            XCTAssertTrue(elements.expanded.contains(row.nodeID), "the chevron click did not expand the node")
            XCTAssertNotEqual(elements.selectedID, row.nodeID, "the chevron click selected the row instead")
            try await self.waitUntil("children of the expanded node", timeout: .seconds(5)) {
                elements.childrenMap[row.nodeID]?.isEmpty == false
            }
            try await self.waitUntil("child rows", timeout: .seconds(2)) {
                elements.visibleRows.contains { $0.node.attrs["id"] == "inner" }
            }

            try hosted.click(atX: CGFloat(row.depth) * 16 + 16 + 20)
            XCTAssertEqual(elements.selectedID, row.nodeID, "a click on the tag must select the row")

            // The badge follows the tag text (8pt of padding after it) so it stays reachable when the tree scrolls sideways.
            let textEnd = ElTreeRowView.contentWidth(of: row) - ElTreeRowView.trailingRoom
            try hosted.click(atX: textEnd + 8 + 12)
            try await self.waitUntil("flex overlay on", timeout: .seconds(3)) { elements.layoutOverlays[row.nodeID] != nil }
        }
    }


    private static let hostileKeys: [String] = [
        "id", "version", "len", "count", "total", "totalCount", "offset", "usage", "quota", "status", "line", "col",
        "column", "index", "sheetIdx", "ruleIdx", "rulePath", "specificity", "childCount", "parentId", "afterId",
        "nodeId", "entry", "seq", "t", "ts", "dur", "duration", "startTime", "iterations", "currentTime", "delay",
        "endDelay", "x", "y", "w", "h", "width", "height", "size", "transferSize", "xfer", "encBody", "decBody",
        "dcl", "load", "fcp", "lcp", "origin", "iid", "eid", "ratio", "contrastRatio", "depth", "domDepth",
        "domNodes", "domMaxKids", "nodeCount", "elapsed", "timespanDur", "httpStatus", "dpr", "rate", "value",
        "entries", "mutations", "rules", "nodes", "children", "path", "records", "items", "files", "anims",
        "tasks", "events", "listeners", "properties", "declarations", "longhands", "usageDetails", "args",
        "tableRows", "hooks", "roots", "sections", "kinds", "overlays", "cssVars", "groupingRules", "headers",
        "parent", "node", "bundle", "props", "attrs", "k", "kind", "type", "url", "href", "title", "msg", "data",
        "frames", "databases", "stores", "registrations", "permissions", "links", "images", "forms", "headings",
    ]

    private static var hostileValues: [Any] {
        [1e300, -1e300, Double.greatestFiniteMagnitude, Double.nan, Double.infinity, -Double.infinity, "NaN", "",
         true, NSNull(), [Any](), [String: Any](), Array(repeating: 1e300, count: 2_000) as [Any]]
    }

    private static let allMessageTypes: [String] = {
        let core = ["hello", "navigate", "picking", "agentError"]
        return core + [
            "el.dom", "el.children", "el.select", "el.style", "el.computed", "el.listeners", "el.a11y", "el.mutation",
            "el.attrDone", "el.outerHTML", "el.boxModel", "el.navigate", "el.snapshotDone", "el.edited", "el.editFailed",
            "el.editDone", "el.text", "el.layoutKinds", "el.layoutOverlays", "con.batch", "src.files", "src.fileUpdate",
            "src.outerHTML", "src.jsResult", "src.cssResult", "src.htmlApplied", "net.batch", "net.nav", "perf.batch",
            "anim.batch", "app.localStorageData", "app.sessionStorageData", "app.storageChanged", "app.idbDatabases",
            "app.idbStoreInfo", "app.idbRecords", "app.cacheNames", "app.cacheEntries", "app.serviceWorkers",
            "app.manifest", "app.quota", "app.frames", "app.permissions", "app.error", "lh.loaded", "lh.bundle",
            "sec.page", "fw.evidence", "fw.tree", "fw.data", "fw.routes", "fw.hmr", "fw.overlay", "fw.editResult",
            "fw.globalStored", "fw.launchResult", "fw.devSocket", "fw.devFrame", "fw.devEvent", "fw.devProbe",
            "fw.devActionResult", "fw.devEnv", "net.form", "net.body",
        ]
    }()

    /// Every message type every module handles, with each field set to hostile values: huge or non-finite numbers, wrong types, huge containers.
    @MainActor
    private func sprayHostileMessages(at session: OrbitInspectSession) {
        let session = session
        for type in Self.allMessageTypes {
            for value in Self.hostileValues {
                var flat: [String: Any] = ["t": type]
                for key in Self.hostileKeys { flat[key] = value }
                var nested: [String: Any] = ["t": type]
                for key in Self.hostileKeys { nested[key] = [flat, flat] as [Any] }
                var deep: [String: Any] = ["t": type]
                for key in Self.hostileKeys { deep[key] = [nested] as [Any] }
                for object in [flat, nested, deep] {
                    for isMain in [true, false] {
                        session.receive(type: type, object: object, frame: OrbitInspectFrame(url: "https://x", isMain: isMain))
                    }
                }
            }
        }
    }

    /// Finding 1: a page could crash Orbit with one postMessage; hostile values through the bridge and every module must not.
    func testHostileMessagesFromThePageNeverCrashTheApp() throws {
        try openInspector { session, _, _ in
            let pageURL = session.pageURL
            _ = try await session.evaluate("""
                (function () {
                  var h = window.webkit.messageHandlers.orbitInspect;
                  var big = 1e300;
                  [
                    '{"t":"hello","version":1e300,"attached":true}',
                    '{"t":"con.batch","entries":[{"seq":"1","level":"log","ts":1e300,"args":[{"k":"ref","id":1e300,"len":1e300,"preview":"x","cls":"A"}]}]}',
                    '{"t":"app.quota","usage":1e300,"quota":-1e300,"usageDetails":{"a":1e300,"b":-1e300}}',
                    '{"t":"anim.batch","anims":[{"id":"a","iterations":1e300,"currentTime":1e300,"duration":1e300}]}',
                    '{"t":"perf.batch","entries":[{"k":"res","ts":1e300,"dur":-1e300,"transferSize":1e300}]}',
                    '{"t":"el.style","id":1e300,"rules":[{"specificity":[1e300,-1e300],"rulePath":[1e300]}]}',
                    '{"t":"src.files","files":[{"id":"x","url":"u","line":1e300,"index":-1e300}]}',
                    '{"t":"fw.tree","roots":[1e300],"nodes":[{"id":1e300,"children":[1e300],"hooks":[{"i":1e300,"l":"a","v":"b"}]}]}'
                  ].forEach(function (m) { h.postMessage(m); });
                  return 1;
                })()
                """)
            try await Task.sleep(for: .milliseconds(300))
            self.sprayHostileMessages(at: session)
            let alive = try await session.evaluate("1 + 1") as? Int
            XCTAssertEqual(alive, 2)
            XCTAssertEqual(session.pageURL, pageURL)
        }
    }

    /// Finding 2: autocomplete passed a bare string to JSONSerialization, which raises an uncatchable exception.
    func testConsoleCompletionsDoNotCrash() throws {
        try openInspector { session, _, _ in
            session.select(panel: .console)
            // Commands to the agent run in a queue, and a completion goes straight to the page, so it must wait for the agent to be there.
            try await self.waitUntil("agent loaded", timeout: .seconds(8)) {
                (try await session.evaluate("!!window.__orbitInspect") as? Bool) == true
            }
            let completions = await session.console.fetchCompletions(path: ["document"], prefix: "getElem")
            XCTAssertTrue(completions.contains("getElementById"), "got \(completions)")
            let quoted = await session.console.fetchCompletions(path: [], prefix: "\"'\\")
            XCTAssertNotNil(quoted)

            _ = try await session.evaluate("console.log({ alpha: 1, beta: [2, 3] }); 1")
            try await self.waitUntil("logged object", timeout: .seconds(5)) {
                session.console.entries.contains { $0.args.first?.registryId != nil }
            }
            let registryId = try XCTUnwrap(session.console.entries.last { $0.args.first?.registryId != nil }?.args.first?.registryId)
            session.console.requestExpansion(registryId: registryId)
            try await self.waitUntil("expanded properties", timeout: .seconds(5)) {
                if case .loaded(let own, _) = session.console.expandedProps[registryId] { return own.contains { $0.name == "alpha" } }
                return false
            }
        }
    }

    /// Finding 7: input whose run throws a SyntaxError at runtime (JSON.parse) ran a second time as statements.
    func testConsoleInputWithARuntimeSyntaxErrorRunsOnce() throws {
        try openInspector { session, _, _ in
            session.select(panel: .console)
            _ = try await session.evaluate("window.__runs = 0; 1")
            session.console.inputText = "window.__runs++, JSON.parse('x')"
            session.console.submitInput()
            try await self.waitUntil("the error result", timeout: .seconds(5)) {
                session.console.entries.contains { $0.level.isError && $0.plainText.contains("JSON") }
            }
            try await Task.sleep(for: .milliseconds(300))
            let runs = try await session.evaluate("window.__runs") as? Int
            XCTAssertEqual(runs, 1, "the input ran \(runs ?? -1) times")
            session.console.inputText = "const __orbitStatement = 41; window.__stmt = __orbitStatement + 1"
            session.console.submitInput()
            try await self.waitUntil("statement ran", timeout: .seconds(5)) {
                (try await session.evaluate("window.__stmt") as? Int) == 42
            }
        }
    }

    @MainActor
    private func agentStats(_ session: OrbitInspectSession) async throws -> [String: Any] {
        try await session.evaluate("window.__orbitInspect.stats()") as? [String: Any] ?? [:]
    }

    /// Finding 3: every tab numbered and held its DOM and observed every mutation, inspector open or not.
    func testDOMObserverAndNodeTrackingRunOnlyWhileTheInspectorIsOpen() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let server = try LiveHTTPTestServer(routes: Self.routes())
            let contents = try await WebKitLiveEngineHost.makeContents()
            let window = LiveContextMenuGesture.host(contents)
            defer { OrbitDevToolsStore.shared.close(contents); server.stop(); window.orderOut(nil); contents.close() }
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

            let isStubOnly = "typeof window.__orbitInspectEarly === 'object' && typeof window.__orbitInspect === 'undefined'"
            let stubOnlyBeforeChurn = try await session.evaluate(isStubOnly) as? Bool
            XCTAssertEqual(stubOnlyBeforeChurn, true, "ordinary navigation must install only the stub")
            _ = try await session.evaluate("for (var i = 0; i < 500; i++) { var d = document.createElement('div'); d.textContent = i; document.body.appendChild(d); d.setAttribute('data-x', i); d.remove(); } 1")
            try await Task.sleep(for: .milliseconds(200))
            let stubOnlyAfterChurn = try await session.evaluate(isStubOnly) as? Bool
            XCTAssertEqual(stubOnlyAfterChurn, true, "DOM churn while closed must leave the page with only the stub")
            let beforeOpening = try await session.evaluate("""
                document.getElementById('target').addEventListener('click', function closedHandler() { return 1; });
                window.addEventListener('beforeunload', function () {});
                performance.now()
                """) as? Double
            let preOpenTime = try XCTUnwrap(beforeOpening)

            OrbitDevToolsStore.shared.open(contents, panel: .elements, inspectAt: nil, armPicker: false)
            try await self.waitUntil("tree", timeout: .seconds(5)) { self.node(session, id: "target") != nil }
            var stats = try await self.agentStats(session)
            XCTAssertEqual(stats["presented"] as? Bool, true)
            XCTAssertEqual(stats["observingDOM"] as? Bool, true)
            let baseline = try XCTUnwrap(stats["disposers"] as? Int)
            try await self.waitUntil("buffered LCP from before opening", timeout: .seconds(5)) {
                session.performance.liveData.lcpEntries.contains { $0.startTime < preOpenTime }
            }
            let lcp = try XCTUnwrap(session.performance.liveData.lcpEntries.last { $0.startTime < preOpenTime })
            session.reveal(nodeID: lcp.nodeID)
            try await self.waitUntil("the closed-time LCP element revealed", timeout: .seconds(5)) { (session.elements.selectedID ?? 0) > 0 }
            let lcpNode = try XCTUnwrap(session.elements.selectedID.flatMap { session.elements.nodes[$0] })
            XCTAssertEqual(lcpNode.kind, "el")
            if !lcp.elementID.isEmpty {
                XCTAssertEqual(lcpNode.attrs["id"], lcp.elementID)
            }
            _ = try await session.evaluate("var n = document.createElement('p'); n.id = 'late'; document.body.appendChild(n); 1")
            try await self.waitUntil("added node in the tree", timeout: .seconds(5)) { self.node(session, id: "late") != nil }

            // Listeners added while closed are still listed, marked as such and without a location.
            _ = try await session.evaluate("document.getElementById('target').addEventListener('keydown', function openHandler() {}); 1")
            let target = try XCTUnwrap(self.node(session, id: "target"))
            session.elements.detailTab = .listeners
            session.elements.selectRow(nodeID: target.id)
            try await self.waitUntil("listeners", timeout: .seconds(5)) {
                session.elements.eventListeners.contains { $0.eventType == "keydown" }
            }
            let listeners = session.elements.eventListeners
            let closedClick = try XCTUnwrap(listeners.first { $0.eventType == "click" && !$0.isAncestor })
            XCTAssertTrue(closedClick.addedBeforeInspector)
            XCTAssertNil(closedClick.sourceURL)
            XCTAssertTrue(closedClick.handlerSource.contains("closedHandler"), "the handler text is still available: \(closedClick.handlerSource)")
            let openKey = try XCTUnwrap(listeners.first { $0.eventType == "keydown" })
            XCTAssertFalse(openKey.addedBeforeInspector)
            XCTAssertTrue(listeners.contains { $0.isWindow && $0.eventType == "beforeunload" && $0.addedBeforeInspector },
                          "window listeners added while closed are still known (Lighthouse's unload check reads them)")
            session.elements.detailTab = .styles

            for _ in 0..<3 {
                OrbitDevToolsStore.shared.close(contents)
                try await Task.sleep(for: .milliseconds(100))
                stats = try await self.agentStats(session)
                XCTAssertEqual(stats["presented"] as? Bool, false)
                XCTAssertEqual(stats["observingDOM"] as? Bool, false)
                XCTAssertEqual(stats["disposers"] as? Int, stats["permanentDisposers"] as? Int, "\(stats)")
                OrbitDevToolsStore.shared.open(contents, panel: .elements, inspectAt: nil, armPicker: false)
                try await Task.sleep(for: .milliseconds(100))
                stats = try await self.agentStats(session)
                XCTAssertEqual(stats["disposers"] as? Int, baseline, "attach/detach cycles must not grow the disposer list")
            }
        }
    }

    /// Finding 4: bodies were cloned and read in full, including endless streams, and frame arrays grew forever.
    func testNetworkBodiesOnlyWhileOpenCappedAndNeverFromStreams() throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let server = try LiveHTTPTestServer(routes: Self.routes())
            let contents = try await WebKitLiveEngineHost.makeContents()
            let window = LiveContextMenuGesture.host(contents)
            defer { OrbitDevToolsStore.shared.close(contents); server.stop(); window.orderOut(nil); contents.close() }
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            let network = session.network

            _ = try await session.evaluate("fetch('/big-closed.txt').then(function (r) { return r.text(); }); 1")
            try await self.waitUntil("closed fetch recorded", timeout: .seconds(5)) {
                network.flushIfDirty()
                return network.records.contains { $0.url.hasSuffix("/big-closed.txt") && $0.status == 200 }
            }
            try await Task.sleep(for: .milliseconds(400))
            let closedID = try XCTUnwrap(network.records.first { $0.url.hasSuffix("/big-closed.txt") }?.id)
            XCTAssertNil(network.richRecord(id: closedID)?.responseBody, "a body was read with the inspector closed")

            OrbitDevToolsStore.shared.open(contents, panel: .network, inspectAt: nil, armPicker: false)
            // The page only reads a body once the agent is in and has been told the inspector is open; both go through the command queue.
            try await self.waitUntil("agent presented", timeout: .seconds(8)) {
                (try await session.evaluate("window.__orbitInspect ? window.__orbitInspect.stats().presented : false") as? Bool) == true
            }
            _ = try await session.evaluate("fetch('/big-open.txt').then(function (r) { return r.text(); }).then(function (t) { window.__bigLength = t.length; }); 1")
            try await self.waitUntil("open fetch body", timeout: .seconds(5)) {
                network.flushIfDirty()
                guard let id = network.records.first(where: { $0.url.hasSuffix("/big-open.txt") })?.id else { return false }
                return network.richRecord(id: id)?.responseBody != nil
            }
            let openID = try XCTUnwrap(network.records.first { $0.url.hasSuffix("/big-open.txt") }?.id)
            let rich = try XCTUnwrap(network.richRecord(id: openID))
            XCTAssertEqual(rich.responseBody?.count, 65536)
            XCTAssertTrue(rich.responseBodyTruncated)
            try await self.waitUntil("page still got the whole body", timeout: .seconds(5)) {
                (try await session.evaluate("window.__bigLength") as? Int) == 100_000
            }

            // An event stream: the page reads it as it arrives; the inspector never tries to read it to the end.
            _ = try await session.evaluate("""
                window.__chunks = 0;
                fetch('/stream').then(function (r) { var rd = r.body.getReader();
                  (function pump() { rd.read().then(function (c) { if (c.done) return; window.__chunks++; pump(); }); })(); });
                1
                """)
            try await self.waitUntil("stream flowing to the page", timeout: .seconds(5)) {
                (try await session.evaluate("window.__chunks") as? Int ?? 0) > 3
            }
            network.flushIfDirty()
            let streamID = try XCTUnwrap(network.records.first { $0.url.hasSuffix("/stream") }?.id)
            XCTAssertNil(network.richRecord(id: streamID)?.responseBody, "an event stream body was read")

            let frames: [[String: Any]] = (0..<1500).map { i in
                ["k": "ws_frame", "id": "js-ws-cap", "dir": "in", "data": "\(i)", "binary": false, "len": 1, "t": Double(i)]
            }
            network.receive(type: "net.batch", object: ["entries": [["k": "ws_open", "id": "js-ws-cap", "url": "ws://x", "t": 0.0]] + frames],
                            frame: OrbitInspectFrame(url: "", isMain: true))
            let socket = try XCTUnwrap(network.richRecord(id: "js-ws-cap"))
            XCTAssertEqual(socket.wsFrames.count, NetRecord.maxStreamItems)
            XCTAssertEqual(socket.wsFrames.last?.data, "1499", "the newest frames are the ones kept")
        }
    }

    /// Finding 5: closing put back the wrapped originals, removing later patches (Zone.js, Sentry); Lighthouse also shadowed window's addEventListener.
    func testClosingTheInspectorKeepsInstrumentationAddedAfterIt() throws {
        try openInspector { session, contents, _ in
            let ownListener = try await session.evaluate("Object.prototype.hasOwnProperty.call(window, 'addEventListener')") as? Bool
            XCTAssertEqual(ownListener, false, "window has its own addEventListener")
            _ = try await session.evaluate("""
                (function () {
                  window.__patchCalls = 0;
                  var f = window.fetch; window.fetch = function () { window.__patchCalls++; return f.apply(this, arguments); }; window.__fetchPatch = window.fetch;
                  var l = console.log; console.log = function () { window.__patchCalls++; return l.apply(this, arguments); }; window.__logPatch = console.log;
                  var o = XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open = function () { window.__patchCalls++; return o.apply(this, arguments); }; window.__openPatch = XMLHttpRequest.prototype.open;
                  var a = EventTarget.prototype.addEventListener; EventTarget.prototype.addEventListener = function () { window.__patchCalls++; return a.apply(this, arguments); }; window.__addPatch = EventTarget.prototype.addEventListener;
                  return 1;
                })()
                """)
            OrbitDevToolsStore.shared.close(contents)
            try await Task.sleep(for: .milliseconds(200))
            let kept = try await session.evaluate("""
                [window.fetch === window.__fetchPatch, console.log === window.__logPatch,
                 XMLHttpRequest.prototype.open === window.__openPatch, EventTarget.prototype.addEventListener === window.__addPatch]
                """) as? [Bool]
            XCTAssertEqual(kept, [true, true, true, true], "closing removed patches added after the inspector")
            let before = session.network.records.count
            _ = try await session.evaluate("""
                (async function () {
                  console.log('after close');
                  var x = new XMLHttpRequest(); x.open('GET', '/api/one.json'); x.send();
                  document.body.addEventListener('click', function () {});
                  var r = await fetch('/api/two.json');
                  window.__afterClose = (await r.json()).two === 2 && window.__patchCalls >= 4;
                })(); 1
                """)
            try await self.waitUntil("the page's patched functions still work", timeout: .seconds(5)) {
                (try await session.evaluate("window.__afterClose") as? Bool) == true
            }
            try await Task.sleep(for: .milliseconds(400))
            session.network.flushIfDirty()
            let jsRecords = session.network.records.dropFirst(before).filter { $0.id.hasPrefix("js-") }
            XCTAssertTrue(jsRecords.isEmpty, "the closed inspector still recorded: \(jsRecords.map(\.url))")
        }
    }

    /// Finding 6: a page could forge a hello to set the Security verdict's URL and wipe evidence; only WebKit's commit may.
    func testForgedHelloAndNavigateCannotChangeTheURLOrWipeEvidence() throws {
        try openInspector { session, contents, _ in
            session.select(panel: .console)
            _ = try await session.evaluate("console.log('evidence'); 1")
            try await self.waitUntil("console evidence", timeout: .seconds(5)) {
                session.console.entries.contains { $0.plainText.contains("evidence") }
            }
            let realURL = try XCTUnwrap(contents.webView.url?.absoluteString)
            XCTAssertEqual(session.pageURL, realURL)
            _ = try await session.evaluate("""
                (function () {
                  var h = window.webkit.messageHandlers.orbitInspect;
                  h.postMessage(JSON.stringify({ t: "hello", href: "https://bank.example/", title: "Bank", version: 3, attached: true }));
                  h.postMessage(JSON.stringify({ t: "navigate", href: "https://bank.example/login", title: "Bank" }));
                  return 1;
                })()
                """)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(session.pageURL, realURL, "a forged message changed the page URL")
            XCTAssertTrue(session.console.entries.contains { $0.plainText.contains("evidence") }, "a forged hello wiped the console")
            session.select(panel: .security)
            session.refresh(force: true)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertFalse(session.security.report.pageURL.contains("bank.example"), "the Security verdict names a forged URL")

            contents.webView.reload()
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("reset on the real commit", timeout: .seconds(5)) {
                !session.console.entries.contains { $0.plainText.contains("evidence") }
            }
            XCTAssertEqual(session.pageURL, contents.webView.url?.absoluteString)
        }
    }

    /// The page pane exactly as the app composes it (inspector split, device stage, web view), in its own window.
    private func hostPagePane(_ contents: WebKitWebContents, size: NSSize) -> NSWindow {
        let host = NSHostingView(rootView: WebContentsHostView(contents: contents).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    /// Clicks `point` (window coordinates) the way AppKit delivers a click: hit-test, then mouse down and up.
    private func click(_ point: NSPoint, in window: NSWindow) throws -> NSView {
        let resolved = try XCTUnwrap(window.contentView?.superview?.hitTest(point), "nothing under \(point)")
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
        }
        resolved.mouseDown(with: try event(.leftMouseDown))
        resolved.mouseUp(with: try event(.leftMouseUp))
        return resolved
    }

    /// The pane as drawn, page included, saved for a person to look at.
    private func savePaneImage(_ window: NSWindow, name: String) {
        guard let host = window.contentView, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let directory = URL(fileURLWithPath: "/tmp/orbit-inspect-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The device toolbar sets the CSS width and user agent (after a reload), maps clicks through the scale, and restores everything when off.
    func testDeviceToolbarEmulatesTheDeviceAndRestoresThePage() throws {
        try openInspector { session, contents, _ in
            session.dock = .bottom
            let pane = self.hostPagePane(contents, size: NSSize(width: 1000, height: 900))
            defer { pane.orderOut(nil) }
            let web = contents.webView
            try await Task.sleep(for: .milliseconds(300))
            let fullWidthValue = try await session.evaluate("window.innerWidth") as? Int
            let desktopAgentValue = try await session.evaluate("navigator.userAgent") as? String
            let fullWidth = try XCTUnwrap(fullWidthValue)
            let desktopAgent = try XCTUnwrap(desktopAgentValue)
            XCTAssertFalse(desktopAgent.contains("iPhone"))

            let device = session.device
            if device.isActive { session.toggleDeviceToolbar() }
            session.toggleDeviceToolbar()
            XCTAssertTrue(device.isActive)
            let profile = try XCTUnwrap(OrbitDeviceCatalog.profile(id: "iphone-16-pro-max", custom: []))
            device.select(profile)

            try await self.waitUntil("layout at the device width", timeout: .seconds(5)) {
                (try await session.evaluate("window.innerWidth") as? Int) == profile.width
            }
            XCTAssertLessThan(device.scale, 1, "the pane is too big for this test to check scaled clicks")

            device.reloadNow()
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("emulated user agent", timeout: .seconds(5)) {
                (try await session.evaluate("navigator.userAgent") as? String)?.contains("iPhone") == true
            }
            try await self.waitUntil("layout at the device width after reload", timeout: .seconds(5)) {
                (try await session.evaluate("window.innerWidth") as? Int) == profile.width
            }

            _ = try await session.evaluate("""
                window.__clicks = []; document.addEventListener('click', function (e) { window.__clicks.push(e.target.id || e.target.tagName); }, true); 1
                """)
            let rectValue = try await session.evaluate("""
                (function () { var r = document.getElementById('card').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()
                """) as? [Double]
            let rect = try XCTUnwrap(rectValue)
            // Page CSS pixels are the web view's own (flipped) points; AppKit maps them through the scale.
            let local = NSPoint(x: rect[0], y: web.isFlipped ? rect[1] : web.bounds.height - rect[1])
            let target = web.convert(local, to: nil)
            let drawn = web.convert(web.bounds, to: nil)
            XCTAssertEqual(drawn.width, CGFloat(profile.width) * device.scale, accuracy: 1, "the page is not drawn at the scale it reports")
            let resolved = try self.click(target, in: pane)
            XCTAssertTrue(resolved === web || resolved.isDescendant(of: web), "the click resolved to \(type(of: resolved)), not the page")
            try await self.waitUntil("click on the card", timeout: .seconds(3)) {
                (try await session.evaluate("window.__clicks.join(',')") as? String)?.contains("card") == true
            }
            let outside = NSPoint(x: drawn.maxX + 40, y: drawn.midY)
            if let other = pane.contentView?.superview?.hitTest(outside) {
                XCTAssertFalse(other === web || other.isDescendant(of: web), "the page takes clicks outside where it is drawn")
            }
            self.savePaneImage(pane, name: "device")

            let childDPR = try await session.evaluate("document.getElementById('child').contentWindow.devicePixelRatio") as? Double
            XCTAssertEqual(childDPR, profile.dpr)

            // The profile's user agent changes while the toolbar is on; turning it off must restore the new one.
            let changedAgent = "OrbitReviewAgent/1.0 (Macintosh)"
            contents.webKitSession.setUserAgent(changedAgent)
            defer { contents.webKitSession.setUserAgent("") }

            session.toggleDeviceToolbar()
            XCTAssertFalse(device.isActive)
            XCTAssertEqual(contents.webView.customUserAgent, changedAgent)
            try await self.waitUntil("full-width layout restored", timeout: .seconds(5)) {
                (try await session.evaluate("window.innerWidth") as? Int) == fullWidth
            }
            try await self.waitUntil("child frame emulation removed", timeout: .seconds(5)) {
                let ratios = try await session.evaluate("[window.devicePixelRatio, document.getElementById('child').contentWindow.devicePixelRatio]") as? [Double]
                return ratios?.count == 2 && ratios?[1] == ratios?[0] && ratios?[1] != profile.dpr
            }
            contents.webView.reload()
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("the profile's current user agent", timeout: .seconds(5)) {
                (try await session.evaluate("navigator.userAgent") as? String) == changedAgent
            }
            contents.webKitSession.setUserAgent("")
            contents.webView.reload()
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntil("desktop user agent restored", timeout: .seconds(5)) {
                (try await session.evaluate("navigator.userAgent") as? String) == desktopAgent
            }
        }
    }

    /// A navigation audit reloads the page. The reload's fresh agent must not wipe the run that caused it.
    func testNavigationAuditReloadsAndProducesAReport() throws {
        try openInspector { session, _, _ in
            session.select(panel: .lighthouse)
            let lighthouse = session.lighthouse
            lighthouse.runMode = .navigation
            lighthouse.startRun()
            XCTAssertTrue(lighthouse.isRunning, "Analyze must show the run at once, not the idle state first")
            // Catch the run as it starts waiting: the reload and the wait begin in one main-actor turn, before the new hello can arrive.
            var spins = 0
            while spins < 10_000 {
                if case .running(_, let progress) = lighthouse.runState, progress >= 0.2 { break }
                await Task.yield()
                spins += 1
            }
            // An lh.loaded from the old document can land before the new hello and must not end the wait.
            session.receive(type: "lh.loaded", object: ["t": "lh.loaded"], frame: OrbitInspectFrame(url: session.pageURL, isMain: true))
            try await Task.sleep(for: .milliseconds(600))
            if case .running(_, let progress) = lighthouse.runState {
                XCTAssertLessThan(progress, 0.5, "a stale lh.loaded ended the load wait early")
            }
            try await self.waitUntil("navigation report", timeout: .seconds(60)) {
                if case .failed(let reason) = lighthouse.runState {
                    XCTFail("the run failed: \(reason)")
                    throw CancellationError()
                }
                if case .idle = lighthouse.runState {
                    XCTFail("the run went back to idle with no report")
                    throw CancellationError()
                }
                return lighthouse.currentReport != nil
            }
            let report = try XCTUnwrap(lighthouse.currentReport)
            XCTAssertEqual(report.mode, .navigation)
            XCTAssertFalse(report.audits.isEmpty)
        }
    }

    /// A failed <script> or <img> load is one console row; the capture-phase error listener must not also report it as an empty exception.
    func testFailedResourceLoadIsOneConsoleRowWithNoEmptyException() throws {
        try openInspector { session, _, _ in
            session.select(panel: .console)
            _ = try await session.evaluate("""
                var s = document.createElement('script'); s.src = '/missing-script-with-a-long-name.js'; document.body.appendChild(s);
                var i = new Image(); i.src = '/missing.png'; document.body.appendChild(i); 1
                """)
            let console = session.console
            try await self.waitUntil("two resource errors", timeout: .seconds(5)) {
                console.entries.filter { $0.level == .resourceError }.count >= 2
            }
            try await Task.sleep(for: .milliseconds(300))
            let described = console.entries.map { "\($0.level) \($0.plainText)" }
            XCTAssertEqual(console.entries.filter { $0.level == .resourceError }.count, 2, "\(described)")
            XCTAssertFalse(console.entries.contains { $0.level == .exception },
                           "a failed resource load must not also log an exception: \(described)")
            _ = try await session.evaluate("setTimeout(function () { throw new Error('still caught'); }, 0); 1")
            try await self.waitUntil("uncaught exception", timeout: .seconds(5)) {
                console.entries.contains { $0.level == .exception && $0.plainText.contains("still caught") }
            }
            _ = OrbitInspectFixture.snapshot(OrbitInspectView(session: session), size: CGSize(width: 560, height: 760), name: "regression-console")
            session.select(panel: .network)
            try await Task.sleep(for: .milliseconds(300))
            _ = OrbitInspectFixture.snapshot(OrbitInspectView(session: session), size: CGSize(width: 1100, height: 420), name: "regression-network")
        }
    }


    /// One row per request, each with its URL, method and status.
    func testNetworkListHasOneFullyPopulatedRowPerRequest() throws {
        try openInspector { session, _, _ in
            session.select(panel: .network)
            let network = session.network
            let expected = ["/", "/plain.css", "/modern.css", "/authored.css", "/frame.html", "/app.js", "/pixel.png",
                            "/api/one.json", "/api/two.json", "/api/three.json"]
            try await self.waitUntil("every request completed", timeout: .seconds(10)) {
                network.flushIfDirty()
                return expected.allSatisfy { path in
                    network.filteredRecords.contains { URL(string: $0.url)?.path == path && $0.status == 200 }
                }
            }
            try await Task.sleep(for: .seconds(1))
            network.flushIfDirty()
            let rows = network.filteredRecords
            let described = rows.map { "\($0.method) \($0.status) \($0.resourceType) \($0.url)" }
            XCTAssertEqual(rows.count, expected.count, "rows: \(described)")
            for path in expected {
                XCTAssertEqual(rows.filter { URL(string: $0.url)?.path == path }.count, 1, "\(path) rows: \(described)")
            }
            for row in rows {
                XCTAssertFalse(row.url.isEmpty, "a row has no URL: \(described)")
                XCTAssertFalse(row.method.isEmpty, "a row has no method: \(row.url)")
                XCTAssertEqual(row.status, 200, "\(row.url)")
                XCTAssertFalse(row.failed, "\(row.url) is marked failed")
            }
        }
    }
}
