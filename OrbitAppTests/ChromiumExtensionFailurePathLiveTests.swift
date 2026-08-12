//  CRX3 failures are covered elsewhere; "Load Unpacked" has no CRX, so this
//  proves a malformed manifest fails cleanly: a thrown Swift error, never a crash or silent "it worked".

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionFailurePathLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func makeDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-ExtensionFailure-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(contentType: "text/html", body: "<html><body>orbit-extension-failure-path-test</body></html>"),
        ])
    }

    // The one assertion every failure-path test shares: whatever just
    // happened to loadExtension, the real browser process must still work afterward.
    private func assertEngineStillFunctions(_ engine: ChromiumEngine, server: LiveHTTPTestServer) async throws {
        let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
        defer { contents.close() }
        contents.load(server.baseURL)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)
        let body = try await contents.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertEqual(body, "orbit-extension-failure-path-test", "the engine could not complete an ordinary navigation right after a failed extension load")
    }

    // MARK: - Missing files: no manifest.json at all

    func testLoadingADirectoryWithNoManifestJSONFailsCleanlyAndTheEngineStaysAliveWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let server = try self.makeServer()
            defer { server.stop() }
            let directory = try self.makeDirectory(name: "NoManifest")
            try "not a manifest".write(to: directory.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

            let before = engine.loadedExtensions(session: engine.defaultSession).count
            do {
                _ = try await engine.loadExtension(at: directory, session: engine.defaultSession)
                XCTFail("loading a directory with no manifest.json must throw, not silently succeed")
            } catch let error as EngineError {
                XCTAssertFalse(error.underlyingDescription.isEmpty, "the thrown EngineError must carry a real, non-empty reason")
            }
            XCTAssertEqual(engine.loadedExtensions(session: engine.defaultSession).count, before, "a failed load must not add a phantom entry to the running registry")

            try await self.assertEngineStillFunctions(engine, server: server)
        }
    }

    // MARK: - Malformed manifest.json: not even valid JSON

    func testLoadingADirectoryWithMalformedManifestJSONFailsCleanlyAndTheEngineStaysAliveWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let server = try self.makeServer()
            defer { server.stop() }
            let directory = try self.makeDirectory(name: "MalformedManifest")
            try "{ this is not valid JSON, at all ]]] --".write(
                to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
            )

            let before = engine.loadedExtensions(session: engine.defaultSession).count
            do {
                _ = try await engine.loadExtension(at: directory, session: engine.defaultSession)
                XCTFail("loading a directory whose manifest.json is not valid JSON must throw, not silently succeed")
            } catch let error as EngineError {
                XCTAssertFalse(error.underlyingDescription.isEmpty)
            }
            XCTAssertEqual(engine.loadedExtensions(session: engine.defaultSession).count, before)

            try await self.assertEngineStillFunctions(engine, server: server)
        }
    }

    // MARK: - Manifest missing a field Chromium itself requires

    func testLoadingAManifestMissingRequiredVersionFieldFailsCleanlyAndTheEngineStaysAliveWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let server = try self.makeServer()
            defer { server.stop() }
            let directory = try self.makeDirectory(name: "MissingVersion")
            // Valid JSON, and would satisfy Orbit's own ChromeExtensionManifest.read
            // in spirit, but has no "version" -- a field Chromium's own
            // extensions::Extension::InitFromValue refuses to proceed without.
            try """
            { "manifest_version": 3, "name": "Orbit Missing Version Test" }
            """.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

            let before = engine.loadedExtensions(session: engine.defaultSession).count
            do {
                _ = try await engine.loadExtension(at: directory, session: engine.defaultSession)
                XCTFail("loading a manifest with no \"version\" must throw, not silently succeed")
            } catch let error as EngineError {
                XCTAssertFalse(error.underlyingDescription.isEmpty)
            }
            XCTAssertEqual(engine.loadedExtensions(session: engine.defaultSession).count, before)

            try await self.assertEngineStillFunctions(engine, server: server)
        }
    }

    // MARK: - Manifest references a file that does not exist on disk

    func testLoadingAManifestThatReferencesAMissingContentScriptFileNeverCrashesTheEngineAndLeavesItUsableWithoutRestart() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let server = try self.makeServer()
            defer { server.stop() }
            let directory = try self.makeDirectory(name: "MissingContentScript")
            try """
            {
              "manifest_version": 3,
              "name": "Orbit Missing Content Script Test",
              "version": "1.0",
              "content_scripts": [
                { "matches": ["http://127.0.0.1/*"], "js": ["does-not-exist.js"] }
              ]
            }
            """.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

            // Not asserting which way Chromium behaves here (it has changed
            // across versions); either way: no crash, no phantom double-registration.
            var threw = false
            do {
                let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
                engine.unloadExtension(id: loaded.id, session: engine.defaultSession)
            } catch is EngineError {
                threw = true
            }

            if threw {
                XCTAssertTrue(engine.loadedExtensions(session: engine.defaultSession).filter { $0.name == "Orbit Missing Content Script Test" }.isEmpty)
            }

            try await self.assertEngineStillFunctions(engine, server: server)
        }
    }
}
