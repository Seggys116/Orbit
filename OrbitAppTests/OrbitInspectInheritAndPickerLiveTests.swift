// Drives the Elements agent against real WebKit: what an `inherit` takes is named, the picker lands on text rather than the
// background behind it, and the box-model highlight leaves the page readable.

import AppKit
import XCTest
@testable import Orbit

@MainActor
final class OrbitInspectInheritAndPickerLiveTests: XCTestCase {

    private static let page = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>inherit and picker</title></head>
    <body style="margin:0">
      <div id="outer" style="color: rgb(10, 20, 30); font-size: 20px; padding: 10px; width: 300px">
        <p id="child" style="color: inherit; margin: 0">Inherited text</p>
      </div>
      <div id="bg" style="position:absolute; left:0; top:90px; width:380px; height:100px; background:#dddddd">
        <span id="decor" style="position:absolute; left:20px; top:30px; pointer-events:none; font-size:24px; color:#123456">Decorative heading</span>
      </div>
      <div id="box" style="position:absolute; left:0; top:200px; width:120px; height:60px; margin:20px; padding:15px; border:5px solid #333333; background:#ffffff">box</div>
    </body></html>
    """

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

    private func withPage(_ body: @escaping (OrbitInspectSession) async throws -> Void) throws {
        try WebKitLiveEngineHost.runLive(timeout: 120) {
            let server = try LiveHTTPTestServer(routes: [
                "/": .init(contentType: "text/html; charset=utf-8", body: Self.page),
            ])
            let contents = try await WebKitLiveEngineHost.makeContents()
            let window = LiveContextMenuGesture.host(contents)
            defer {
                server.stop()
                window.orderOut(nil)
                contents.close()
            }
            let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            OrbitDevToolsStore.shared.open(contents, panel: .elements, inspectAt: nil, armPicker: false)
            session.refresh(force: true)
            try await self.waitUntil("elements tree", timeout: .seconds(8)) { !session.elements.visibleRows.isEmpty }
            try await body(session)
        }
    }

    private func centre(of elementID: String, in session: OrbitInspectSession) async throws -> CGPoint {
        let rect = try await session.evaluate("""
            (function(){ var r = document.getElementById('\(elementID)').getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2]; })()
            """) as? [Double]
        let pair = try XCTUnwrap(rect)
        return CGPoint(x: pair[0], y: pair[1])
    }

    // MARK: - inherit

    func testAnInheritDeclarationNamesWhatItTakesAndFromWhere() throws {
        try withPage { session in
            session.inspect(at: try await self.centre(of: "child", in: session))
            try await self.waitUntil("the paragraph is selected with its rules") {
                session.elements.selectedID.flatMap { session.elements.nodes[$0] }?.name == "p"
                    && !session.elements.styleRules.isEmpty
            }

            let inline = try XCTUnwrap(session.elements.styleRules.first { $0.ruleType == "inline" })
            let color = try XCTUnwrap(inline.declarations.first { $0.property == "color" })

            XCTAssertEqual(color.value, "inherit")
            XCTAssertEqual(color.computedValue, "rgb(10, 20, 30)", "An inherit must show the value it takes, the parent's computed colour.")
            XCTAssertEqual(color.inheritedFrom, "div#outer", "It must also say which element that value comes from.")
        }
    }

    func testADeclarationThatIsNotInheritCarriesNoInheritHint() throws {
        try withPage { session in
            session.inspect(at: try await self.centre(of: "child", in: session))
            try await self.waitUntil("the paragraph's rules") { !session.elements.styleRules.isEmpty }

            let inline = try XCTUnwrap(session.elements.styleRules.first { $0.ruleType == "inline" })
            let margin = try XCTUnwrap(inline.declarations.first { $0.property == "margin" })

            XCTAssertNil(margin.inheritedFrom)
        }
    }

    // MARK: - picker

    func testPickingTextInAPointerEventsNoneLayerSelectsTheTextNotTheBackground() throws {
        try withPage { session in
            session.inspect(at: try await self.centre(of: "decor", in: session))
            try await self.waitUntil("a node is selected") { session.elements.selectedID != nil }

            let selected = try XCTUnwrap(session.elements.selectedID.flatMap { session.elements.nodes[$0] })
            XCTAssertEqual(selected.name, "span", "The text's own element must be picked, not the grey box behind it (got \(selected.name)).")
        }
    }

    func testPickingThePlainBackgroundStillSelectsTheBackground() throws {
        try withPage { session in
            // Right edge of the grey box, well clear of the heading's text.
            session.inspect(at: CGPoint(x: 360, y: 170))
            try await self.waitUntil("a node is selected") { session.elements.selectedID != nil }

            let selected = try XCTUnwrap(session.elements.selectedID.flatMap { session.elements.nodes[$0] })
            XCTAssertEqual(selected.name, "div")
        }
    }

    func testThePickerLeavesNoPointerEventsOverrideBehind() throws {
        try withPage { session in
            session.inspect(at: try await self.centre(of: "decor", in: session))
            try await self.waitUntil("a node is selected") { session.elements.selectedID != nil }

            let leftover = try await session.evaluate("document.getElementById('orbit-inspect-hit-all') ? 1 : 0") as? Int
            XCTAssertEqual(leftover, 0, "The page's pointer-events must go back to normal once the point has been resolved.")
            let decorEvents = try await session.evaluate("getComputedStyle(document.getElementById('decor')).pointerEvents") as? String
            XCTAssertEqual(decorEvents, "none")
        }
    }

    // MARK: - highlight

    func testTheBoxModelHighlightDrawsBandsNotStackedFills() throws {
        try withPage { session in
            session.inspect(at: try await self.centre(of: "box", in: session))
            try await self.waitUntil("the box is selected") {
                session.elements.selectedID.flatMap { session.elements.nodes[$0] }?.name == "div"
            }
            let id = try XCTUnwrap(session.elements.selectedID)
            session.highlight(nodeID: id)

            try await self.waitUntil("the content layer is drawn") {
                let shown = try await session.evaluate("""
                    (function(){ var h = document.getElementById('orbit-inspect-root'); if (!h || !h.shadowRoot) return 0;
                    var c = h.shadowRoot.querySelector('[data-part="content"]'); return c && getComputedStyle(c).display !== 'none' ? 1 : 0; })()
                    """) as? Int
                return shown == 1
            }

            let report = try await session.evaluate("""
                (function(){ var s = document.getElementById('orbit-inspect-root').shadowRoot; var out = {};
                ['margin','border','padding','content'].forEach(function(p){ var el = s.querySelector('[data-part="' + p + '"]'); var cs = getComputedStyle(el);
                out[p] = { bg: cs.backgroundColor, w: cs.width, h: cs.height, bt: cs.borderTopWidth, bl: cs.borderLeftWidth, style: cs.borderTopStyle }; });
                return JSON.stringify(out); })()
                """) as? String
            let data = try XCTUnwrap(report?.data(using: .utf8))
            let layers = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])

            // Margin, border and padding are rings: no fill of their own, and a border as thick as the band they stand for.
            for band in ["margin", "border", "padding"] {
                XCTAssertEqual(layers[band]?["bg"], "rgba(0, 0, 0, 0)", "\(band) must not fill its whole box, or it stacks over the layers inside it.")
                XCTAssertEqual(layers[band]?["style"], "solid", "\(band) is drawn as a ring.")
            }
            XCTAssertEqual(layers["margin"]?["bt"], "20px")
            XCTAssertEqual(layers["border"]?["bt"], "5px")
            XCTAssertEqual(layers["padding"]?["bt"], "15px")
            XCTAssertEqual(layers["content"]?["w"], "120px")
            XCTAssertEqual(layers["content"]?["h"], "60px")

            // The one fill, over the content, is translucent enough to read the page through.
            let alpha = try XCTUnwrap(layers["content"]?["bg"]).split(separator: ",").last
                .flatMap { Double($0.replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)) }
            XCTAssertLessThanOrEqual(alpha ?? 1, 0.4, "The content fill must stay translucent.")
        }
    }
}
