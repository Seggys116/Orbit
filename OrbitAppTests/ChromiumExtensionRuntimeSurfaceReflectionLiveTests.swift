//  Schema conformance proves the JSON matches, not that the binding was
//  generated -- how chrome.scripting stayed compiled-in and undefined. Walks the real `chrome` object inside a real MV3 worker.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ChromiumExtensionRuntimeSurfaceReflectionLiveTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - The report

    /// One namespace as the extension process sees it. `functions`, `events`
    /// and `properties` are the member names; `children` are the nested
    /// namespace-shaped objects (chrome.storage.sync, chrome.devtools.panels).
    private struct ReflectedNamespace: Decodable {
        var functions: [String]
        var events: [String]
        var properties: [String]
        var children: [String]
    }

    private typealias Report = [String: ReflectedNamespace]

    private static let reflectionScript = """
    function orbitReflect(value, depth) {
      var functions = [], events = [], properties = [], children = [];
      var keys;
      try { keys = Object.keys(value); } catch (e) { keys = []; }
      for (var i = 0; i < keys.length; i++) {
        var name = keys[i], member;
        try { member = value[name]; } catch (e) { continue; }
        if (typeof member === 'function') { functions.push(name); continue; }
        if (member !== null && typeof member === 'object') {
          if (typeof member.addListener === 'function'
              && typeof member.removeListener === 'function'
              && typeof member.hasListener === 'function') {
            events.push(name);
          } else if (depth > 0) {
            children.push(name);
          } else {
            properties.push(name);
          }
          continue;
        }
        properties.push(name);
      }
      return {
        functions: functions.sort(), events: events.sort(),
        properties: properties.sort(), children: children.sort()
      };
    }

    function orbitResolve(path) {
      var parts = path.split('.');
      var value = chrome;
      for (var i = 0; i < parts.length; i++) {
        if (value === null || typeof value !== 'object') { return undefined; }
        try { value = value[parts[i]]; } catch (e) { return undefined; }
        if (value === undefined) { return undefined; }
      }
      return value;
    }

    function orbitReflectChrome(probeNames) {
      var report = {};
      var top = [];
      try { top = Object.keys(chrome); } catch (e) { top = []; }
      for (var i = 0; i < top.length; i++) {
        var name = top[i], value;
        try { value = chrome[name]; } catch (e) { continue; }
        if (value === null || typeof value !== 'object') { continue; }
        report[name] = orbitReflect(value, 1);
        var nested = report[name].children;
        for (var j = 0; j < nested.length; j++) {
          var child;
          try { child = value[nested[j]]; } catch (e) { continue; }
          if (child === null || typeof child !== 'object') { continue; }
          report[name + '.' + nested[j]] = orbitReflect(child, 0);
        }
      }
      // Enumeration alone would fake absence for a non-enumerable accessor,
      // so every namespace the expectations name is also resolved by name.
      for (var k = 0; k < probeNames.length; k++) {
        var probe = probeNames[k];
        if (report[probe]) { continue; }
        var resolved = orbitResolve(probe);
        if (resolved === null || typeof resolved !== 'object') { continue; }
        report[probe] = orbitReflect(resolved, 0);
      }
      return report;
    }
    """

    private static let reportAttribute = "data-orbit-runtime-surface-report"

    private func writeFixture(named name: String, matchHost: String, permissions: [String], probeNames: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAppTests-RuntimeSurface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let permissionsJSON = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0",
          "permissions": [\(permissionsJSON)],
          "host_permissions": ["http://\(matchHost)/*"],
          "action": { "default_title": "\(name)" },
          "commands": { "orbit-reflection-command": { "description": "Reflection only" } },
          "background": { "service_worker": "background.js" },
          "content_scripts": [
            { "matches": ["http://\(matchHost)/*"], "js": ["content.js"], "run_at": "document_idle" }
          ]
        }
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let probeJSON = String(
            data: try JSONSerialization.data(withJSONObject: probeNames), encoding: .utf8
        ) ?? "[]"
        let background = """
        \(Self.reflectionScript)
        var orbitProbeNames = \(probeJSON);
        chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
          if (message === 'orbit-reflect-chrome') {
            var report;
            try { report = JSON.stringify(orbitReflectChrome(orbitProbeNames)); }
            catch (e) { report = JSON.stringify({ __error: String(e) }); }
            sendResponse(report);
          }
          return true;
        });
        """
        try background.write(to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let content = """
        chrome.runtime.sendMessage('orbit-reflect-chrome', function (response) {
          document.documentElement.setAttribute('\(Self.reportAttribute)', String(response));
        });
        """
        try content.write(to: directory.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        return directory
    }

    private func makeServer() throws -> LiveHTTPTestServer {
        try LiveHTTPTestServer(routes: [
            "/": LiveHTTPTestServer.Route(
                contentType: "text/html",
                body: "<html><body>orbit-runtime-surface-reflection</body></html>"
            ),
        ])
    }

    private static func pollUntil(_ waitingFor: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw EngineError(code: .engineUnavailable, underlyingDescription: "timed out waiting for \(waitingFor)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Loads a fixture with `permissions`, navigates a real page so its content
    /// script runs, and returns what its own service worker sees on `chrome`.
    private func reflect(permissions: [String], fixtureName: String) throws -> Report {
        let expected = try expectations()
        let probeNames = Array(Set(
            expected.mustBeDefined
                + Array(expected.knownUnavailable.keys)
                + expected.gated.map(\.namespace)
                + (try Schema.orbitPortedNamespaces().keys.map { $0 })
        )).sorted()
        let raw = try LiveChromiumEngineHost.runLive(timeout: 90) { () -> String in
            let engine = await LiveChromiumEngineHost.sharedEngine()
            let fixture = try self.writeFixture(
                named: fixtureName, matchHost: "127.0.0.1", permissions: permissions, probeNames: probeNames
            )
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await LiveChromiumEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await LiveChromiumEngineHost.waitUntilStoppedLoading(contents)

            try await Self.pollUntil("the service worker's reflection report") {
                let value = try await contents.evaluateJavaScript(
                    "document.documentElement.getAttribute('\(Self.reportAttribute)')"
                ) as? String
                return (value?.isEmpty == false) && value != "undefined" && value != "null"
            }
            return try await contents.evaluateJavaScript(
                "document.documentElement.getAttribute('\(Self.reportAttribute)')"
            ) as? String ?? ""
        }

        guard let data = raw.data(using: .utf8), !raw.isEmpty else {
            XCTFail("the service worker returned no reflection report at all — its top-level script threw before the listener was registered, which is the 'chrome is not defined' failure mode")
            return [:]
        }
        if let failure = try? JSONDecoder().decode([String: String].self, from: data), let message = failure["__error"] {
            XCTFail("walking the chrome object inside the service worker threw: \(message)")
            return [:]
        }
        return try JSONDecoder().decode(Report.self, from: data)
    }

    private func expectations() throws -> (mustBeDefined: [String], knownUnavailable: [String: String], fixturePermissions: [String], gated: [(namespace: String, permission: String)]) {
        let object = try Schema.readObject(Schema.repositoryFile("OrbitTests/Fixtures/RuntimeSurfaceExpectations.json"))
        let gatedRaw = object["permissionGatedNamespaces"] as? [[String: String]] ?? []
        return (
            object["mustBeDefined"] as? [String] ?? [],
            object["knownUnavailable"] as? [String: String] ?? [:],
            object["fixturePermissions"] as? [String] ?? [],
            gatedRaw.compactMap { row in
                guard let namespace = row["namespace"], let permission = row["permission"] else { return nil }
                return (namespace, permission)
            }
        )
    }

    // MARK: - Positive: everything Orbit claims is reachable

    func testEveryNamespaceOrbitClaimsToSupportIsActuallyDefinedInsideARealMV3ServiceWorker() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let expected = try expectations()
        let report = try reflect(permissions: expected.fixturePermissions, fixtureName: "Orbit Runtime Surface Reflection")

        XCTAssertGreaterThan(
            report.count, 5,
            "the worker reported only \(report.count) namespaces on `chrome`, so the walk itself failed and every assertion below would pass vacuously"
        )

        let missing = expected.mustBeDefined.filter { report[$0] == nil }.sorted()
        XCTAssertEqual(
            missing, [],
            "these namespaces are compiled in and undefined to an extension holding every permission Orbit supports. This is the chrome.scripting failure exactly: the schema is present, the code is linked, and the namespace does not exist at runtime because a feature dependency never resolved. Reflected namespaces were: \(report.keys.sorted())"
        )
    }

    func testEveryFunctionAndEventOrbitsOwnSchemasDeclareIsPresentOnTheRuntimeObject() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let expected = try expectations()
        let report = try reflect(permissions: expected.fixturePermissions, fixtureName: "Orbit Runtime Surface Members")

        var absentMembers: [String] = []
        for (namespace, file) in try Schema.orbitPortedNamespaces() {
            // webstorePrivate is allowlist-restricted and app is
            // disallow_for_service_workers, so both are correctly absent here.
            guard namespace != "webstorePrivate", namespace != "app" else { continue }
            guard let reflected = report[namespace] else {
                absentMembers.append("\(namespace) (whole namespace)")
                continue
            }
            let surface = try Schema.orbitSurface(namespace: namespace, file: file)
            for function in surface.functions.sorted() where !reflected.functions.contains(function) {
                absentMembers.append("\(namespace).\(function) (function)")
            }
            for event in surface.events.sorted() where !reflected.events.contains(event) {
                absentMembers.append("\(namespace).\(event) (event)")
            }
        }
        XCTAssertEqual(
            absentMembers.sorted(), [],
            "Orbit's own schemas declare these members and the extension process cannot see them. A schema diff cannot catch this — the JSON is correct — and it is the gap between 'compiled in' and 'reachable' that made chrome.scripting invisible for so long."
        )
    }

    func testNoNamespaceExpectedAPIGapsRecordsAsAbsentIsSecretlyReachable() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let expected = try expectations()
        let report = try reflect(permissions: expected.fixturePermissions, fixtureName: "Orbit Runtime Surface Absence")

        let unexpectedlyPresent = expected.knownUnavailable.keys
            .filter { report[$0] != nil }
            .sorted()
        XCTAssertEqual(
            unexpectedlyPresent, [],
            "RuntimeSurfaceExpectations.json says these namespaces do not resolve at runtime, and they now do. That is a win, not a bug: delete each entry from knownUnavailable, and if it is also listed in ExpectedAPIGaps.json run `Scripts/extension-schemas update-expectations`. The point of asserting on absence is that nobody can start relying on one of these by accident."
        )
    }

    // MARK: - Negative control: no permissions, nothing gated is reachable

    func testAPermissionlessExtensionCannotSeeAnyPermissionGatedNamespace() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let expected = try expectations()
        let report = try reflect(permissions: [], fixtureName: "Orbit Runtime Surface Negative Control")

        XCTAssertNotNil(
            report["runtime"],
            "even a permissionless extension gets chrome.runtime; its absence means the reflection failed rather than that the gating worked"
        )

        let leaked = expected.gated.filter { report[$0.namespace] != nil }.map { "\($0.namespace) (needs \"\($0.permission)\")" }.sorted()
        XCTAssertEqual(
            leaked, [],
            "these namespaces are reachable by an extension that declared no permissions at all. A permission check that never denies is not a permission check, and a positive-only surface test cannot tell the two apart."
        )
    }

    func testAPermissionlessExtensionSeesOnlyManagementsThreeUngatedMembers() throws {
        try XCTSkipUnless(LiveChromiumEngineHost.isEnabled, "ORBIT_LIVE_ENGINE not set")
        let report = try reflect(permissions: [], fixtureName: "Orbit Runtime Surface Management Control")
        let object = try Schema.readObject(Schema.repositoryFile("OrbitTests/Fixtures/RuntimeSurfaceExpectations.json"))
        let partial = object["partiallyGatedNamespaces"] as? [String: [String: Any]] ?? [:]
        let alwaysAvailable = partial["management"]?["alwaysAvailable"] as? [String] ?? []
        XCTAssertFalse(alwaysAvailable.isEmpty, "the management control row lost its alwaysAvailable list")

        guard let management = report["management"] else {
            XCTFail("chrome.management is undefined without the permission; upstream keeps its three dependencies:[] members available to every extension, so this shape change would break getSelf() for anything that calls it")
            return
        }
        for member in alwaysAvailable {
            XCTAssertTrue(
                management.functions.contains(member),
                "chrome.management.\(member) takes no permission upstream and is missing without one here"
            )
        }
        let gatedButPresent = management.functions.filter { !alwaysAvailable.contains($0) }.sorted()
        XCTAssertEqual(
            gatedButPresent, [],
            "chrome.management exposed permission-gated functions to an extension that never asked for the management permission"
        )
    }
}
