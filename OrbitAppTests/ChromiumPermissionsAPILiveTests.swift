//  Runs in the extension's own page, not a content-script relay: permissions.request
//  is privileged-context and needs the user gesture only evaluateJavaScript(_:userGesture:) supplies.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumPermissionsAPILiveTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        WebStoreInstallVerifyProbe.autoAnswerExtensionPermissionsConsent = nil
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    // "storage" is required, "idle"/"power" optional, "alarms" is declared
    // nowhere -- the negative control every grant path is checked against.
    private func writeFixture(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-Permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        try writeFixtureContents(named: name, into: directory)
        return directory
    }

    private func writeFixtureContents(named name: String, into directory: URL) throws {
        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": ["storage"],
          "optional_permissions": ["idle", "power"],
          "host_permissions": ["http://127.0.0.1/*"],
          "optional_host_permissions": ["https://optional.example/*"],
          "background": { "service_worker": "background.js" }
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        try "self.addEventListener('install', function () {});\n"
            .write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let probeHTML = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Orbit Permissions Probe</title></head>
        <body><div id="orbit-permissions-probe">ready</div><script src="probe.js"></script></body></html>
        """
        try probeHTML.write(to: directory.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)

        let probeJS = """
        window.__orbitAdded = [];
        window.__orbitRemoved = [];
        window.__orbitOut = null;
        if (chrome.permissions && chrome.permissions.onAdded) {
          chrome.permissions.onAdded.addListener(function (permissions) {
            window.__orbitAdded.push(permissions);
          });
        }
        if (chrome.permissions && chrome.permissions.onRemoved) {
          chrome.permissions.onRemoved.addListener(function (permissions) {
            window.__orbitRemoved.push(permissions);
          });
        }
        """
        try probeJS.write(to: directory.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)
    }

    // MARK: - Harness

    /// Only AppEnvironment.startEngineIfNeeded installs the consent delegate;
    /// without this every request fails. Must follow sharedEngine(), which dlsym's the symbols it installs through.
    private func engineWithConsentInstalled() async -> ChromiumEngine {
        let engine = await LiveChromiumEngineHost.sharedEngine()
        ChromiumTabsSetup.installHandlerOnce
        return engine
    }

    private static func pollUntil(
        _ waitingFor: String,
        timeout: Duration = .seconds(20),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(
                    code: .engineUnavailable,
                    underlyingDescription: "timed out after \(timeout) waiting for \(waitingFor)"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func openProbePage(
        engine: ChromiumEngine, extensionID: String
    ) async throws -> ChromiumWebContents {
        let page = try await LiveChromiumEngineHost.makeContents(engine: engine)
        page.load(URL(string: "chrome-extension://\(extensionID)/probe.html")!)
        try await LiveChromiumEngineHost.waitUntilStoppedLoading(page)
        try await Self.pollUntil("the extension probe page to install its listeners") {
            try await page.evaluateJavaScript("Array.isArray(window.__orbitAdded)") as? Bool == true
        }
        return page
    }

    private struct APIOutcome {
        let ok: Bool
        let value: Any?
        let error: String
    }

    /// `invocation` must be a JS expression evaluating to a promise, invoked
    /// synchronously so a user gesture is still live when permissions.request reads it.
    private func callAPI(
        _ page: ChromiumWebContents, _ invocation: String, userGesture: Bool = false
    ) async throws -> APIOutcome {
        let script = """
        (function () {
          window.__orbitOut = null;
          try {
            Promise.resolve(\(invocation)).then(
              function (value) {
                window.__orbitOut = JSON.stringify({ ok: true, value: value === undefined ? null : value });
              },
              function (error) {
                window.__orbitOut = JSON.stringify({ ok: false, error: String((error && error.message) || error) });
              }
            );
          } catch (error) {
            window.__orbitOut = JSON.stringify({ ok: false, error: String((error && error.message) || error) });
          }
          return 'started';
        })()
        """
        if userGesture {
            _ = try await page.evaluateJavaScript(script, userGesture: true)
        } else {
            _ = try await page.evaluateJavaScript(script)
        }
        try await Self.pollUntil("chrome.permissions to answer") {
            try await page.evaluateJavaScript("window.__orbitOut !== null") as? Bool == true
        }
        let rawValue = try await page.evaluateJavaScript("window.__orbitOut")
        let raw = try XCTUnwrap(
            rawValue as? String,
            "chrome.permissions never answered"
        )
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            "chrome.permissions answered with something that is not an object: \(raw)"
        )
        return APIOutcome(
            ok: parsed["ok"] as? Bool ?? false,
            value: parsed["value"],
            error: parsed["error"] as? String ?? ""
        )
    }

    private func getAll(_ page: ChromiumWebContents) async throws -> (permissions: [String], origins: [String]) {
        let outcome = try await callAPI(page, "chrome.permissions.getAll()")
        XCTAssertTrue(outcome.ok, "getAll failed: \(outcome.error)")
        let dict = try XCTUnwrap(outcome.value as? [String: Any], "getAll must resolve to a Permissions object")
        return (dict["permissions"] as? [String] ?? [], dict["origins"] as? [String] ?? [])
    }

    private func contains(_ page: ChromiumWebContents, _ argument: String) async throws -> APIOutcome {
        try await callAPI(page, "chrome.permissions.contains(\(argument))")
    }

    private func request(
        _ page: ChromiumWebContents, _ argument: String, answer: Bool?
    ) async throws -> APIOutcome {
        WebStoreInstallVerifyProbe.autoAnswerExtensionPermissionsConsent = answer
        defer { WebStoreInstallVerifyProbe.autoAnswerExtensionPermissionsConsent = nil }
        return try await callAPI(page, "chrome.permissions.request(\(argument))", userGesture: true)
    }

    private func eventPayloads(_ page: ChromiumWebContents, _ variable: String) async throws -> [[String: Any]] {
        let raw = try await page.evaluateJavaScript("JSON.stringify(window.\(variable))") as? String ?? "[]"
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        return parsed ?? []
    }

    // MARK: - Tests

    func testGetAllReportsTheManifestsRequiredPermissionsAndNotItsUngrantedOptionalOnes() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) {
            let engine = await self.engineWithConsentInstalled()
            let directory = try self.writeFixture(named: "Orbit Permissions GetAll Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            let page = try await self.openProbePage(engine: engine, extensionID: loaded.id)
            defer { page.close() }

            let all = try await self.getAll(page)
            XCTAssertTrue(all.permissions.contains("storage"), "getAll must report the required permission: \(all.permissions)")
            XCTAssertFalse(all.permissions.contains("idle"), "an ungranted optional permission must not be reported as active")
            XCTAssertFalse(all.permissions.contains("power"), "an ungranted optional permission must not be reported as active")
            XCTAssertFalse(all.permissions.contains("alarms"), "a permission absent from the manifest must never be reported")
            XCTAssertTrue(
                all.origins.contains { $0.contains("127.0.0.1") },
                "getAll must report the required host permission: \(all.origins)"
            )
            XCTAssertFalse(
                all.origins.contains { $0.contains("optional.example") },
                "an ungranted optional host permission must not be reported as active: \(all.origins)"
            )
        }
    }

    func testContainsIsTrueForAGrantedPermissionAndFalseForAnUngrantedOne() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) {
            let engine = await self.engineWithConsentInstalled()
            let directory = try self.writeFixture(named: "Orbit Permissions Contains Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            let page = try await self.openProbePage(engine: engine, extensionID: loaded.id)
            defer { page.close() }

            let granted = try await self.contains(page, "{ permissions: ['storage'] }")
            XCTAssertTrue(granted.ok, "contains failed: \(granted.error)")
            XCTAssertEqual(granted.value as? Bool, true, "contains must be true for a required, granted permission")

            let ungranted = try await self.contains(page, "{ permissions: ['idle'] }")
            XCTAssertTrue(ungranted.ok, "contains failed: \(ungranted.error)")
            XCTAssertEqual(ungranted.value as? Bool, false, "contains must be false for an ungranted optional permission")

            let host = try await self.contains(page, "{ origins: ['https://optional.example/*'] }")
            XCTAssertTrue(host.ok, "contains failed: \(host.error)")
            XCTAssertEqual(host.value as? Bool, false, "contains must be false for an ungranted optional host permission")
        }
    }

    func testRequestGrantsTheOptionalPermissionWhenTheUserApprovesAndFiresOnAdded() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) {
            let engine = await self.engineWithConsentInstalled()
            let directory = try self.writeFixture(named: "Orbit Permissions Request Approve Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            let page = try await self.openProbePage(engine: engine, extensionID: loaded.id)
            defer { page.close() }

            let outcome = try await self.request(page, "{ permissions: ['idle'] }", answer: true)
            XCTAssertTrue(outcome.ok, "request failed: \(outcome.error)")
            XCTAssertEqual(outcome.value as? Bool, true, "request must resolve true when the user approves")

            let after = try await self.contains(page, "{ permissions: ['idle'] }")
            XCTAssertEqual(after.value as? Bool, true, "an approved optional permission must become contained")

            let all = try await self.getAll(page)
            XCTAssertTrue(all.permissions.contains("idle"), "an approved optional permission must appear in getAll: \(all.permissions)")

            try await Self.pollUntil("permissions.onAdded to fire") {
                try await self.eventPayloads(page, "__orbitAdded").isEmpty == false
            }
            let added = try await self.eventPayloads(page, "__orbitAdded")
            XCTAssertTrue(
                added.contains { ($0["permissions"] as? [String])?.contains("idle") == true },
                "onAdded must carry the permission that was granted: \(added)"
            )
            let evtRemovedCount = try await self.eventPayloads(page, "__orbitRemoved").count
            XCTAssertEqual(evtRemovedCount, 0, "onRemoved must not fire for a grant")
        }
    }

    func testRequestGrantsNothingWhenTheUserRefuses() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) {
            let engine = await self.engineWithConsentInstalled()
            let directory = try self.writeFixture(named: "Orbit Permissions Request Refuse Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            let page = try await self.openProbePage(engine: engine, extensionID: loaded.id)
            defer { page.close() }

            let outcome = try await self.request(page, "{ permissions: ['idle'] }", answer: false)
            XCTAssertTrue(outcome.ok, "request failed: \(outcome.error)")
            XCTAssertEqual(outcome.value as? Bool, false, "request must resolve false when the user refuses")

            let after = try await self.contains(page, "{ permissions: ['idle'] }")
            XCTAssertEqual(after.value as? Bool, false, "a refused permission must not be granted")

            let all = try await self.getAll(page)
            XCTAssertFalse(all.permissions.contains("idle"), "a refused permission must not appear in getAll: \(all.permissions)")
            let evtAddedCount = try await self.eventPayloads(page, "__orbitAdded").count
            XCTAssertEqual(evtAddedCount, 0, "onAdded must not fire for a refusal")
        }
    }

    func testRemoveRevokesAGrantedOptionalPermissionAndFiresOnRemoved() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) {
            let engine = await self.engineWithConsentInstalled()
            let directory = try self.writeFixture(named: "Orbit Permissions Remove Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            let page = try await self.openProbePage(engine: engine, extensionID: loaded.id)
            defer { page.close() }

            let granted = try await self.request(page, "{ permissions: ['idle'] }", answer: true)
            XCTAssertEqual(granted.value as? Bool, true, "setup: the grant must succeed, got \(granted.error)")

            let removed = try await self.callAPI(page, "chrome.permissions.remove({ permissions: ['idle'] })")
            XCTAssertTrue(removed.ok, "remove failed: \(removed.error)")
            XCTAssertEqual(removed.value as? Bool, true, "remove must resolve true")

            let after = try await self.contains(page, "{ permissions: ['idle'] }")
            XCTAssertEqual(after.value as? Bool, false, "a removed permission must no longer be contained")

            try await Self.pollUntil("permissions.onRemoved to fire") {
                try await self.eventPayloads(page, "__orbitRemoved").isEmpty == false
            }
            let events = try await self.eventPayloads(page, "__orbitRemoved")
            XCTAssertTrue(
                events.contains { ($0["permissions"] as? [String])?.contains("idle") == true },
                "onRemoved must carry the permission that was revoked: \(events)"
            )

            let required = try await self.callAPI(page, "chrome.permissions.remove({ permissions: ['storage'] })")
            XCTAssertFalse(required.ok, "remove must reject a required permission, but it resolved")
            XCTAssertTrue(
                required.error.contains("required"),
                "removing a required permission must say so: \(required.error)"
            )
        }
    }

    func testAGrantedOptionalPermissionSurvivesTheExtensionBeingReloaded() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) {
            let engine = await self.engineWithConsentInstalled()
            let directory = try self.writeFixture(named: "Orbit Permissions Persistence Test")

            let firstLoad = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            let firstPage = try await self.openProbePage(engine: engine, extensionID: firstLoad.id)
            let granted = try await self.request(firstPage, "{ permissions: ['idle'] }", answer: true)
            XCTAssertEqual(granted.value as? Bool, true, "setup: the grant must succeed, got \(granted.error)")
            firstPage.close()

            // Same on-disk directory, so the same path-derived id and the same
            // extension-prefs record -- what a relaunch would find.
            engine.unloadExtension(id: firstLoad.id, session: engine.defaultSession)
            let secondLoad = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: secondLoad.id, session: engine.defaultSession) }
            XCTAssertEqual(secondLoad.id, firstLoad.id, "the same unpacked directory must derive the same extension id")

            let secondPage = try await self.openProbePage(engine: engine, extensionID: secondLoad.id)
            defer { secondPage.close() }

            let after = try await self.contains(secondPage, "{ permissions: ['idle'] }")
            XCTAssertTrue(after.ok, "contains failed after reload: \(after.error)")
            XCTAssertEqual(after.value as? Bool, true, "a granted optional permission must survive a reload")

            let all = try await self.getAll(secondPage)
            XCTAssertTrue(
                all.permissions.contains("idle"),
                "a granted optional permission must still be in getAll after a reload: \(all.permissions)"
            )
        }
    }

    func testAPermissionAbsentFromOptionalPermissionsCanNeverBeGranted() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        try LiveChromiumEngineHost.runLive(timeout: 120) {
            let engine = await self.engineWithConsentInstalled()
            let directory = try self.writeFixture(named: "Orbit Permissions Negative Control Test")
            let loaded = try await engine.loadExtension(at: directory, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }
            let page = try await self.openProbePage(engine: engine, extensionID: loaded.id)
            defer { page.close() }

            // Auto-APPROVE throughout: if consent alone stood between the
            // extension and an undeclared permission, this would grant it.
            let api = try await self.request(page, "{ permissions: ['alarms'] }", answer: true)
            XCTAssertFalse(api.ok, "requesting a permission absent from the manifest must reject, but it resolved to \(String(describing: api.value))")
            XCTAssertTrue(
                api.error.contains("manifest"),
                "the rejection must name the manifest as the reason: \(api.error)"
            )

            let host = try await self.request(page, "{ origins: ['https://not-declared.example/*'] }", answer: true)
            XCTAssertFalse(host.ok, "requesting an undeclared host must reject, but it resolved to \(String(describing: host.value))")

            let wider = try await self.request(page, "{ origins: ['https://*/*'] }", answer: true)
            XCTAssertFalse(wider.ok, "requesting a host pattern wider than the declared optional one must reject")

            let unknown = try await self.request(page, "{ permissions: ['thisIsNotARealPermission'] }", answer: true)
            XCTAssertFalse(unknown.ok, "requesting an unrecognised permission must reject")

            let all = try await self.getAll(page)
            for name in ["alarms", "thisIsNotARealPermission"] {
                XCTAssertFalse(all.permissions.contains(name), "\(name) must never end up granted: \(all.permissions)")
            }
            for origin in all.origins {
                XCTAssertFalse(origin.contains("not-declared.example"), "an undeclared host must never end up granted: \(all.origins)")
            }
            let evtAddedCount = try await self.eventPayloads(page, "__orbitAdded").count
            XCTAssertEqual(evtAddedCount, 0, "no refused request may fire onAdded")
        }
    }
}
