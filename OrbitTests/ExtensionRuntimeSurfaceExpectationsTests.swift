// Keeps RuntimeSurfaceExpectations.json consistent with _api_features.json and
// ExpectedAPIGaps.json without starting an engine. Load-bearing: the negative control
// asserting every permission-gated namespace is undefined without that permission.

import XCTest

final class ExtensionRuntimeSurfaceExpectationsTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface

    private func expectations() throws -> [String: Any] {
        try Schema.readObject(Schema.repositoryFile("OrbitTests/Fixtures/RuntimeSurfaceExpectations.json"))
    }

    private func stringList(_ key: String) throws -> [String] {
        try XCTUnwrap(expectations()[key] as? [String], "RuntimeSurfaceExpectations.json is missing the \"\(key)\" list")
    }

    /// namespace -> the permission its `dependencies` names, from Orbit's own
    /// API feature file.
    private func orbitPermissionGatedNamespaces() throws -> [String: String] {
        let object = try Schema.readObject(
            Schema.repositoryFile("Chromium/Embedder/common/api/_api_features.json")
        )
        var gated: [String: String] = [:]
        for (name, raw) in object {
            guard !name.contains("."), let entry = raw as? [String: Any] else { continue }
            let dependencies = entry["dependencies"] as? [String] ?? []
            for dependency in dependencies where dependency.hasPrefix("permission:") {
                gated[name] = String(dependency.dropFirst("permission:".count))
            }
        }
        return gated
    }

    // MARK: - The negative control is a table, not a one-off

    func test_everyPermissionGatedNamespaceOrbitDeclaresHasANegativeControlRow() throws {
        let gated = try orbitPermissionGatedNamespaces()
        XCTAssertFalse(gated.isEmpty, "parsed no permission dependencies out of _api_features.json")

        let rows = try XCTUnwrap(expectations()["permissionGatedNamespaces"] as? [[String: String]])
        let covered = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
            guard let namespace = row["namespace"], let permission = row["permission"] else { return nil }
            return (namespace, permission)
        })

        let uncovered = gated.keys.filter { covered[$0] == nil }.sorted()
        XCTAssertEqual(
            uncovered, [],
            "these namespaces are gated on a permission in Chromium/Embedder/common/api/_api_features.json and nothing asserts they are actually denied without it. A permission check that never denies is not a permission check."
        )

        for (namespace, permission) in gated where covered[namespace] != nil {
            XCTAssertEqual(
                covered[namespace], permission,
                "the negative control for \(namespace) names permission \"\(covered[namespace] ?? "")\" but _api_features.json gates it on \"\(permission)\""
            )
        }
    }

    func test_theNegativeControlNamesNoNamespaceThatIsNotActuallyGated() throws {
        let rows = try XCTUnwrap(expectations()["permissionGatedNamespaces"] as? [[String: String]])
        for row in rows {
            let namespace = try XCTUnwrap(row["namespace"])
            let permission = try XCTUnwrap(row["permission"])
            XCTAssertFalse(namespace.isEmpty)
            XCTAssertFalse(
                permission.isEmpty,
                "\(namespace) has a negative-control row with no permission, so the control asserts nothing"
            )
        }
    }

    // MARK: - The three lists cannot contradict each other

    func test_nothingIsRequiredToBeDefinedAndKnownUnavailableAtOnce() throws {
        let mustBeDefined = Set(try stringList("mustBeDefined"))
        let knownUnavailable = Set(try XCTUnwrap(expectations()["knownUnavailable"] as? [String: String]).keys)
        XCTAssertEqual(
            mustBeDefined.intersection(knownUnavailable).sorted(), [],
            "these namespaces are listed as both required at runtime and known to be unavailable; whichever assertion runs second is dead"
        )
    }

    func test_everyKnownUnavailableNamespaceCarriesTheReasonItIsUnavailable() throws {
        let knownUnavailable = try XCTUnwrap(expectations()["knownUnavailable"] as? [String: String])
        XCTAssertFalse(knownUnavailable.isEmpty)
        for (namespace, reason) in knownUnavailable.sorted(by: { $0.key < $1.key }) {
            XCTAssertGreaterThan(
                reason.count, 20,
                "\(namespace) is asserted absent with no real explanation. This list is the runtime half of ExpectedAPIGaps.json: an entry without a reason is an untested namespace with a nicer label."
            )
        }
    }

    func test_everyNamespaceOrbitPortsIsRequiredToBeDefinedAtRuntime() throws {
        let mustBeDefined = Set(try stringList("mustBeDefined"))
        // Both are web-page APIs an MV3 service worker is never meant to see:
        // webstorePrivate is allowlist-restricted, app is disallow_for_service_workers.
        let ported = try Schema.orbitPortedNamespaces().keys
            .filter { $0 != "webstorePrivate" && $0 != "app" }
        let unasserted = ported.filter { !mustBeDefined.contains($0) }.sorted()
        XCTAssertEqual(
            unasserted, [],
            "Orbit ships a schema for these and nothing asserts an extension can actually reach them. The schema being present is precisely what made chrome.scripting's absence invisible."
        )
    }

    func test_everyKnownUnavailableChromeLayerNamespaceIsAlsoRecordedInExpectedAPIGaps() throws {
        let knownUnavailable = try XCTUnwrap(expectations()["knownUnavailable"] as? [String: String])
        let gaps = try Schema.readExpectations().namespaces
        // ExpectedAPIGaps.json records chrome-layer gaps only; a compiled-in core namespace
        // that still doesn't resolve has no schema to diff. devtools.* is 3 namespaces
        // upstream but 1 object at runtime, so the runtime list names the parent.
        let exempt = try Schema.upstreamIndex().coreNamespaces.union(["devtools"])
        let unrecorded = knownUnavailable.keys
            .filter { !exempt.contains($0) && gaps[$0]?.status != "absent" }
            .sorted()
        XCTAssertEqual(
            unrecorded, [],
            "these namespaces are asserted unreachable at runtime but ExpectedAPIGaps.json does not record them as absent. Either Orbit ported one — in which case it belongs in mustBeDefined — or the schema diff and the runtime reflection now disagree about what exists."
        )
    }

    func test_theFixturePermissionListOnlyNamesPermissionsOrbitCanActuallyRegister() throws {
        let fixturePermissions = Set(try stringList("fixturePermissions"))
        XCTAssertFalse(fixturePermissions.isEmpty)
        // The chrome-layer ones Orbit registers itself; everything else has to
        // be a core //extensions permission, which Orbit gets for free.
        let orbitRegistered = try Schema.registeredPermissionNames()
        let chromeLayer = Set(try Schema.upstreamIndex().chromePermissions)
            .subtracting(try Schema.upstreamIndex().corePermissions)
        let declaredButUnregistered = fixturePermissions
            .intersection(chromeLayer)
            .subtracting(orbitRegistered)
            .sorted()
        XCTAssertEqual(
            declaredButUnregistered, [],
            "the reflection fixture declares chrome-layer permissions Orbit never registers. Chromium drops an unknown permission from the manifest without an error, so the fixture would quietly run with fewer permissions than it asks for and the positive surface test would fail for the wrong reason."
        )
    }
}
