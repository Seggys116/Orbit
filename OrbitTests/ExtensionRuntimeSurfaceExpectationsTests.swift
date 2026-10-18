// Keeps RuntimeSurfaceExpectations.json consistent with the wrapper inventory, the WebKit permission
// list and ExpectedAPIGaps.json without starting an engine. Load-bearing: the negative control
// asserting every permission-gated namespace is undefined without that permission.

import XCTest

final class ExtensionRuntimeSurfaceExpectationsTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface
    private typealias Inventory = ChromeAPISurfaceInventory

    private func expectations() throws -> [String: Any] {
        try Schema.readObject(Schema.repositoryFile("OrbitTests/Fixtures/RuntimeSurfaceExpectations.json"))
    }

    private func stringList(_ key: String) throws -> [String] {
        try XCTUnwrap(expectations()[key] as? [String], "RuntimeSurfaceExpectations.json is missing the \"\(key)\" list")
    }

    // MARK: - The negative control is a table, not a one-off

    func test_everyPermissionGatedNamespaceOrbitDeclaresHasANegativeControlRow() throws {
        let rows = try XCTUnwrap(expectations()["permissionGatedNamespaces"] as? [[String: String]])
        XCTAssertFalse(rows.isEmpty)
        let known = try Schema.upstreamIndex().chromePermissions.union(Schema.upstreamIndex().corePermissions)
        for row in rows {
            let namespace = try XCTUnwrap(row["namespace"])
            let permission = try XCTUnwrap(row["permission"])
            XCTAssertFalse(namespace.isEmpty)
            XCTAssertTrue(known.contains(permission), permission)
        }
    }

    func test_everyNegativeControlRowNamesThePermissionThatActuallyGatesIt() throws {
        let rows = try XCTUnwrap(expectations()["permissionGatedNamespaces"] as? [[String: String]])
        let wrapperNamespaces = Set(Inventory.namespaces.map(\.name)).union(["privacy"])
        let native = Set(Inventory.webKitNativeNamespaces)
        for row in rows {
            let namespace = try XCTUnwrap(row["namespace"])
            let permission = try XCTUnwrap(row["permission"])
            XCTAssertFalse(
                permission.isEmpty,
                "\(namespace) has a negative-control row with no permission, so the control asserts nothing"
            )
            if wrapperNamespaces.contains(namespace) {
                XCTAssertEqual(permission, namespace, "the wrapper gates chrome.\(namespace) on the permission of the same name")
            } else if native.contains(namespace) {
                XCTAssertTrue(
                    Inventory.webKitNativePermissions.contains(permission),
                    "\(namespace) is WebKit's, so only a permission WebKit recognises can gate it; \(permission) is not one"
                )
            } else {
                XCTFail("\(namespace) is neither created by the wrapper nor provided by WebKit, so no permission gates it here")
            }
        }
    }

    func test_everyPermissionGatedNamespaceTheWrapperCreatesHasANegativeControlRow() throws {
        let rows = try XCTUnwrap(expectations()["permissionGatedNamespaces"] as? [[String: String]])
        let covered = Set(rows.compactMap { $0["namespace"] })
        let partial = try XCTUnwrap(expectations()["partiallyGatedNamespaces"] as? [String: [String: Any]])
        let wrapperNamespaces = Set(Inventory.namespaces.map(\.name)).union(["privacy"])
        let uncovered = wrapperNamespaces.subtracting(covered).subtracting(partial.keys).sorted()
        XCTAssertEqual(
            uncovered, [],
            "the wrapper creates these permission-gated namespaces and nothing asserts they stay undefined without the permission, so a newly wrapped namespace could skip the control"
        )
    }

    func test_thePartiallyGatedRowMatchesTheInventorysUngatedMembers() throws {
        let partial = try XCTUnwrap(expectations()["partiallyGatedNamespaces"] as? [String: [String: Any]])
        for (name, row) in partial {
            let namespace = try XCTUnwrap(Inventory.namespaces.first { $0.name == name }, "\(name) is not a wrapper namespace")
            XCTAssertEqual(
                Set(row["alwaysAvailable"] as? [String] ?? []), Set(namespace.ungatedMethods),
                "the control's list of always-available \(name) members is not the one the wrapper keeps"
            )
        }
        XCTAssertNotNil(partial["management"])
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

    func test_everyNamespaceTheWrapperCreatesIsRequiredToBeDefinedAtRuntime() throws {
        let mustBeDefined = Set(try stringList("mustBeDefined"))
        let created = Set(Inventory.namespaces.map(\.name)).union(["privacy"])
        let unasserted = created.subtracting(mustBeDefined).sorted()
        XCTAssertEqual(
            unasserted, [],
            "the wrapper creates these and nothing asserts an extension can actually reach them. A namespace being declared is precisely what made chrome.scripting's absence invisible."
        )
    }

    func test_noKnownUnavailableNamespaceIsOneTheWrapperOrWebKitProvidesOrMightProvide() throws {
        let knownUnavailable = Set(try XCTUnwrap(expectations()["knownUnavailable"] as? [String: String]).keys)
        let provided = Set(Inventory.namespaces.map(\.name)).union(Inventory.webKitNativeNamespaces).union(["privacy"])
        XCTAssertEqual(knownUnavailable.intersection(provided).sorted(), [], "asserted undefined but provided")
        let gaps = try Schema.readExpectations().namespaces
        let unverified = gaps.filter { $0.value.status == "unverified" }.keys
        XCTAssertEqual(
            knownUnavailable.intersection(unverified).sorted(), [],
            "ExpectedAPIGaps.json says WebKit may provide these, so the runtime suite must not assert them undefined"
        )
    }

    func test_everyNamespaceThatNeedsAFixturePermissionHasItDeclared() throws {
        let fixturePermissions = Set(try stringList("fixturePermissions"))
        let needed = Set(Inventory.namespaces.map(\.name)).union(["privacy"])
        XCTAssertEqual(
            needed.subtracting(fixturePermissions).sorted(), [],
            "the reflection fixture does not declare the permission for these wrapper namespaces, so the runtime walk could never see them"
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
        let known = try Schema.upstreamIndex().chromePermissions.union(Schema.upstreamIndex().corePermissions)
        let invented = fixturePermissions.subtracting(known).sorted()
        XCTAssertEqual(
            invented, [],
            "the reflection fixture names permissions the vendored upstream snapshot does not define"
        )
    }
}
