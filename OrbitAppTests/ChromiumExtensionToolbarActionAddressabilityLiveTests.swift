//  ExtensionToolbarActionVisualTests.swift proves this against hand-built
//  fixtures; this proves it against a REAL Chromium-assigned id. Both tests here used to assert the opposite.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionToolbarActionAddressabilityLiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func writeActionPopupExtension(named name: String, manifestKey: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-ToolbarAddressability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        var manifest: [String: Any] = [
            "manifest_version": 3,
            "name": name,
            "version": "1.0",
            "action": ["default_popup": "popup.html"],
        ]
        if let manifestKey { manifest["key"] = manifestKey }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        try "<html><body>popup</body></html>".write(
            to: directory.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8
        )
        return directory
    }

    // MARK: - A real "Load Unpacked" extension with no manifest key

    func testARealUnpackedExtensionWithNoManifestKeyGetsAToolbarActionEntryAndAnOpenablePopup() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let directory = try self.writeActionPopupExtension(named: "Orbit Unpacked No Key Test", manifestKey: nil)

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            XCTAssertTrue(loaded.hasToolbarAction, "precondition: the real engine must agree this extension declares a toolbar action")
            let manifest = try ChromeExtensionManifest.read(fromDirectory: loaded.directory)
            XCTAssertNil(manifest.key, "precondition: a real 'Load Unpacked' install with no key in manifest.json must stay keyless")

            // The engine reports the realpath-resolved directory it actually
            // hashed, so Orbit's own derivation over that path must reproduce it exactly.
            XCTAssertEqual(
                loaded.id, ChromeExtensionID.id(forUnpackedPath: loaded.directory),
                "Orbit's path-derived id must agree with the id the real engine assigned, or the addressability check is guessing"
            )

            let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
            let entry = try XCTUnwrap(
                entries.first { $0.id == loaded.id },
                "a real, running, unpacked extension declaring action.default_popup must get a toolbar entry -- this is Orbit's own supported 'Load Unpacked Extension' flow, which never writes a manifest \"key\""
            )
            XCTAssertEqual(entry.popupURL, URL(string: "chrome-extension://\(loaded.id)/popup.html"))

            // Proof the URL is not merely well-formed: the popup document
            // really loads from that origin in the running engine.
            let popup = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { popup.close() }
            popup.load(entry.popupURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(popup)
            let body = try await popup.evaluateJavaScript("document.body ? document.body.textContent : ''")
            XCTAssertEqual(
                (body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "popup",
                "the toolbar entry's chrome-extension:// popup URL must actually resolve in the running engine"
            )
        }
    }

    // MARK: - The control: the same shape of fixture, with a real key, is addressable

    func testTheSameKindOfExtensionWithARealManifestKeyDoesGetAToolbarActionEntry() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive {
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
            let directory = try self.writeActionPopupExtension(named: "Orbit Unpacked With Key Test", manifestKey: key)

            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let expectedID = try XCTUnwrap(ChromeExtensionID.id(fromPublicKeyBase64: key))
            XCTAssertEqual(
                loaded.id, expectedID,
                "the real engine's own id derivation from a manifest key must match Orbit's own ChromeExtensionID -- the isExtensionIDAddressable check gating the toolbar icon depends on this agreeing"
            )

            let entries = SiteControlPopoverView.extensionActionEntries(engine: engine, session: engine.defaultSession)
            XCTAssertTrue(
                entries.contains { $0.id == loaded.id },
                "a real extension whose manifest key recomputes to its own real engine-assigned id must get a toolbar action entry"
            )
        }
    }
}
