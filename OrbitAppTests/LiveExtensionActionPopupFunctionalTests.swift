//  Other popup-sizing suites drive MockWebContents.reportPreferredSize, never a real
//  chrome-extension:// URL through ExtensionActionPopupModel; this file uses a real one.

import AppKit
import Foundation
import WebKit
import XCTest
@testable import Orbit

@MainActor
final class LiveExtensionActionPopupFunctionalTests: LiveEnvironmentTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // popupScript is written as its own popup.js: MV3's extension_pages CSP is
    // script-src 'self', so an inline <script> is blocked outright.
    private func writeExtension(popupBody: String, popupScript: String? = nil, permissions: [String] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-LivePopupFunctional-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let permissionsJSON = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
        {
          "manifest_version": 3,
          "name": "Orbit Live Popup Functional Test",
          "version": "1.0",
          "permissions": [\(permissionsJSON)],
          "action": { "default_popup": "popup.html" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try popupBody.write(to: directory.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        if let popupScript {
            try popupScript.write(to: directory.appendingPathComponent("popup.js"), atomically: true, encoding: .utf8)
        }
        return directory
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

    // MARK: - A real popup renders at exactly its declared size, end-to-end through the real model

    func testARealExtensionPopupOfAKnownDeclaredSizeReportsExactlyThatSizeThroughTheRealModel() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let popupHTML = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            html, body { margin: 0; padding: 0; }
            #box { width: 214px; height: 132px; background: #336699; }
            </style></head><body><div id="box"></div></body></html>
            """
            let directory = try self.writeExtension(popupBody: popupHTML)
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let popupURL = URL(string: "chrome-extension://\(loaded.id)/popup.html")!
            let model = ExtensionActionPopupModel(engine: engine, session: engine.defaultSession, url: popupURL)
            model.start()
            defer { model.teardown() }

            let contents = try XCTUnwrap(model.contents, "the real engine failed to create the popup's own WebContents")
            // Left at the loading size. A frame larger than the document makes the
            // viewport-height check throw the real report away.
            contents.setVisible(true)

            try await Self.pollUntil { model.hasReportedContentSize }

            XCTAssertEqual(model.contentSize.width, 214, accuracy: 4, "the real popup's own document size did not reach ExtensionActionPopupModel.contentSize")
            XCTAssertEqual(model.contentSize.height, 132, accuracy: 4)
        }
    }

    // The suites above enlarge the web view to 900×700 before waiting. The app does not:
    // start() leaves the popup at the 25×25 loading box, which is the size the user sees
    // when detection never replaces it.
    func testARealPopupLeftAtTheLoadingSizeGrowsToTheDocument() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let popupHTML = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            html, body { margin: 0; padding: 0; overflow: hidden; }
            body { min-width: 24rem; }
            #box { width: 360px; height: 220px; background: #5b4dff; }
            </style></head><body><div id="box"></div></body></html>
            """
            let directory = try self.writeExtension(popupBody: popupHTML)
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let popupURL = URL(string: "chrome-extension://\(loaded.id)/popup.html")!
            let model = ExtensionActionPopupModel(engine: engine, session: engine.defaultSession, url: popupURL)
            model.start()
            defer { model.teardown() }

            let contents = try XCTUnwrap(model.contents)
            let host = NSView(frame: NSRect(origin: .zero, size: ExtensionActionPopupSupport.popupLoadingSize))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: ExtensionActionPopupSupport.popupLoadingSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            let view = contents.view
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            window.orderFront(nil)
            contents.setVisible(true)
            defer { window.close() }

            let deadline = ContinuousClock.now + .seconds(8)
            while model.contentSize.width < 300, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let measured = try? await ExtensionActionPopupSupport.measuredContentSize(in: contents)
            let probe = try? await contents.evaluateJavaScript(
                "String(!!window.__orbitContentSizing)+' scroll='+document.body.scrollWidth+'x'+document.body.scrollHeight"
            )
            let scriptCount = (contents.view as? WKWebView)?.configuration.userContentController.userScripts.count ?? -1
            XCTAssertEqual(
                model.contentSize.width, 384, accuracy: 8,
                "popup stayed \(model.contentSize) reported=\(model.hasReportedContentSize), script measured \(String(describing: measured)), view \(contents.view.bounds.size), probe \(String(describing: probe)), userScripts \(scriptCount)"
            )
            XCTAssertEqual(model.contentSize.height, 220, accuracy: 8, "height stayed \(model.contentSize.height)")
            XCTAssertFalse(model.scrollsHorizontally, "a page that fits its own width must not scroll sideways")
        }
    }

    // MARK: - The same real popup, oversized: clamps to Chrome's own maximum through the real model

    func testARealExtensionPopupLargerThanChromesMaximumClampsThroughTheRealModel() throws {
        try WebKitLiveEngineHost.runLive {
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let popupHTML = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            html, body { margin: 0; padding: 0; }
            #box { width: 2400px; height: 2400px; background: #336699; }
            </style></head><body><div id="box"></div></body></html>
            """
            let directory = try self.writeExtension(popupBody: popupHTML)
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let popupURL = URL(string: "chrome-extension://\(loaded.id)/popup.html")!
            let model = ExtensionActionPopupModel(engine: engine, session: engine.defaultSession, url: popupURL)
            model.start()
            defer { model.teardown() }

            let contents = try XCTUnwrap(model.contents)
            contents.setVisible(true)

            try await Self.pollUntil { model.hasReportedContentSize }

            XCTAssertEqual(model.contentSize, ExtensionActionPopupSupport.popupMaximumSize, "a real, wildly oversized popup document must clamp to Chrome's own maximum popup size, through the real renderer")
        }
    }

    // MARK: - A real popup runs real extension JS: chrome.storage and chrome.tabs, not just static HTML

    func testARealExtensionPopupExecutesRealChromeAPICallsAndWritesTheResultsIntoItsOwnDOM() throws {
        let (storageResult, tabCount) = try WebKitLiveEngineHost.runLive { () -> (String?, Int?) in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let env = self.env
            env._test_engineOverride = engine
            let spaceID = try XCTUnwrap(env.activeSpace?.id)

            let popupHTML = """
            <!doctype html><html><body>
            <div id="status">loading</div>
            <script src="popup.js"></script>
            </body></html>
            """
            let popupScript = """
            chrome.storage.local.set({ orbitPopupTest: 'orbit-popup-wrote-this' }, function() {
              chrome.storage.local.get(['orbitPopupTest'], function(result) {
                chrome.tabs.query({}, function(tabs) {
                  document.getElementById('status').setAttribute(
                    'data-orbit-popup-result',
                    JSON.stringify({ storage: result.orbitPopupTest, tabCount: tabs.length })
                  );
                });
              });
            });
            """
            let directory = try self.writeExtension(
                popupBody: popupHTML, popupScript: popupScript, permissions: ["storage", "tabs"]
            )
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let server = try LiveHTTPTestServer(routes: [
                "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-popup-functional-test-tab</body></html>"),
            ])
            defer { server.stop() }
            let tabID = env.openTab(url: server.baseURL, in: spaceID)
            defer { env.closeTab(tabID) }
            let tabContents = try XCTUnwrap(env.webContents[tabID] as? WebKitWebContents)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(tabContents)

            let popupURL = URL(string: "chrome-extension://\(loaded.id)/popup.html")!
            let model = ExtensionActionPopupModel(engine: engine, session: engine.defaultSession, url: popupURL)
            model.start()
            defer { model.teardown() }

            guard let chromiumContents = model.contents as? WebKitWebContents else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "the popup's WebContents was not a WebKitWebContents")
            }

            let probe = "var node = document.getElementById('status'); node ? node.getAttribute('data-orbit-popup-result') : null"
            var captured: String?
            try await Self.pollUntil {
                let raw = try await chromiumContents.evaluateJavaScript(probe) as? String
                guard let raw, !raw.isEmpty else { return false }
                captured = raw
                return true
            }
            let raw = captured
            let tabCount: Int? = raw.flatMap { data -> Int? in
                guard let jsonData = data.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                else { return nil }
                return dict["tabCount"] as? Int
            }
            return (raw, tabCount)
        }

        let raw = try XCTUnwrap(
            storageResult,
            "the popup's own JS never wrote its result -- chrome.storage/chrome.tabs likely never resolved inside a real extension popup context"
        )
        XCTAssertTrue(raw.contains("orbit-popup-wrote-this"), "chrome.storage.local.set/get did not round-trip inside the real popup: \(raw)")
        XCTAssertEqual(tabCount, 1, "chrome.tabs.query from inside a real popup did not see the one real tab that was actually open")
    }
}
