//  Schema conformance proves a declared surface matches, not that the binding reached the worker --
//  how chrome.scripting stayed compiled-in and undefined. Walks the real `chrome` object inside a real
//  MV3 worker and holds it to the wrapper inventory and the gap register in both directions.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitExtensionRuntimeSurfaceReflectionLiveTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface
    private typealias Inventory = ChromeAPISurfaceInventory

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
    function orbitNames(value) {
      var names = [], seen = {}, current = value, depth = 0;
      while (current && current !== Object.prototype && depth < 4) {
        var own;
        try { own = Object.getOwnPropertyNames(current); } catch (e) { own = []; }
        for (var i = 0; i < own.length; i++) {
          if (seen[own[i]]) { continue; }
          seen[own[i]] = true;
          names.push(own[i]);
        }
        try { current = Object.getPrototypeOf(current); } catch (e) { break; }
        depth++;
      }
      return names;
    }

    function orbitReflect(value, depth) {
      var functions = [], events = [], properties = [], children = [];
      var keys;
      try { keys = orbitNames(value); } catch (e) { keys = []; }
      for (var i = 0; i < keys.length; i++) {
        var name = keys[i], member;
        if (name.indexOf('__orbit') === 0) { continue; }
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
        var names = Set<String>(expected.mustBeDefined)
        names.formUnion(expected.knownUnavailable.keys)
        names.formUnion(expected.gated.map(\.namespace))
        names.formUnion(Inventory.namespaces.map(\.name))
        names.formUnion(Inventory.augmentations.map(\.namespace))
        names.insert("privacy")
        let probeNames = names.sorted()
        let raw = try WebKitLiveEngineHost.runLive(timeout: 90) { () -> String in
            let engine = await WebKitLiveEngineHost.sharedEngine()
            let fixture = try self.writeFixture(
                named: fixtureName, matchHost: "127.0.0.1", permissions: permissions, probeNames: probeNames
            )
            let server = try self.makeServer()
            defer { server.stop() }

            let loaded = try await engine.loadExtension(at: fixture, session: engine.defaultSession)
            defer { engine.unloadExtension(id: loaded.id, session: engine.defaultSession) }

            let contents = try await WebKitLiveEngineHost.makeContents(engine: engine)
            defer { contents.close() }
            contents.load(server.baseURL)
            try await WebKitLiveEngineHost.waitUntilStoppedLoading(contents)

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

    /// What the extension process sees of a namespace, by kind: nested namespace-shaped objects count as properties.
    private func present(_ reflected: ReflectedNamespace, _ kind: Schema.MemberKind) -> Set<String> {
        switch kind {
        case .functions: return Set(reflected.functions)
        case .events: return Set(reflected.events)
        case .properties: return Set(reflected.properties + reflected.children)
        case .types: return []
        }
    }

    func testEveryMemberTheWrapperInventoryDeclaresIsPresentOnTheRuntimeObject() throws {
        let expected = try expectations()
        let report = try reflect(permissions: expected.fixturePermissions, fixtureName: "Orbit Runtime Surface Members")

        var absentMembers: [String] = []
        for namespace in Inventory.namespaces {
            guard let reflected = report[namespace.name] else {
                absentMembers.append("\(namespace.name) (whole namespace)")
                continue
            }
            for function in namespace.methods where !present(reflected, .functions).contains(function) {
                absentMembers.append("\(namespace.name).\(function) (function)")
            }
            for event in namespace.events where !present(reflected, .events).contains(event) {
                absentMembers.append("\(namespace.name).\(event) (event)")
            }
            for constant in namespace.constants where !present(reflected, .properties).contains(constant) {
                absentMembers.append("\(namespace.name).\(constant) (constant)")
            }
        }
        XCTAssertEqual(
            absentMembers.sorted(), [],
            "the wrapper inventory declares these members and the extension process cannot see them. A schema diff cannot catch this -- the declaration is correct -- and it is the gap between 'provided' and 'reachable' that made chrome.scripting invisible for so long."
        )
    }

    func testEveryMemberTheWrapperAddsToWebKitsNamespacesReachesTheWorker() throws {
        let expected = try expectations()
        let report = try reflect(permissions: expected.fixturePermissions, fixtureName: "Orbit Runtime Surface Augmentations")

        var absentMembers: [String] = []
        for augmentation in Inventory.augmentations {
            guard let reflected = report[augmentation.namespace] else {
                absentMembers.append("\(augmentation.namespace) (whole namespace)")
                continue
            }
            for function in augmentation.functions where !present(reflected, .functions).contains(function) {
                absentMembers.append("\(augmentation.namespace).\(function) (function)")
            }
            for event in augmentation.events where !present(reflected, .events).contains(event) {
                absentMembers.append("\(augmentation.namespace).\(event) (event)")
            }
            for property in augmentation.properties where !property.contains(".")
                && !present(reflected, .properties).contains(property) {
                absentMembers.append("\(augmentation.namespace).\(property) (property)")
            }
        }
        XCTAssertEqual(
            absentMembers.sorted(), [],
            "the wrapper is meant to add these to namespaces WebKit provides, and a real worker cannot see them: an extension that registers for one of these events throws at load"
        )
    }

    /// The live half of ExpectedAPIGaps.json: every upstream member of a namespace Orbit provides
    /// either exists in the worker or is recorded missing, and nothing recorded missing exists.
    func testTheRuntimeSurfaceMatchesTheGapRegisterMemberForMember() throws {
        let expected = try expectations()
        let report = try reflect(permissions: expected.fixturePermissions, fixtureName: "Orbit Runtime Surface Gap Register")
        let gaps = try Schema.readExpectations().namespaces

        var wrong: [String] = []
        var accepted: [String] = []
        for (name, gap) in gaps.sorted(by: { $0.key < $1.key })
        where gap.status == "partial" || gap.status == "complete" {
            guard let reflected = report[name] else {
                wrong.append("\(name): the namespace is undefined in the worker")
                continue
            }
            guard let upstream = try Schema.upstreamSurface(ofNamespace: name) else { continue }
            for kind in Schema.comparedKinds {
                let live = present(reflected, kind)
                // Dotted paths (privacy.services.*) are nested members the flat walk does not list.
                let wanted = upstream.names(ofKind: kind).filter { !$0.contains(".") }
                let recorded = Set((gap.missing[kind] ?? []).filter { !$0.contains(".") })
                let tolerated = Set(gap.uncertain[kind] ?? [])
                for member in wanted.subtracting(live).subtracting(recorded).subtracting(tolerated).sorted() {
                    wrong.append("\(name).\(member) (\(kind.singular)) is missing in the worker and not recorded as missing")
                }
                for member in recorded.intersection(live).sorted() {
                    wrong.append("\(name).\(member) (\(kind.singular)) exists in the worker but is recorded as missing: delete it from ExpectedAPIGaps.json")
                }
                for member in tolerated.sorted() {
                    accepted.append("\(name).\(member) (\(kind.singular)) \(live.contains(member) ? "present" : "absent")")
                }
            }
        }
        XCTContext.runActivity(named: "WebKit-version-dependent members, as observed") { activity in
            activity.add(XCTAttachment(string: accepted.joined(separator: "\n")))
        }
        XCTAssertEqual(
            wrong, [],
            "the live surface and OrbitTests/Fixtures/ExpectedAPIGaps.json disagree. Each line is a member that silently stopped existing, or one that now exists and is still recorded as missing. Members WebKit's version decides belong in an uncertain list until observed here."
        )
    }

    func testNoNamespaceExpectedAPIGapsRecordsAsAbsentIsSecretlyReachable() throws {
        let expected = try expectations()
        let report = try reflect(permissions: expected.fixturePermissions, fixtureName: "Orbit Runtime Surface Absence")

        let unexpectedlyPresent = expected.knownUnavailable.keys
            .filter { report[$0] != nil }
            .sorted()
        XCTAssertEqual(
            unexpectedlyPresent, [],
            "RuntimeSurfaceExpectations.json says these namespaces do not resolve at runtime, and they now do. That is a win, not a bug: delete each entry from knownUnavailable, and re-triage its row in ExpectedAPIGaps.json, which still says nothing provides it. The point of asserting on absence is that nobody can start relying on one of these by accident."
        )
    }

    // MARK: - Negative control: no permissions, nothing gated is reachable

    func testAPermissionlessExtensionCannotSeeAnyPermissionGatedNamespace() throws {
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

    // MARK: - The two copies of the wrapped permission list

    func testTheEnginesPermissionListAndTheWrapperInventoryAgree() {
        XCTAssertEqual(
            WebKitExtensionServices.orbitPermissions, Inventory.wrappedPermissions,
            "WebKitExtensionServices and the wrapper inventory disagree on which permissions Orbit itself implements; the engine would gate or recognise a different set than the wrapper creates"
        )
    }
}
