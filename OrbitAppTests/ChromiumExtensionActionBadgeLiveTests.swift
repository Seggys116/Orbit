//  chrome.action end to end: asserts setBadgeText/setIcon/etc. reach
//  extensionActionStates and the drawn toolbar entry, not that a function merely ran.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionActionBadgeLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private static let commandAttribute = "data-orbit-action-command"
    private static let acknowledgementAttribute = "data-orbit-action-ack"

    private func writeFixture(named name: String, matchHost: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-ActionBadge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "action": { "default_popup": "popup.html", "default_icon": "static.png", "default_title": "Static Title" },
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://\(matchHost)/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // Every branch answers sendResponse only after the chrome.action call
        // resolves, so the acknowledgement means the API really completed.
        let background = """
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
          var done = function() { sendResponse('ok'); };
          var fail = function(error) { sendResponse('error: ' + String(error)); };
          try {
            switch (message) {
              case 'badge':
                chrome.action.setBadgeText({ text: '42' }).then(done, fail);
                break;
              case 'clear-badge':
                chrome.action.setBadgeText({ text: '' }).then(done, fail);
                break;
              case 'colour':
                chrome.action.setBadgeBackgroundColor({ color: [0, 128, 255, 255] }).then(done, fail);
                break;
              case 'disable':
                chrome.action.disable().then(done, fail);
                break;
              case 'enable':
                chrome.action.enable().then(done, fail);
                break;
              case 'icon':
                chrome.action.setIcon({ path: 'dynamic.png' }).then(done, fail);
                break;
              case 'title':
                chrome.action.setTitle({ title: 'Dynamic Title' }).then(done, fail);
                break;
              case 'popup':
                chrome.action.setPopup({ popup: 'other.html' }).then(done, fail);
                break;
              case 'read-badge':
                chrome.action.getBadgeText({}).then(function(text) { sendResponse('badge:' + text); }, fail);
                break;
              default:
                fail('unknown command ' + message);
            }
          } catch (error) {
            fail(error);
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        var last = null;
        setInterval(function() {
          var command = document.documentElement.getAttribute('\(Self.commandAttribute)');
          if (!command || command === last) { return; }
          last = command;
          chrome.runtime.sendMessage(command, function(response) {
            document.documentElement.setAttribute('\(Self.acknowledgementAttribute)', command + '|' + String(response));
          });
        }, 25);
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        try "<html><body>popup</body></html>".write(
            to: directory.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8
        )
        try "<html><body>other</body></html>".write(
            to: directory.appendingPathComponent("other.html"), atomically: true, encoding: .utf8
        )
        try Self.writePNG(red: 0, green: 0, blue: 255, to: directory.appendingPathComponent("static.png"))
        try Self.writePNG(red: 0, green: 255, blue: 0, to: directory.appendingPathComponent("dynamic.png"))
        return directory
    }

    private static func writePNG(red: UInt8, green: UInt8, blue: UInt8, to url: URL, size: Int = 32) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw EngineError(code: .unknown, underlyingDescription: "PNG encoding failed")
        }
        try data.write(to: url)
    }

    private static func pollUntil(timeout: Duration = .seconds(15), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "pollUntil timed out after \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Sends one command to the background worker and waits for its own
    /// acknowledgement, returning whatever it answered.
    @discardableResult
    private static func run(command: String, in contents: ChromiumWebContents) async throws -> String {
        _ = try await contents.evaluateJavaScript(
            "document.documentElement.removeAttribute('\(acknowledgementAttribute)');"
            + "document.documentElement.setAttribute('\(commandAttribute)', '\(command)');"
        )
        var answer = ""
        try await pollUntil {
            let raw = try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(acknowledgementAttribute)')"
            )
            guard let value = raw as? String, value.hasPrefix(command + "|") else { return false }
            answer = String(value.dropFirst(command.count + 1))
            return true
        }
        XCTAssertFalse(answer.hasPrefix("error:"), "chrome.action.\(command) failed in the real service worker: \(answer)")
        return answer
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-action-badge-test</body></html>"),
        ])
    }

    // MARK: - Badge text, colour, icon, title, popup

    func testChromeActionSetBadgeTextReachesTheToolbarEntryOrbitDraws() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeFixture(named: "Orbit Action Badge Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            XCTAssertEqual(
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeText, "",
                "precondition: an extension that has not badged itself must report no badge"
            )

            try await Self.run(command: "badge", in: contents)
            try await Self.pollUntil {
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeText == "42"
            }

            let entry = try XCTUnwrap(
                SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
                    .first { $0.id == loaded.id },
                "the badged extension must still get a toolbar entry"
            )
            XCTAssertEqual(entry.badgeText, "42", "the badge the extension set must be the text the toolbar draws")

            // The engine's own getter agrees, so the value really landed in
            // extensions::ExtensionAction and is not a Swift-side echo.
            let readBack = try await Self.run(command: "read-badge", in: contents)
            XCTAssertEqual(readBack, "badge:42")

            try await Self.run(command: "clear-badge", in: contents)
            try await Self.pollUntil {
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeText.isEmpty
            }
        }
    }

    func testChromeActionSetBadgeBackgroundColorReachesSwiftAsTheExactColour() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeFixture(named: "Orbit Action Colour Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            XCTAssertTrue(
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeBackgroundColor.isUnset,
                "precondition: an extension that never set a badge colour must report the unset colour"
            )

            try await Self.run(command: "colour", in: contents)
            try await Self.pollUntil {
                !engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeBackgroundColor.isUnset
            }
            XCTAssertEqual(
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeBackgroundColor,
                ExtensionActionColor(red: 0, green: 128, blue: 255, alpha: 255)
            )
        }
    }

    func testChromeActionSetIconReplacesTheManifestIconWithRealDecodedBitmapBytes() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeFixture(named: "Orbit Action Icon Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            XCTAssertNil(
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).iconPNG,
                "precondition: only an explicit setIcon produces bytes here -- the manifest icon is read off disk by Swift"
            )

            try await Self.run(command: "icon", in: contents)
            try await Self.pollUntil {
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).iconPNG != nil
            }

            let data = try XCTUnwrap(engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).iconPNG)
            let image = try XCTUnwrap(NSImage(data: data), "the relayed bytes must decode as a real image")
            XCTAssertGreaterThan(image.size.width, 0)

            // dynamic.png is solid green, static.png solid blue: colour proves
            // ImageLoader read the file the extension named, not the manifest's default_icon.
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let centre = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            XCTAssertGreaterThan(centre.greenComponent, 0.5, "setIcon('dynamic.png') must relay the green bitmap")
            XCTAssertLessThan(centre.blueComponent, 0.5, "the blue manifest default_icon must not be what was relayed")
        }
    }

    func testChromeActionSetTitleAndSetPopupReachTheToolbarEntry() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeFixture(named: "Orbit Action Title Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.run(command: "title", in: contents)
            try await Self.pollUntil {
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).title == "Dynamic Title"
            }

            try await Self.run(command: "popup", in: contents)
            try await Self.pollUntil {
                SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
                    .first { $0.id == loaded.id }?.popupURL
                    == URL(string: "chrome-extension://\(loaded.id)/other.html")
            }

            let entry = try XCTUnwrap(
                SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
                    .first { $0.id == loaded.id }
            )
            XCTAssertEqual(entry.accessibleTitle, "Dynamic Title", "chrome.action.setTitle must override the manifest's default_title")
        }
    }

    // MARK: - enable / disable

    func testChromeActionDisableAndEnableFlipTheToolbarEntrysEnabledState() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeFixture(named: "Orbit Action Enable Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            let entryIsEnabled: () -> Bool? = {
                SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
                    .first { $0.id == loaded.id }?.actionState.isEnabled
            }
            XCTAssertEqual(entryIsEnabled(), true, "precondition: an MV3 action defaults to enabled")

            try await Self.run(command: "disable", in: contents)
            try await Self.pollUntil { entryIsEnabled() == false }

            try await Self.run(command: "enable", in: contents)
            try await Self.pollUntil { entryIsEnabled() == true }
        }
    }

    // MARK: - Unload

    func testUnloadingTheExtensionClearsItsRelayedActionState() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeFixture(named: "Orbit Action Unload Test", matchHost: "127.0.0.1")
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.run(command: "badge", in: contents)
            try await Self.pollUntil {
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeText == "42"
            }

            engine.unloadExtension(id: loaded.id, session: engine.defaultSession)
            try await Self.pollUntil {
                engine.extensionActionStates.state(extensionID: loaded.id, tabID: nil).badgeText.isEmpty
            }
        }
    }
}
