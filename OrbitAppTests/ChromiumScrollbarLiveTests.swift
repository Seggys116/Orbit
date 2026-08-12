//  Covers the page (Blink-drawn) scrollbar via PageScrollbarStyleScript --
//  not OrbitScroller, which retrofits chrome NSScrollViews (OrbitScrollerLiveRetrofitTests).

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumScrollbarLiveTests: XCTestCase {

    private func installScript(on engine: ChromiumEngine) {
        engine.addUserScript(PageScrollbarStyleScript.userScript, session: engine.defaultSession)
    }

    private func sample(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return nil }
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
        return (
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    private func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    // MARK: - The reported bug: does the thumb track real scroll position?

    func testScrollbarThumbTracksRealScrollPosition() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let widthCSS = 400.0
        let heightCSS = 300.0

        let result = try LiveChromiumEngineHost.runLive {
            () -> (top: (r: Int, g: Int, b: Int)?, bottom: (r: Int, g: Int, b: Int)?,
                   topAfter: (r: Int, g: Int, b: Int)?, bottomAfter: (r: Int, g: Int, b: Int)?)? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;height:3000px;background:#ffffff\"></body></html>",
                baseURL: nil
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            guard let beforeImage = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let before = self.bitmap(from: beforeImage) else { return nil }
            let scaleX = Double(before.pixelsWide) / widthCSS
            let scaleY = Double(before.pixelsHigh) / heightCSS
            let xInScrollbar = before.pixelsWide - max(4, Int(4 * scaleX))
            let yNearTop = Int(4 * scaleY)
            let yNearBottom = before.pixelsHigh - Int(4 * scaleY) - 1

            let top = self.sample(before, x: xInScrollbar, y: yNearTop)
            let bottom = self.sample(before, x: xInScrollbar, y: yNearBottom)

            _ = try await contents.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); true;")
            // Real scrolling is compositor-driven and asynchronous; give it
            // time to commit and submit a new frame before capturing.
            try await Task.sleep(for: .milliseconds(500))

            guard let afterImage = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let after = self.bitmap(from: afterImage) else { return nil }
            let topAfter = self.sample(after, x: xInScrollbar, y: yNearTop)
            let bottomAfter = self.sample(after, x: xInScrollbar, y: yNearBottom)

            return (top, bottom, topAfter, bottomAfter)
        }

        let unwrapped = try XCTUnwrap(result, "capturePreview or bitmap decoding failed before any sample was taken")
        let top = try XCTUnwrap(unwrapped.top, "no pixel sampled near the top of the scrollbar column before scrolling")
        let bottom = try XCTUnwrap(unwrapped.bottom, "no pixel sampled near the bottom of the scrollbar column before scrolling")
        let topAfter = try XCTUnwrap(unwrapped.topAfter, "no pixel sampled near the top of the scrollbar column after scrolling")
        let bottomAfter = try XCTUnwrap(unwrapped.bottomAfter, "no pixel sampled near the bottom of the scrollbar column after scrolling")

        XCTAssertLessThan(
            top.r, 245,
            "precondition: at scrollTop=0 the thumb must be visible near the top of the track (sampled rgb(\(top.r),\(top.g),\(top.b)))"
        )
        XCTAssertGreaterThan(
            bottom.r, 245,
            "precondition: at scrollTop=0 the bottom of the track must be bare, no thumb there (sampled rgb(\(bottom.r),\(bottom.g),\(bottom.b)))"
        )
        XCTAssertGreaterThan(
            topAfter.r, 245,
            "after scrolling to the bottom of the document, the top of the track must be bare -- the thumb should have moved down. sampled rgb(\(topAfter.r),\(topAfter.g),\(topAfter.b)), was rgb(\(top.r),\(top.g),\(top.b)) before scrolling"
        )
        XCTAssertLessThan(
            bottomAfter.r, 245,
            "after scrolling to the bottom of the document, the thumb must be visible near the bottom of the track -- this is the reported bug: the scrollbar not tracking real scroll position. sampled rgb(\(bottomAfter.r),\(bottomAfter.g),\(bottomAfter.b)), was rgb(\(bottom.r),\(bottom.g),\(bottom.b)) before scrolling"
        )
    }

    // Scans the whole right-hand column (where a vertical scrollbar would
    // draw) for any non-background pixel, i.e. any trace of a thumb.
    private func rightColumnHasAnyNonBackgroundPixel(
        _ bitmap: NSBitmapImageRep,
        widthCSS: Double
    ) -> Bool {
        let scaleX = Double(bitmap.pixelsWide) / widthCSS
        let x = bitmap.pixelsWide - max(4, Int(4 * scaleX))
        var y = 0
        while y < bitmap.pixelsHigh {
            if let pixel = sample(bitmap, x: x, y: y), pixel.r < 245 { return true }
            y += 2
        }
        return false
    }

    // MARK: - Policy: a page that hides its own scrollbar is never overridden

    /// Orbit's stylesheet carries no `!important` and inserts before the
    /// page's own CSS, so a page's equal-specificity rule wins the cascade and Orbit never re-shows a hidden scrollbar.
    func testWebkitScrollbarDisplayNoneOnThePageIsNeverOverridden() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let widthCSS = 400.0
        let heightCSS = 300.0

        let (overflows, hasThumb) = try LiveChromiumEngineHost.runLive { () -> (Bool, Bool)? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
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
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            let overflows = (try await contents.evaluateJavaScript(
                "document.documentElement.scrollHeight > document.documentElement.clientHeight"
            ) as? Bool) ?? false

            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let bitmap = self.bitmap(from: image) else { return nil }
            return (overflows, self.rightColumnHasAnyNonBackgroundPixel(bitmap, widthCSS: widthCSS))
        } ?? (false, true)

        XCTAssertTrue(overflows, "precondition: the page must actually overflow, or hiding its scrollbar proves nothing")
        XCTAssertFalse(hasThumb, "a page that sets ::-webkit-scrollbar{display:none} must never have Orbit draw a thumb over it -- Orbit's stylesheet must never win over the page's own with equal specificity")
    }

    func testScrollbarWidthNoneOnThePageIsNeverOverridden() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let widthCSS = 400.0
        let heightCSS = 300.0

        let (overflows, hasThumb) = try LiveChromiumEngineHost.runLive { () -> (Bool, Bool)? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
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
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            let overflows = (try await contents.evaluateJavaScript(
                "document.documentElement.scrollHeight > document.documentElement.clientHeight"
            ) as? Bool) ?? false

            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let bitmap = self.bitmap(from: image) else { return nil }
            return (overflows, self.rightColumnHasAnyNonBackgroundPixel(bitmap, widthCSS: widthCSS))
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
        inIframe: Bool = false,
        sampleThumb: Bool = false
    ) throws -> (probe: ViewportProbe, hasThumb: Bool) {
        let widthCSS = 400.0
        let heightCSS = 300.0
        let html = inIframe
            ? iframePage(rootStyle: rootStyle, bodyStyle: bodyStyle)
            : overflowPage(rootStyle: rootStyle, bodyStyle: bodyStyle)
        let js = viewportProbeJS(target: inIframe ? "document.getElementById('f').contentWindow" : "window")

        let result = try LiveChromiumEngineHost.runLive { () -> (String, Bool)? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(html, baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
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
            guard sampleThumb else { return (json, false) }

            try await Task.sleep(for: .milliseconds(400))
            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let bitmap = self.bitmap(from: image) else { return nil }
            return (json, self.rightColumnHasAnyNonBackgroundPixel(bitmap, widthCSS: widthCSS))
        }

        let unwrapped = try XCTUnwrap(result, "the viewport probe returned nothing")
        let probe = try XCTUnwrap(ViewportProbe(json: unwrapped.0), "could not decode the viewport probe JSON: \(unwrapped.0)")
        XCTAssertEqual(probe.compatMode, "CSS1Compat", "the fixture's <!DOCTYPE html> must keep the document in standards mode -- in quirks mode body is the scrolling element and none of this is under test")
        XCTAssertEqual(probe.scrollingElement, "html", "standards mode: document.scrollingElement is always the root element (Document::ScrollingElementNoLayout, document.cc:2053-2068)")
        return (probe, unwrapped.1)
    }

    func testOverflowHiddenOnBodyPropagatesToTheViewportButStillScrollsProgrammatically() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let (probe, hasThumb) = try measureViewport(rootStyle: "", bodyStyle: "overflow:hidden", sampleThumb: true)

        XCTAssertEqual(probe.verticalScrollbar, 0, "body{overflow:hidden} with a visible root must propagate to the viewport and leave it with no vertical scrollbar")
        XCTAssertEqual(probe.horizontalScrollbar, 0, "propagation applies to both axes: no horizontal scrollbar either")
        XCTAssertFalse(hasThumb, "a viewport whose overflow is hidden draws no scrollbar, so Orbit must paint no thumb over it")
        XCTAssertEqual(probe.bodyScrollTop, 0, "the body handed its overflow to the viewport, so the body itself is not a scroll container")
        XCTAssertEqual(probe.scrollTop, 2000, "overflow:hidden on the viewport suppresses scrollbars and user scrolling, never programmatic scrolling -- ScrollableAxes() returns both axes unconditionally for a LayoutView (paint_layer_scrollable_area.cc:2484-2495)")
        XCTAssertEqual(probe.scrollLeft, 700, "the same holds horizontally")
    }

    func testOverflowHiddenOnTheRootElementPropagatesToTheViewport() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let (probe, _) = try measureViewport(rootStyle: "overflow:hidden", bodyStyle: "")

        XCTAssertEqual(probe.verticalScrollbar, 0, "html{overflow:hidden} is propagated directly -- the root wins and body is never consulted (Document::ViewportDefiningElement, document.cc:4149-4181)")
        XCTAssertEqual(probe.horizontalScrollbar, 0, "no horizontal scrollbar either")
        XCTAssertEqual(probe.scrollTop, 2000, "still programmatically scrollable, exactly as when the value came from body")
        XCTAssertEqual(probe.scrollLeft, 700, "the same holds horizontally")
    }

    func testOverflowClipOnBodyIsTreatedAsHiddenOnTheViewport() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let (probe, _) = try measureViewport(rootStyle: "", bodyStyle: "overflow:clip")

        XCTAssertEqual(probe.verticalScrollbar, 0, "clip propagates like hidden and suppresses the viewport's scrollbars")
        XCTAssertEqual(probe.horizontalScrollbar, 0, "no horizontal scrollbar either")
        XCTAssertEqual(probe.scrollTop, 2000, "clip is rewritten to hidden on the viewport (style_resolver.cc:3593-3606), so unlike clip on an ordinary box it leaves a programmatically scrollable scroll container -- WPT css/cssom-view/scrollIntoView-root-overflow-clip.html")
        XCTAssertEqual(probe.scrollLeft, 700, "the same holds horizontally")
    }

    func testOverflowClipOnTheRootElementIsTreatedAsHiddenOnTheViewport() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let (probe, _) = try measureViewport(rootStyle: "overflow:clip", bodyStyle: "")

        XCTAssertEqual(probe.verticalScrollbar, 0, "clip on the root propagates like hidden")
        XCTAssertEqual(probe.horizontalScrollbar, 0, "no horizontal scrollbar either")
        XCTAssertEqual(probe.scrollTop, 2000, "clip on the root becomes hidden on the viewport, which stays programmatically scrollable")
        XCTAssertEqual(probe.scrollLeft, 700, "the same holds horizontally")
    }

    func testMixedOverflowPropagatesPerAxis() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let (probe, _) = try measureViewport(rootStyle: "", bodyStyle: "overflow-y:hidden;overflow-x:auto")

        XCTAssertEqual(probe.verticalScrollbar, 0, "overflow-y:hidden must suppress only the vertical scrollbar")
        XCTAssertGreaterThan(probe.horizontalScrollbar, 0, "overflow-x:auto must still produce a horizontal scrollbar -- propagation is per axis, not all-or-nothing")
        XCTAssertEqual(probe.scrollTop, 2000, "the hidden axis still scrolls programmatically")
        XCTAssertEqual(probe.scrollLeft, 700, "the auto axis scrolls as usual")
    }

    /// `position:fixed` takes the body out of flow, so the document stops
    /// overflowing entirely -- unlike `overflow:hidden`, nothing is left to scroll to.
    func testPositionFixedBodyIsWhatActuallyLocksTheViewport() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

        let (probe, _) = try measureViewport(rootStyle: "", bodyStyle: "position:fixed;top:0;left:0;right:0;bottom:0")

        XCTAssertEqual(probe.documentScrollHeight, probe.documentClientHeight, "a fixed-position body contributes no scrollable overflow, so the document must not overflow")
        XCTAssertEqual(probe.verticalScrollbar, 0, "nothing to scroll means no scrollbar")
        XCTAssertEqual(probe.scrollTop, 0, "with no scrollable range even a programmatic scroll clamps to 0 -- this, not overflow:hidden, is what pins the viewport")
        XCTAssertEqual(probe.scrollLeft, 0, "the same holds horizontally")
    }

    func testOverflowPropagationInsideAnIframeMatchesTheTopLevelFrame() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")

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
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let widthCSS = 400.0
        let heightCSS = 300.0

        let hasThumb = try LiveChromiumEngineHost.runLive { () -> Bool? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;height:100px;background:#ffffff\">short</body></html>",
                baseURL: nil
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let bitmap = self.bitmap(from: image) else { return nil }
            return self.rightColumnHasAnyNonBackgroundPixel(bitmap, widthCSS: widthCSS)
        } ?? true

        XCTAssertFalse(hasThumb, "a page shorter than the viewport has nothing to scroll and must show no thumb")
    }

    // MARK: - Nested scroll containers: an inner div, not the document

    func testNestedScrollContainerTracksItsOwnScrollIndependentlyOfTheDocument() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let widthCSS = 400.0
        let heightCSS = 300.0

        let result = try LiveChromiumEngineHost.runLive {
            () -> (docScrollTop: Double, topOfDiv: (r: Int, g: Int, b: Int)?, bottomOfDiv: (r: Int, g: Int, b: Int)?)? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
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
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            _ = try await contents.evaluateJavaScript("document.getElementById('box').scrollTop = 2800; true;")
            try await Task.sleep(for: .milliseconds(400))

            let docScrollTop = (try await contents.evaluateJavaScript("document.documentElement.scrollTop") as? Double) ?? -1

            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let bitmap = self.bitmap(from: image) else { return nil }
            let scaleX = Double(bitmap.pixelsWide) / widthCSS
            let scaleY = Double(bitmap.pixelsHigh) / heightCSS
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

    func testHorizontalScrollbarThumbTracksRealScrollPosition() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let widthCSS = 400.0
        let heightCSS = 300.0

        let result = try LiveChromiumEngineHost.runLive {
            () -> (left: (r: Int, g: Int, b: Int)?, right: (r: Int, g: Int, b: Int)?,
                   leftAfter: (r: Int, g: Int, b: Int)?, rightAfter: (r: Int, g: Int, b: Int)?)? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            // height:250 < viewport height 300, so no vertical overflow;
            // width:3000 > viewport width 400 forces horizontal overflow only.
            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;width:3000px;height:250px;background:#ffffff\"></body></html>",
                baseURL: nil
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))

            guard let beforeImage = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let before = self.bitmap(from: beforeImage) else { return nil }
            let scaleX = Double(before.pixelsWide) / widthCSS
            let scaleY = Double(before.pixelsHigh) / heightCSS
            let yInScrollbar = before.pixelsHigh - max(4, Int(4 * scaleY))
            let xNearLeft = Int(4 * scaleX)
            let xNearRight = before.pixelsWide - Int(4 * scaleX) - 1

            let left = self.sample(before, x: xNearLeft, y: yInScrollbar)
            let right = self.sample(before, x: xNearRight, y: yInScrollbar)

            _ = try await contents.evaluateJavaScript("window.scrollTo(document.body.scrollWidth, 0); true;")
            try await Task.sleep(for: .milliseconds(500))

            guard let afterImage = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let after = self.bitmap(from: afterImage) else { return nil }
            let leftAfter = self.sample(after, x: xNearLeft, y: yInScrollbar)
            let rightAfter = self.sample(after, x: xNearRight, y: yInScrollbar)

            return (left, right, leftAfter, rightAfter)
        }

        let unwrapped = try XCTUnwrap(result, "capturePreview or bitmap decoding failed")
        let left = try XCTUnwrap(unwrapped.left)
        let right = try XCTUnwrap(unwrapped.right)
        let leftAfter = try XCTUnwrap(unwrapped.leftAfter)
        let rightAfter = try XCTUnwrap(unwrapped.rightAfter)

        XCTAssertLessThan(left.r, 245, "precondition: at scrollLeft=0 the thumb must be visible near the left of the horizontal track")
        XCTAssertGreaterThan(right.r, 245, "precondition: at scrollLeft=0 the right of the horizontal track must be bare")
        XCTAssertGreaterThan(leftAfter.r, 245, "after scrolling to the right edge, the left of the track must be bare")
        XCTAssertLessThan(rightAfter.r, 245, "after scrolling to the right edge, the thumb must be visible near the right of the track")
    }

    // MARK: - Reset on navigation

    func testScrollbarResetsToTheTopOnNavigationToANewPage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let widthCSS = 400.0
        let heightCSS = 300.0

        let result = try LiveChromiumEngineHost.runLive { () -> (scrollTopOnNewPage: Double, topHasThumb: Bool)? in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            self.installScript(on: engine)

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: widthCSS, height: heightCSS)

            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;height:3000px;background:#ffffff\">page A</body></html>",
                baseURL: nil
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(300))
            _ = try await contents.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); true;")
            try await Task.sleep(for: .milliseconds(400))

            contents.loadHTML(
                "<!DOCTYPE html><html><body style=\"margin:0;height:3000px;background:#ffffff\">page B</body></html>",
                baseURL: nil
            )
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await Task.sleep(for: .milliseconds(400))

            let scrollTop = (try await contents.evaluateJavaScript("document.documentElement.scrollTop") as? Double) ?? -1

            guard let image = await contents.capturePreview(rect: nil, size: CGSize(width: widthCSS, height: heightCSS)),
                  let bitmap = self.bitmap(from: image) else { return nil }
            let scaleX = Double(bitmap.pixelsWide) / widthCSS
            let scaleY = Double(bitmap.pixelsHigh) / heightCSS
            let xInScrollbar = bitmap.pixelsWide - max(4, Int(4 * scaleX))
            let yNearTop = Int(4 * scaleY)
            let top = self.sample(bitmap, x: xInScrollbar, y: yNearTop)
            return (scrollTop, (top?.r ?? 255) < 245)
        }

        let unwrapped = try XCTUnwrap(result, "capturePreview or bitmap decoding failed")
        XCTAssertEqual(unwrapped.scrollTopOnNewPage, 0, "a freshly navigated page must start scrolled to the top, never inheriting the previous document's scroll position")
        XCTAssertTrue(unwrapped.topHasThumb, "the new page's thumb must be visible at the top of the track, matching its own scrollTop of 0")
    }
}
