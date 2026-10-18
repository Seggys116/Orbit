//  Covers the page (Blink-drawn) scrollbar via PageScrollbarStyleScript --
//  not OrbitScroller, which retrofits chrome NSScrollViews (OrbitScrollerLiveRetrofitTests).

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitScrollbarLiveTests: XCTestCase {

    private func installScript(on engine: WebKitEngine) {
        engine.addUserScript(PageScrollbarStyleScript.userScript, session: engine.defaultSession)
    }

    private func sample(_ bitmap: ImagePixelSampler.SnapshotBitmap, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        bitmap.pixel(x: x, y: y).map { ($0.red, $0.green, $0.blue) }
    }

    private func bitmap(from image: NSImage) -> ImagePixelSampler.SnapshotBitmap? {
        ImagePixelSampler.bitmap(image)
    }

    // MARK: - Does Orbit's scrollbar render, and does it follow the real scroll position?

    // A WKWebView snapshot paints the page's contents and never its scrollbars, so a pixel read of the track is
    // always bare. The renderer's own geometry is what shows the styled bar is live: a custom ::-webkit-scrollbar
    // takes layout space (innerWidth - clientWidth), unlike an overlay scroller, and scrollTop is what its thumb is drawn from.
    func testScrollbarIsStyledAndTracksRealScrollPosition() throws {
        let widthCSS = 400.0
        let heightCSS = 300.0

        let result = try WebKitLiveEngineHost.runLive { () -> [String: Double]? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;height:3000px;background:#ffffff\"></body></html>",
                baseURL: nil
            )
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            let script = """
            (function () {
              var d = document.documentElement;
              function read() {
                return { gutter: window.innerWidth - d.clientWidth, hGutter: window.innerHeight - d.clientHeight, top: d.scrollTop };
              }
              window.scrollTo(0, 0);
              void d.offsetHeight;
              var before = read();
              window.scrollTo(0, d.scrollHeight);
              void d.offsetHeight;
              var after = read();
              return JSON.stringify({
                gutter: before.gutter, hGutter: before.hGutter, topBefore: before.top,
                gutterAfter: after.gutter, topAfter: after.top, maxTop: d.scrollHeight - d.clientHeight
              });
            })()
            """
            guard let json = try await contents.evaluateJavaScript(script) as? String,
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }

        let measured = try XCTUnwrap(result, "the scrollbar probe returned nothing")
        XCTAssertEqual(
            measured["gutter"], 9,
            "Orbit's ::-webkit-scrollbar (width: 9px) must be the scrollbar the page gets; a different gutter means WebKit drew its own or an overlay scroller. Measured: \(measured)"
        )
        XCTAssertEqual(measured["hGutter"], 0, "a page that only overflows vertically has no horizontal bar. Measured: \(measured)")
        XCTAssertEqual(measured["topBefore"], 0)
        XCTAssertEqual(measured["gutterAfter"], 9, "the bar must stay as scrolling moves the thumb. Measured: \(measured)")
        XCTAssertGreaterThan(try XCTUnwrap(measured["maxTop"]), 0, "precondition: the page overflows")
        XCTAssertEqual(
            measured["topAfter"], measured["maxTop"],
            "scrolling to the end must put the viewport at the end of the document, which is where the thumb sits at the bottom of the track. Measured: \(measured)"
        )
    }

    // MARK: - Policy: a page that hides its own scrollbar is never overridden

    /// Orbit's stylesheet carries no `!important` and inserts before the
    /// page's own CSS, so a page's equal-specificity rule wins the cascade and Orbit never re-shows a hidden scrollbar.
    func testWebkitScrollbarDisplayNoneOnThePageIsNeverOverridden() throws {
        let widthCSS = 400.0
        let heightCSS = 300.0

        let (overflows, hasThumb) = try WebKitLiveEngineHost.runLive { () -> (Bool, Bool)? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(
                """
                <!DOCTYPE html><html><head><style>
                ::-webkit-scrollbar { display: none; }
                </style></head>
                <body style="margin:0;height:3000px;background:#ffffff"></body></html>
                """,
                baseURL: nil
            )
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            let overflows = (try await contents.evaluateJavaScript(
                "document.documentElement.scrollHeight > document.documentElement.clientHeight"
            ) as? Bool) ?? false

            // Snapshots omit scrollbars; a bar that is drawn takes layout space.
            let gutter = (try await contents.evaluateJavaScript(
                "window.innerWidth - document.documentElement.clientWidth"
            ) as? NSNumber)?.doubleValue ?? -1
            return (overflows, gutter != 0)
        } ?? (false, true)

        XCTAssertTrue(overflows, "precondition: the page must actually overflow, or hiding its scrollbar proves nothing")
        XCTAssertFalse(hasThumb, "a page that sets ::-webkit-scrollbar{display:none} must never have Orbit draw a thumb over it -- Orbit's stylesheet must never win over the page's own with equal specificity")
    }

    func testScrollbarWidthNoneOnThePageIsNeverOverridden() throws {
        let widthCSS = 400.0
        let heightCSS = 300.0

        let (overflows, hasThumb) = try WebKitLiveEngineHost.runLive { () -> (Bool, Bool)? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(
                """
                <!DOCTYPE html><html><head><style>
                html { scrollbar-width: none; }
                </style></head>
                <body style="margin:0;height:3000px;background:#ffffff"></body></html>
                """,
                baseURL: nil
            )
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            let overflows = (try await contents.evaluateJavaScript(
                "document.documentElement.scrollHeight > document.documentElement.clientHeight"
            ) as? Bool) ?? false

            // Snapshots omit scrollbars; a bar that is drawn takes layout space.
            let gutter = (try await contents.evaluateJavaScript(
                "window.innerWidth - document.documentElement.clientWidth"
            ) as? NSNumber)?.doubleValue ?? -1
            return (overflows, gutter != 0)
        } ?? (false, true)

        XCTAssertTrue(overflows, "precondition: the page must actually overflow, or hiding its scrollbar proves nothing")
        XCTAssertFalse(hasThumb, "a page that sets scrollbar-width:none must never have Orbit draw a thumb over it")
    }

    // MARK: - Viewport overflow propagation (CSS Overflow 3 §3.3)

    /// `hidden`/`clip` propagated to the viewport (per CSS Overflow 3 §3.3)
    /// suppress scrollbars and user scrolling but never pin `window.scrollTo`, which routes around `UserInputScrollable`.
    private struct ViewportProbe {
        let scrollTop: Double
        let scrollLeft: Double
        let verticalScrollbar: Double
        let horizontalScrollbar: Double
        let documentScrollHeight: Double
        let documentClientHeight: Double
        let scrollingElement: String
        let bodyScrollTop: Double
        let compatMode: String

        init?(json: String) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            func number(_ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? -1 }
            scrollTop = number("scrollTop")
            scrollLeft = number("scrollLeft")
            verticalScrollbar = number("verticalScrollbar")
            horizontalScrollbar = number("horizontalScrollbar")
            documentScrollHeight = number("documentScrollHeight")
            documentClientHeight = number("documentClientHeight")
            bodyScrollTop = number("bodyScrollTop")
            scrollingElement = (object["scrollingElement"] as? String) ?? ""
            compatMode = (object["compatMode"] as? String) ?? ""
        }
    }

    /// 3000x3000 of content in a 400x300 (or 300x200, in a frame) viewport, so
    /// both axes overflow and (700, 2000) is well inside the scrollable range.
    private func overflowPage(rootStyle: String, bodyStyle: String) -> String {
        """
        <!DOCTYPE html><html style="\(rootStyle)"><body style="margin:0;background:#ffffff;\(bodyStyle)">\
        <div style="width:3000px;height:3000px;background:#ffffff"></div></body></html>
        """
    }

    private func iframePage(rootStyle: String, bodyStyle: String) -> String {
        let inner = overflowPage(rootStyle: rootStyle, bodyStyle: bodyStyle)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!DOCTYPE html><html><body style="margin:0;background:#ffffff">\
        <iframe id="f" style="width:300px;height:200px;border:0" srcdoc="\(inner)"></iframe></body></html>
        """
    }

    /// `innerWidth - documentElement.clientWidth` is the scrollbar's layout
    /// width: Orbit's custom (non-overlay) scrollbar makes a nonzero gutter mean a scrollbar.
    private func viewportProbeJS(target: String) -> String {
        """
        (function () {
          var w = \(target);
          var doc = w.document, d = doc.documentElement, b = doc.body;
          w.scrollTo(0, 0);
          void d.offsetHeight;
          var vertical = w.innerWidth - d.clientWidth;
          var horizontal = w.innerHeight - d.clientHeight;
          w.scrollTo(700, 2000);
          void d.offsetHeight;
          return JSON.stringify({
            scrollTop: d.scrollTop,
            scrollLeft: d.scrollLeft,
            verticalScrollbar: vertical,
            horizontalScrollbar: horizontal,
            documentScrollHeight: d.scrollHeight,
            documentClientHeight: d.clientHeight,
            scrollingElement: doc.scrollingElement ? doc.scrollingElement.tagName.toLowerCase() : "",
            bodyScrollTop: b.scrollTop,
            compatMode: doc.compatMode
          });
        })()
        """
    }

    private func measureViewport(
        rootStyle: String,
        bodyStyle: String,
        inIframe: Bool = false
    ) throws -> (probe: ViewportProbe, hasThumb: Bool) {
        let widthCSS = 400.0
        let heightCSS = 300.0
        let html = inIframe
            ? iframePage(rootStyle: rootStyle, bodyStyle: bodyStyle)
            : overflowPage(rootStyle: rootStyle, bodyStyle: bodyStyle)
        let js = viewportProbeJS(target: inIframe ? "document.getElementById('f').contentWindow" : "window")

        let result = try WebKitLiveEngineHost.runLive { () -> (String, Bool)? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(html, baseURL: nil)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            if inIframe {
                for _ in 0..<50 {
                    let ready = try await contents.evaluateJavaScript(
                        "(document.getElementById('f').contentDocument || {}).readyState || ''"
                    ) as? String
                    if ready == "complete" { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }

            guard let json = try await contents.evaluateJavaScript(js) as? String else { return nil }
            return (json, false)
        }

        let unwrapped = try XCTUnwrap(result, "the viewport probe returned nothing")
        let probe = try XCTUnwrap(ViewportProbe(json: unwrapped.0), "could not decode the viewport probe JSON: \(unwrapped.0)")
        XCTAssertEqual(probe.compatMode, "CSS1Compat", "the fixture's <!DOCTYPE html> must keep the document in standards mode -- in quirks mode body is the scrolling element and none of this is under test")
        XCTAssertEqual(probe.scrollingElement, "html", "standards mode: document.scrollingElement is always the root element (Document::ScrollingElementNoLayout, document.cc:2053-2068)")
        return (probe, probe.verticalScrollbar != 0 || probe.horizontalScrollbar != 0)
    }

    func testOverflowHiddenOnBodyPropagatesToTheViewportButStillScrollsProgrammatically() throws {

        let (probe, hasThumb) = try measureViewport(rootStyle: "", bodyStyle: "overflow:hidden")

        XCTAssertEqual(probe.verticalScrollbar, 0, "body{overflow:hidden} with a visible root must propagate to the viewport and leave it with no vertical scrollbar")
        XCTAssertEqual(probe.horizontalScrollbar, 0, "propagation applies to both axes: no horizontal scrollbar either")
        XCTAssertFalse(hasThumb, "a viewport whose overflow is hidden draws no scrollbar, so Orbit must paint no thumb over it")
        XCTAssertEqual(probe.bodyScrollTop, 0, "the body handed its overflow to the viewport, so the body itself is not a scroll container")
        XCTAssertEqual(probe.scrollTop, 2000, "overflow:hidden on the viewport suppresses scrollbars and user scrolling, never programmatic scrolling -- ScrollableAxes() returns both axes unconditionally for a LayoutView (paint_layer_scrollable_area.cc:2484-2495)")
        XCTAssertEqual(probe.scrollLeft, 700, "the same holds horizontally")
    }

    func testOverflowHiddenOnTheRootElementPropagatesToTheViewport() throws {

        let (probe, _) = try measureViewport(rootStyle: "overflow:hidden", bodyStyle: "")

        XCTAssertEqual(probe.verticalScrollbar, 0, "html{overflow:hidden} is propagated directly -- the root wins and body is never consulted (Document::ViewportDefiningElement, document.cc:4149-4181)")
        XCTAssertEqual(probe.horizontalScrollbar, 0, "no horizontal scrollbar either")
        XCTAssertEqual(probe.scrollTop, 2000, "still programmatically scrollable, exactly as when the value came from body")
        XCTAssertEqual(probe.scrollLeft, 700, "the same holds horizontally")
    }

    func testOverflowClipOnBodyIsTreatedAsHiddenOnTheViewport() throws {

        let (probe, _) = try measureViewport(rootStyle: "", bodyStyle: "overflow:clip")

        XCTAssertEqual(probe.verticalScrollbar, 0, "clip propagates like hidden and suppresses the viewport's scrollbars")
        XCTAssertEqual(probe.horizontalScrollbar, 0, "no horizontal scrollbar either")
        XCTAssertEqual(probe.scrollTop, 2000, "clip is rewritten to hidden on the viewport (style_resolver.cc:3593-3606), so unlike clip on an ordinary box it leaves a programmatically scrollable scroll container -- WPT css/cssom-view/scrollIntoView-root-overflow-clip.html")
        XCTAssertEqual(probe.scrollLeft, 700, "the same holds horizontally")
    }

    func testOverflowClipOnTheRootElementIsTreatedAsHiddenOnTheViewport() throws {

        let (probe, _) = try measureViewport(rootStyle: "overflow:clip", bodyStyle: "")

        XCTAssertEqual(probe.verticalScrollbar, 0, "clip on the root propagates like hidden")
        XCTAssertEqual(probe.horizontalScrollbar, 0, "no horizontal scrollbar either")
        XCTAssertEqual(probe.scrollTop, 2000, "clip on the root becomes hidden on the viewport, which stays programmatically scrollable")
        XCTAssertEqual(probe.scrollLeft, 700, "the same holds horizontally")
    }

    func testMixedOverflowPropagatesPerAxis() throws {

        let (probe, _) = try measureViewport(rootStyle: "", bodyStyle: "overflow-y:hidden;overflow-x:auto")

        XCTAssertEqual(probe.verticalScrollbar, 0, "overflow-y:hidden must suppress only the vertical scrollbar")
        XCTAssertGreaterThan(probe.horizontalScrollbar, 0, "overflow-x:auto must still produce a horizontal scrollbar -- propagation is per axis, not all-or-nothing")
        XCTAssertEqual(probe.scrollTop, 2000, "the hidden axis still scrolls programmatically")
        XCTAssertEqual(probe.scrollLeft, 700, "the auto axis scrolls as usual")
    }

    /// `position:fixed` takes the body out of flow, so the document stops
    /// overflowing entirely -- unlike `overflow:hidden`, nothing is left to scroll to.
    func testPositionFixedBodyIsWhatActuallyLocksTheViewport() throws {

        let (probe, _) = try measureViewport(rootStyle: "", bodyStyle: "position:fixed;top:0;left:0;right:0;bottom:0")

        XCTAssertEqual(probe.documentScrollHeight, probe.documentClientHeight, "a fixed-position body contributes no scrollable overflow, so the document must not overflow")
        XCTAssertEqual(probe.verticalScrollbar, 0, "nothing to scroll means no scrollbar")
        XCTAssertEqual(probe.scrollTop, 0, "with no scrollable range even a programmatic scroll clamps to 0 -- this, not overflow:hidden, is what pins the viewport")
        XCTAssertEqual(probe.scrollLeft, 0, "the same holds horizontally")
    }

    func testOverflowPropagationInsideAnIframeMatchesTheTopLevelFrame() throws {

        let (hidden, _) = try measureViewport(rootStyle: "", bodyStyle: "overflow:hidden", inIframe: true)
        XCTAssertEqual(hidden.verticalScrollbar, 0, "an iframe has its own viewport and the same propagation rule applies to it")
        XCTAssertEqual(hidden.scrollTop, 2000, "and the same programmatic scrollability")

        let clipped = try measureViewport(rootStyle: "overflow:clip", bodyStyle: "", inIframe: true).probe
        XCTAssertEqual(clipped.verticalScrollbar, 0, "clip on an iframe's root propagates like hidden")
        XCTAssertEqual(clipped.scrollTop, 2000, "and leaves the frame programmatically scrollable")

        let locked = try measureViewport(rootStyle: "", bodyStyle: "position:fixed;top:0;left:0;right:0;bottom:0", inIframe: true).probe
        XCTAssertEqual(locked.documentScrollHeight, locked.documentClientHeight, "a fixed body locks an iframe's viewport the same way it locks the top frame's")
        XCTAssertEqual(locked.scrollTop, 0, "so the iframe refuses the scroll")
    }

    // MARK: - A non-scrollable page draws no scrollbar

    func testShortNonOverflowingPageHasNoScrollbar() throws {
        let widthCSS = 400.0
        let heightCSS = 300.0

        let hasThumb = try WebKitLiveEngineHost.runLive { () -> Bool? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;height:100px;background:#ffffff\">short</body></html>",
                baseURL: nil
            )
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            // Snapshots omit scrollbars; a bar that is drawn takes layout space.
            let gutter = (try await contents.evaluateJavaScript(
                "window.innerWidth - document.documentElement.clientWidth"
            ) as? NSNumber)?.doubleValue ?? -1
            return gutter != 0
        } ?? true

        XCTAssertFalse(hasThumb, "a page shorter than the viewport has nothing to scroll and must show no thumb")
    }

    // MARK: - Nested scroll containers: an inner div, not the document

    func testNestedScrollContainerTracksItsOwnScrollIndependentlyOfTheDocument() throws {
        let widthCSS = 400.0
        let heightCSS = 300.0

        let result = try WebKitLiveEngineHost.runLive {
            () -> (docScrollTop: Double, topOfDiv: (r: Int, g: Int, b: Int)?, bottomOfDiv: (r: Int, g: Int, b: Int)?)? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            // The document itself never overflows (body is shorter than the
            // viewport); only #box, an inner container, scrolls.
            contents.loadHTML(
                """
                <!DOCTYPE html><html><body style="margin:0;height:250px;background:#ffffff">
                <div id="box" style="position:absolute;top:20px;left:20px;width:200px;height:200px;overflow:auto;background:#ffffff">
                <div style="height:3000px;background:#ffffff"></div>
                </div>
                </body></html>
                """,
                baseURL: nil
            )
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            _ = try await contents.evaluateJavaScript("document.getElementById('box').scrollTop = 2800; true;")
            try await Task.sleep(for: .milliseconds(400))

            let docScrollTop = (try await contents.evaluateJavaScript("document.documentElement.scrollTop") as? Double) ?? -1

            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let bitmap = self.bitmap(from: image) else { return nil }
            let scaleX = Double(bitmap.width) / widthCSS
            let scaleY = Double(bitmap.height) / heightCSS
            // #box spans CSS x in [20, 220), y in [20, 220); its own scrollbar
            // sits a few px inside its own right edge, not the viewport's.
            let xInBoxScrollbar = Int((220 - 5) * scaleX)
            let yNearBoxTop = Int((20 + 4) * scaleY)
            let yNearBoxBottom = Int((220 - 4) * scaleY)

            let topOfDiv = self.sample(bitmap, x: xInBoxScrollbar, y: yNearBoxTop)
            let bottomOfDiv = self.sample(bitmap, x: xInBoxScrollbar, y: yNearBoxBottom)
            return (docScrollTop, topOfDiv, bottomOfDiv)
        }

        let unwrapped = try XCTUnwrap(result, "capturePreview or bitmap decoding failed")
        XCTAssertEqual(unwrapped.docScrollTop, 0, "scrolling the inner div must never move the document itself")
        let bottomOfDiv = try XCTUnwrap(unwrapped.bottomOfDiv, "no pixel sampled near the bottom of the inner div's own scrollbar")
        XCTAssertLessThan(
            bottomOfDiv.r, 245,
            "after scrolling #box to near its own bottom, its own thumb must be visible near the bottom of its own track, not the document's -- sampled rgb(\(bottomOfDiv.r),\(bottomOfDiv.g),\(bottomOfDiv.b))"
        )
    }

    // MARK: - Horizontal scrolling

    // Geometry rather than pixels for the viewport bar: snapshots omit it (see the vertical test above).
    func testHorizontalScrollbarIsStyledAndTracksRealScrollPosition() throws {
        let widthCSS = 400.0
        let heightCSS = 300.0

        let result = try WebKitLiveEngineHost.runLive { () -> [String: Double]? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            // height:250 < viewport height 300, so no vertical overflow;
            // width:3000 > viewport width 400 forces horizontal overflow only.
            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;width:3000px;height:250px;background:#ffffff\"></body></html>",
                baseURL: nil
            )
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            let script = """
            (function () {
              var d = document.documentElement;
              window.scrollTo(0, 0);
              void d.offsetHeight;
              var hGutter = window.innerHeight - d.clientHeight;
              var vGutter = window.innerWidth - d.clientWidth;
              var leftBefore = d.scrollLeft;
              window.scrollTo(d.scrollWidth, 0);
              void d.offsetHeight;
              return JSON.stringify({
                hGutter: hGutter, vGutter: vGutter, leftBefore: leftBefore,
                leftAfter: d.scrollLeft, maxLeft: d.scrollWidth - d.clientWidth
              });
            })()
            """
            guard let json = try await contents.evaluateJavaScript(script) as? String,
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }

        let measured = try XCTUnwrap(result, "the scrollbar probe returned nothing")
        XCTAssertEqual(measured["hGutter"], 9, "Orbit's horizontal scrollbar (height: 9px) must be the one the page gets. Measured: \(measured)")
        XCTAssertEqual(measured["vGutter"], 0, "a page that only overflows horizontally has no vertical bar. Measured: \(measured)")
        XCTAssertEqual(measured["leftBefore"], 0)
        XCTAssertGreaterThan(try XCTUnwrap(measured["maxLeft"]), 0, "precondition: the page overflows horizontally")
        XCTAssertEqual(measured["leftAfter"], measured["maxLeft"], "scrolling to the right edge must put the viewport there. Measured: \(measured)")
    }

    // MARK: - Reset on navigation

    func testScrollbarResetsToTheTopOnNavigationToANewPage() throws {
        let widthCSS = 400.0
        let heightCSS = 300.0

        let result = try WebKitLiveEngineHost.runLive { () -> (scrollTopOnNewPage: Double, gutter: Double)? in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;height:3000px;background:#ffffff\">page A</body></html>",
                baseURL: nil
            )
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))
            _ = try await contents.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); true;")
            try await Task.sleep(for: .milliseconds(400))

            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;height:3000px;background:#ffffff\">page B</body></html>",
                baseURL: nil
            )
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(400))

            let scrollTop = (try await contents.evaluateJavaScript("document.documentElement.scrollTop") as? Double) ?? -1

            let gutter = (try await contents.evaluateJavaScript(
                "window.innerWidth - document.documentElement.clientWidth"
            ) as? NSNumber)?.doubleValue ?? -1
            return (scrollTop, gutter)
        }

        let unwrapped = try XCTUnwrap(result, "the navigation probe returned nothing")
        XCTAssertEqual(unwrapped.scrollTopOnNewPage, 0, "a freshly navigated page must start scrolled to the top, never inheriting the previous document's scroll position")
        XCTAssertEqual(unwrapped.gutter, 9, "the new page must get Orbit's scrollbar too, with its thumb at the top of the track for a scrollTop of 0")
    }
}
