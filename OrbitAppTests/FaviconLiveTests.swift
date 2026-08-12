//  Proves a page's real favicon reaches Orbit and lands on the tab. Regression:
//  nothing in the engine ever called didChangeFavicon, so a hand-called unit test stayed green with no real path.

import AppKit
import Foundation
import XCTest
@testable import Orbit

@MainActor
final class FaviconLiveTests: XCTestCase {

    @MainActor
    private final class FaviconRecordingDelegate: WebContentsDelegate {
        private(set) var lastImage: NSImage?
        private(set) var lastURL: URL?
        private(set) var callCount = 0

        func webContents(_ contents: WebContents, didChangeFavicon image: NSImage?, url: URL?) {
            lastImage = image
            lastURL = url
            callCount += 1
        }

        func waitForImage(timeout: Duration = .seconds(15)) async -> NSImage? {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let lastImage { return lastImage }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return lastImage
        }
    }

    // MARK: - Declared icon formats

    func testPNGFaviconReachesTheDelegateAsADecodedImage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try runFaviconCase(
            routes: [
                "/": FaviconLiveTests.htmlRoute(head: "<link rel=\"icon\" type=\"image/png\" href=\"/icon.png\">"),
                "/icon.png": LiveHTTPTestServer.Route(contentType: "image/png", data: FaviconLiveTests.solidPNG),
            ],
            expectedPathSuffix: "/icon.png",
            what: "a declared PNG favicon"
        )
    }

    func testICOFaviconReachesTheDelegateAsADecodedImage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try runFaviconCase(
            routes: [
                "/": FaviconLiveTests.htmlRoute(head: "<link rel=\"icon\" type=\"image/x-icon\" href=\"/site.ico\">"),
                "/site.ico": LiveHTTPTestServer.Route(contentType: "image/x-icon", data: FaviconLiveTests.solidICO),
            ],
            expectedPathSuffix: "/site.ico",
            what: "a declared ICO favicon"
        )
    }

    func testSVGFaviconReachesTheDelegateAsADecodedImage() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try runFaviconCase(
            routes: [
                "/": FaviconLiveTests.htmlRoute(head: "<link rel=\"icon\" type=\"image/svg+xml\" href=\"/icon.svg\">"),
                "/icon.svg": LiveHTTPTestServer.Route(contentType: "image/svg+xml", data: FaviconLiveTests.solidSVG),
            ],
            expectedPathSuffix: "/icon.svg",
            what: "a declared SVG favicon"
        )
    }

    /// The implicit /favicon.ico a document that declares nothing still gets:
    /// blink synthesises the candidate, and only blink knows about it.
    func testUndeclaredFaviconIcoIsStillFound() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try runFaviconCase(
            routes: [
                "/": FaviconLiveTests.htmlRoute(head: ""),
                "/favicon.ico": LiveHTTPTestServer.Route(contentType: "image/x-icon", data: FaviconLiveTests.solidICO),
            ],
            expectedPathSuffix: "/favicon.ico",
            what: "the implicit /favicon.ico of a document that declares no icon"
        )
    }

    /// The valid icon is deliberately declared in the middle of three: Blink
    /// hands candidates back last-declared-first, so only a middle icon is reached by a step that isn't the first or last.
    func testAnUndecodableIconFallsBackThroughTheRemainingCandidates() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let broken = LiveHTTPTestServer.Route(contentType: "image/png", data: Data("not an image at all".utf8))
        try runFaviconCase(
            routes: [
                "/": FaviconLiveTests.htmlRoute(head: """
                <link rel="icon" type="image/png" href="/broken-1.png">\
                <link rel="icon" type="image/png" href="/good.png">\
                <link rel="icon" type="image/png" href="/broken-2.png">
                """),
                "/broken-1.png": broken,
                "/broken-2.png": broken,
                "/good.png": LiveHTTPTestServer.Route(contentType: "image/png", data: FaviconLiveTests.solidPNG),
            ],
            expectedPathSuffix: "/good.png",
            what: "the one decodable icon, declared between two that are not"
        )
    }

    /// The shape a framework-built site actually ships: a `<link rel="icon">`
    /// data: URL appended by script after parse, which re-fetching/scraping the markup never finds.
    func testScriptInjectedDataURLFaviconReachesTheDelegate() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let dataURL = "data:image/png;base64,\(FaviconLiveTests.solidPNG.base64EncodedString())"
        let injector = """
        <script>
        var link = document.createElement('link');
        link.rel = 'icon';
        link.type = 'image/png';
        link.href = '\(dataURL)';
        document.head.appendChild(link);
        </script>
        """
        let recorded = try LiveChromiumEngineHost.runLive(timeout: 60) { () -> (NSImage?, URL?) in
            let server = try LiveHTTPTestServer(routes: ["/": FaviconLiveTests.htmlRoute(head: injector)])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            let delegate = FaviconRecordingDelegate()
            contents.delegate = delegate
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let image = await delegate.waitForImage()
            return (image, delegate.lastURL)
        }

        let image = try XCTUnwrap(
            recorded.0,
            "no favicon reached the delegate for a page whose only icon is a script-injected data: URL — the exact case a modern site ships"
        )
        FaviconLiveTests.assertIsFixtureColour(image, context: "script-injected data: URL favicon")
        let url = try XCTUnwrap(recorded.1, "favicon arrived with no URL")
        XCTAssertEqual(url.scheme, "data", "expected the data: URL the page declared, got \(url.absoluteString.prefix(64))")
    }

    // MARK: - Reaching the tab model

    func testFaviconReachesTheTabAndTheFaviconCache() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let outcome = try LiveChromiumEngineHost.runLive(timeout: 60) { () -> (faviconURL: URL?, cached: NSImage?, host: String) in
            let server = try LiveHTTPTestServer(routes: [
                "/": FaviconLiveTests.htmlRoute(head: "<link rel=\"icon\" type=\"image/png\" href=\"/icon.png\">"),
                "/icon.png": LiveHTTPTestServer.Route(contentType: "image/png", data: FaviconLiveTests.solidPNG),
            ])
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }

            let env = AppEnvironment.demo
            let spaceID = env.state.spaces.first?.id
                ?? env.createSpace(
                    name: "Favicon Test Space", icon: "circle", iconIsEmoji: false,
                    theme: SpaceTheme(), profileID: env.createDefaultProfileIfNeeded()
                )
            let tab = Tab(spaceID: spaceID, section: .today, url: server.baseURL, title: "")
            env.state.tabs[tab.id] = tab
            env._test_attachWebContents(contents, for: tab.id)
            contents.delegate = env
            defer {
                env._test_detachWebContents(for: tab.id)
                env.state.tabs.removeValue(forKey: tab.id)
            }

            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let host = server.baseURL.host() ?? ""
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                if env.faviconCache.cachedImage(forHost: host) != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            return (env.state.tabs[tab.id]?.faviconURL, env.faviconCache.cachedImage(forHost: host), host)
        }

        let faviconURL = try XCTUnwrap(
            outcome.faviconURL,
            "the tab's faviconURL was never set — nothing in the engine reached AppEnvironment's didChangeFavicon"
        )
        XCTAssertTrue(faviconURL.path.hasSuffix("/icon.png"), "unexpected favicon URL \(faviconURL.absoluteString)")
        let cached = try XCTUnwrap(
            outcome.cached,
            "FaviconCache holds no image for \(outcome.host) — the sidebar and tab strip would draw the generated letter tile instead"
        )
        FaviconLiveTests.assertIsFixtureColour(cached, context: "cached favicon for \(outcome.host)")
    }

    // MARK: - Shared body

    private func runFaviconCase(
        routes: [String: LiveHTTPTestServer.Route],
        expectedPathSuffix: String,
        what: String
    ) throws {
        let recorded = try LiveChromiumEngineHost.runLive(timeout: 60) { () -> (NSImage?, URL?) in
            let server = try LiveHTTPTestServer(routes: routes)
            defer { server.stop() }

            let contents = try await LiveChromiumEngineHost.makeContents()
            defer { contents.close() }
            let delegate = FaviconRecordingDelegate()
            contents.delegate = delegate
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
            let image = await delegate.waitForImage()
            return (image, delegate.lastURL)
        }

        let image = try XCTUnwrap(recorded.0, "no favicon image ever reached the delegate for \(what)")
        FaviconLiveTests.assertIsFixtureColour(image, context: what)
        let url = try XCTUnwrap(recorded.1, "\(what) arrived with no URL")
        XCTAssertTrue(
            url.path.hasSuffix(expectedPathSuffix),
            "\(what) reported \(url.absoluteString), expected a URL ending in \(expectedPathSuffix)"
        )
    }

    // MARK: - Fixtures

    // One colour for every fixture format, so a decoded icon can be told apart
    // from a blank or a placeholder by its pixels rather than by its existence.
    private static let fixtureColour = (red: 17, green: 136, blue: 204)

    private static func htmlRoute(head: String) -> LiveHTTPTestServer.Route {
        LiveHTTPTestServer.Route(
            contentType: "text/html",
            body: "<!doctype html><html><head><meta charset=\"utf-8\"><title>favicon fixture</title>\(head)</head><body>orbit-favicon-test</body></html>"
        )
    }

    private static let solidPNG: Data = {
        let size = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32
        ) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(
            deviceRed: CGFloat(fixtureColour.red) / 255,
            green: CGFloat(fixtureColour.green) / 255,
            blue: CGFloat(fixtureColour.blue) / 255,
            alpha: 1
        ).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }()

    /// A single-entry ICO wrapping the PNG above (PNG-in-ICO), which is what
    /// Chromium's ICO decoder reads by signature.
    private static let solidICO: Data = {
        let png = solidPNG
        var data = Data()
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        appendUInt16(0)   // reserved
        appendUInt16(1)   // type: icon
        appendUInt16(1)   // one image
        data.append(32)   // width
        data.append(32)   // height
        data.append(0)    // palette size: none
        data.append(0)    // reserved
        appendUInt16(1)   // colour planes
        appendUInt16(32)  // bits per pixel
        appendUInt32(UInt32(png.count))
        appendUInt32(22)  // offset: 6-byte header + one 16-byte entry
        data.append(png)
        return data
    }()

    private static let solidSVG: Data = Data("""
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">\
    <rect width="32" height="32" fill="rgb(\(fixtureColour.red),\(fixtureColour.green),\(fixtureColour.blue))"/></svg>
    """.utf8)

    private static func assertIsFixtureColour(
        _ image: NSImage,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(image.size.width, 0, "\(context): decoded to a zero-sized image", file: file, line: line)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let colour = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                  .usingColorSpace(.deviceRGB)
        else {
            XCTFail("\(context): decoded image could not be read back as a bitmap", file: file, line: line)
            return
        }
        let red = Int((colour.redComponent * 255).rounded())
        let green = Int((colour.greenComponent * 255).rounded())
        let blue = Int((colour.blueComponent * 255).rounded())
        // Tolerance covers one colour-space hop (device space -> sRGB -> this
        // display's CGImage read, ~20 max drift), still far from a different colour.
        XCTAssertEqual(red, fixtureColour.red, accuracy: 30, "\(context): red channel", file: file, line: line)
        XCTAssertEqual(green, fixtureColour.green, accuracy: 30, "\(context): green channel", file: file, line: line)
        XCTAssertEqual(blue, fixtureColour.blue, accuracy: 30, "\(context): blue channel", file: file, line: line)
        // Ordering does not move across a colour-space hop, and it is what
        // separates the fixture icon from a white/black/grey stand-in.
        XCTAssertTrue(
            blue > green && green > red,
            "\(context): decoded pixel (\(red), \(green), \(blue)) is not the fixture's blue-dominant colour",
            file: file, line: line
        )
    }
}
