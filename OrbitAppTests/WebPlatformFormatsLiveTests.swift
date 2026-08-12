//  Live coverage for real formats: image codecs, WOFF2 fonts, CSS grid/flexbox/calc,
//  fetch() JSON, and gzip/brotli decompression -- real bytes served over a real socket.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebPlatformFormatsLiveTests: XCTestCase {

    private func waitUntilTrue(
        _ contents: ChromiumWebContents,
        _ expression: String,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            let result = try await contents.evaluateJavaScript(expression)
            if (result as? Bool) == true { return }
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "'\(expression)' never became true")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Image codecs

    private func decodedImageDimensions(routePath: String, contentType: String, data: Data) throws -> (width: Int, height: Int) {
        try LiveChromiumEngineHost.runLive { () -> (Int, Int) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(
                    contentType: "text/html",
                    body: "<html><body><img id=\"i\" src=\"\(routePath)\"></body></html>"
                ),
                routePath: LiveHTTPTestServer.Route(contentType: contentType, data: data),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)

            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            try await self.waitUntilTrue(contents, "document.getElementById('i').complete && document.getElementById('i').naturalWidth > 0")

            let width = try await contents.evaluateJavaScript("document.getElementById('i').naturalWidth")
            let height = try await contents.evaluateJavaScript("document.getElementById('i').naturalHeight")
            return ((width as? NSNumber)?.intValue ?? -1, (height as? NSNumber)?.intValue ?? -1)
        }
    }

    func testJPEGImageDecodesToItsRealPixelDimensions() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let size = try decodedImageDimensions(routePath: "/i.jpg", contentType: "image/jpeg", data: LiveMediaFixtures.jpeg)
        XCTAssertEqual(size.width, 32, "a real 32x32 JPEG did not decode to its real width")
        XCTAssertEqual(size.height, 32, "a real 32x32 JPEG did not decode to its real height")
    }

    func testPNGImageDecodesToItsRealPixelDimensions() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let size = try decodedImageDimensions(routePath: "/i.png", contentType: "image/png", data: LiveMediaFixtures.png)
        XCTAssertEqual(size.width, 32)
        XCTAssertEqual(size.height, 32)
    }

    func testWebPImageDecodesToItsRealPixelDimensions() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let size = try decodedImageDimensions(routePath: "/i.webp", contentType: "image/webp", data: LiveMediaFixtures.webp)
        XCTAssertEqual(size.width, 32, "a real lossy WebP did not decode through Blink's real libwebp decoder")
        XCTAssertEqual(size.height, 32)
    }

    func testAVIFImageDecodesToItsRealPixelDimensions() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let size = try decodedImageDimensions(routePath: "/i.avif", contentType: "image/avif", data: LiveMediaFixtures.avif)
        XCTAssertEqual(size.width, 32, "a real AVIF did not decode through Blink's real libaom/dav1d decoder")
        XCTAssertEqual(size.height, 32)
    }

    func testSVGImageRendersAndReportsItsIntrinsicSize() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let size = try decodedImageDimensions(routePath: "/i.svg", contentType: "image/svg+xml", data: LiveMediaFixtures.svg)
        XCTAssertEqual(size.width, 32, "an <img src> SVG did not report its declared intrinsic width")
        XCTAssertEqual(size.height, 32)
    }

    // MARK: - WOFF2 web font

    func testWOFF2WebFontLoadsAndChangesRenderedTextWidth() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (loaded, fontFamilyWidth, monospaceWidth) = try LiveChromiumEngineHost.runLive { () -> (Bool, Double, Double) in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-font-test</body></html>"),
                "/orbit-test.woff2": LiveHTTPTestServer.Route(contentType: "font/woff2", data: LiveMediaFixtures.woff2),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)

            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            window.__orbitFontLoaded = false;
            var face = new FontFace('OrbitTestFont', 'url(/orbit-test.woff2)');
            face.load().then(function(loadedFace) {
              document.fonts.add(loadedFace);
              window.__orbitFontLoaded = true;
            }).catch(function(e) { window.__orbitFontLoadError = String(e); });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitFontLoaded === true || !!window.__orbitFontLoadError")

            let loadedValue = try await contents.evaluateJavaScript("window.__orbitFontLoaded === true")
            let widths = try await contents.evaluateJavaScript("""
            (function() {
              var canvas = document.createElement('canvas');
              var ctx = canvas.getContext('2d');
              var text = 'Orbit Live Test Measurement WWWiiillll';
              ctx.font = '24px OrbitTestFont, monospace';
              var withFont = ctx.measureText(text).width;
              ctx.font = '24px monospace';
              var monospace = ctx.measureText(text).width;
              return [withFont, monospace];
            })();
            """)
            let widthArray = widths as? [Any] ?? []
            let withFont = (widthArray.first as? NSNumber)?.doubleValue ?? -1
            let monospace = (widthArray.last as? NSNumber)?.doubleValue ?? -2
            return ((loadedValue as? Bool) ?? false, withFont, monospace)
        }

        XCTAssertTrue(loaded, "a real WOFF2 FontFace failed to parse/load through Blink's real font loader")
        XCTAssertNotEqual(
            fontFamilyWidth, monospaceWidth, accuracy: 0.01,
            "text measured in the real loaded WOFF2 font should differ from the same text in a monospace fallback -- the real glyph metrics never took effect"
        )
    }

    // MARK: - CSS features (real Blink layout)

    func testCSSGridAndFlexboxProduceRealComputedLayout() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (gridItemLeft, gridItemTop, flexGap) = try LiveChromiumEngineHost.runLive { () -> (Double, Double, Double) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)

            contents.loadHTML("""
            <html><body style="margin:0">
            <div id="grid" style="display:grid;grid-template-columns:100px 100px;grid-template-rows:50px 50px">
              <div></div><div id="gridItem"></div>
            </div>
            <div id="flex" style="display:flex;gap:20px">
              <div style="width:10px;height:10px"></div><div id="flexSecond" style="width:10px;height:10px"></div>
            </div>
            </body></html>
            """, baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let gridRect = try await contents.evaluateJavaScript("""
            (function() { var r = document.getElementById('gridItem').getBoundingClientRect(); return [r.left, r.top]; })();
            """)
            let flexRect = try await contents.evaluateJavaScript("""
            (function() {
              var flex = document.getElementById('flex').getBoundingClientRect();
              var second = document.getElementById('flexSecond').getBoundingClientRect();
              return second.left - flex.left;
            })();
            """)
            let gridArray = gridRect as? [Any] ?? []
            let left = (gridArray.first as? NSNumber)?.doubleValue ?? -1
            let top = (gridArray.last as? NSNumber)?.doubleValue ?? -1
            let gap = (flexRect as? NSNumber)?.doubleValue ?? -1
            return (left, top, gap)
        }

        XCTAssertEqual(gridItemLeft, 100, accuracy: 1, "the second grid column did not lay out at its real 100px track offset")
        XCTAssertEqual(gridItemTop, 0, accuracy: 1, "grid-template-rows placed the first row's second item at the wrong offset")
        XCTAssertEqual(flexGap, 30, accuracy: 1, "a 20px flex gap plus a 10px item should put the second flex child 30px from the first's left edge")
    }

    func testCSSCustomPropertiesAndCalcResolveToRealComputedValues() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let (computedWidth, computedColor) = try LiveChromiumEngineHost.runLive { () -> (Double, String) in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)

            contents.loadHTML("""
            <html><body style="margin:0">
            <div id="box" style="--orbit-base: 40px; --orbit-color: rgb(9, 99, 199); width: calc(var(--orbit-base) * 3 + 10px); color: var(--orbit-color)"></div>
            </body></html>
            """, baseURL: nil)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let width = try await contents.evaluateJavaScript("document.getElementById('box').getBoundingClientRect().width")
            let color = try await contents.evaluateJavaScript("getComputedStyle(document.getElementById('box')).color")
            return ((width as? NSNumber)?.doubleValue ?? -1, color as? String ?? "")
        }

        XCTAssertEqual(computedWidth, 130, accuracy: 1, "calc(var(--orbit-base) * 3 + 10px) with --orbit-base:40px should resolve to 130px")
        XCTAssertEqual(computedColor, "rgb(9, 99, 199)", "a CSS custom property did not resolve to its real computed color")
    }

    // MARK: - fetch(): JSON, gzip, brotli

    func testFetchReturnsRealJSONBody() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let note = try LiveChromiumEngineHost.runLive { () -> String in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-fetch-json-test</body></html>"),
                "/data.json": LiveHTTPTestServer.Route(contentType: "application/json", data: LiveMediaFixtures.jsonBody),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            _ = try await contents.evaluateJavaScript("""
            window.__orbitFetchNote = null;
            fetch('/data.json').then(function(r) { return r.json(); }).then(function(json) {
              window.__orbitFetchNote = json.note + ':' + json.values.length;
            }).catch(function(e) { window.__orbitFetchNote = 'error:' + String(e); });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitFetchNote !== null")
            return (try await contents.evaluateJavaScript("window.__orbitFetchNote")) as? String ?? ""
        }
        XCTAssertEqual(note, "compressed body round trip:200", "a real fetch().json() did not return the real JSON body's real content")
    }

    func testGzipContentEncodedResponseDecodesToTheOriginalBody() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let matches = try compressedFetchMatchesOriginal(routePath: "/data.json.gz", contentEncoding: "gzip", compressed: LiveMediaFixtures.jsonGzip)
        XCTAssertTrue(matches, "fetch() did not transparently gunzip a real Content-Encoding: gzip response to the original body")
    }

    func testBrotliContentEncodedResponseDecodesToTheOriginalBody() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let matches = try compressedFetchMatchesOriginal(routePath: "/data.json.br", contentEncoding: "br", compressed: LiveMediaFixtures.jsonBrotli)
        XCTAssertTrue(matches, "fetch() did not transparently un-brotli a real Content-Encoding: br response to the original body")
    }

    private func compressedFetchMatchesOriginal(routePath: String, contentEncoding: String, compressed: Data) throws -> Bool {
        try LiveChromiumEngineHost.runLive { () -> Bool in
            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-compression-test</body></html>"),
                routePath: LiveHTTPTestServer.Route(
                    contentType: "application/json",
                    data: compressed,
                    extraHeaders: ["Content-Encoding": contentEncoding]
                ),
            ])
            defer { server.stop() }

            let engine = await LiveChromiumEngineHost.sharedEngine()
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let originalText = String(decoding: LiveMediaFixtures.jsonBody, as: UTF8.self)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            _ = try await contents.evaluateJavaScript("""
            window.__orbitCompressionResult = null;
            fetch('\(routePath)').then(function(r) { return r.text(); }).then(function(text) {
              window.__orbitCompressionResult = (text === '\(originalText)');
            }).catch(function(e) { window.__orbitCompressionResult = false; });
            true;
            """)
            try await self.waitUntilTrue(contents, "window.__orbitCompressionResult !== null")
            let result = try await contents.evaluateJavaScript("window.__orbitCompressionResult")
            return (result as? Bool) ?? false
        }
    }
}
