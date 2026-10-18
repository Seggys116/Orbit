// The anti-subset check: fixture-driven tests can only exercise what their author believed
// exists, so a missing namespace stays invisible. The wrapper half runs the generated wrapper in
// JavaScriptCore and diffs what it really defines against the vendored upstream schemas; the
// WebKit half is checked live by WebKitExtensionRuntimeSurfaceReflectionLiveTests. Both are
// held to ExpectedAPIGaps.json.

import CryptoKit
import XCTest

final class ExtensionSchemaConformanceTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface
    private typealias Inventory = ChromeAPISurfaceInventory

    private func wrapperSession() throws -> ChromeWrapperRuntime.Session {
        try ChromeWrapperRuntime.startWithEveryWrappedPermission()
    }

    private var wrapperNamespaceNames: Set<String> {
        Set(Inventory.namespaces.map(\.name)).union(["privacy"])
    }

    // MARK: - The snapshot is real, current, and unedited

    func test_vendoredUpstreamSnapshotHasAVersionStamp() throws {
        let index = try Schema.upstreamIndex()
        XCTAssertFalse(index.chromiumVersion.isEmpty)
        XCTAssertEqual(
            try Schema.readExpectations().upstreamVersion, index.chromiumVersion,
            "ExpectedAPIGaps.json was triaged against a different upstream snapshot than the one vendored now, so every gap in it is measured against the wrong schema. Re-vendor, then re-triage the diff."
        )
    }

    func test_vendoredUpstreamSnapshotIsNotEmptyAndCoversEveryNamespaceTheWrapperProvides() throws {
        let index = try Schema.upstreamIndex()
        XCTAssertGreaterThan(
            index.chromeNamespaces.count, 100,
            "the vendored snapshot lists \(index.chromeNamespaces.count) chrome-layer namespaces; upstream has well over a hundred, so the sync captured nothing and every assertion below would pass vacuously"
        )
        XCTAssertGreaterThan(index.coreNamespaces.count, 40, "core namespace list is implausibly short")

        let provided = wrapperNamespaceNames.union(Inventory.augmentations.map(\.namespace))
        for namespace in provided.sorted() {
            XCTAssertTrue(
                index.knownNamespaces.contains(namespace),
                "the chrome wrapper provides \(namespace), which the vendored upstream snapshot does not list"
            )
        }
    }

    func test_vendoredSchemaFilesStillHashToWhatTheSyncRecorded() throws {
        let index = try Schema.upstreamIndex()
        XCTAssertFalse(index.schemaSHA256.isEmpty, "the vendored index records no file hashes")
        for (file, expected) in index.schemaSHA256.sorted(by: { $0.key < $1.key }) {
            let url = Schema.vendoredUpstreamDirectory.appendingPathComponent(file)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(
                Self.sha256Hex(data), expected,
                "\(file) no longer matches the hash the sync recorded for it. The vendored copies are upstream's bytes; editing one to make a gap disappear is the one way to defeat this whole suite."
            )
        }
    }

    // MARK: - The wrapper really defines what its inventory says

    func test_theGeneratedWrapperDefinesExactlyTheNamespacesTheInventoryDeclares() throws {
        let session = try wrapperSession()
        for namespace in Inventory.namespaces {
            let members = try XCTUnwrap(
                session.members(of: namespace.name),
                "the generated wrapper defines no chrome.\(namespace.name) although the inventory declares it and its permission is granted"
            )
            XCTAssertEqual(
                members.functions, Set(namespace.methods),
                "chrome.\(namespace.name) functions differ between the inventory and the wrapper that was generated"
            )
            XCTAssertEqual(
                members.events, Set(namespace.events),
                "chrome.\(namespace.name) events differ between the inventory and the wrapper that was generated"
            )
            XCTAssertEqual(
                members.properties.union(members.enums), Set(namespace.constants),
                "chrome.\(namespace.name) constants differ between the inventory and the wrapper that was generated"
            )
        }
    }

    func test_theGeneratedWrapperAddsEveryInventoryAugmentationToTheNamespacesWebKitProvides() throws {
        let session = try wrapperSession()
        for augmentation in Inventory.augmentations {
            let members = try XCTUnwrap(
                session.members(of: augmentation.namespace),
                "chrome.\(augmentation.namespace) is missing after the wrapper ran over a WebKit that provides it"
            )
            XCTAssertEqual(
                Set(augmentation.functions).subtracting(members.functions).sorted(), [],
                "the wrapper no longer adds these chrome.\(augmentation.namespace) functions"
            )
            XCTAssertEqual(
                Set(augmentation.events).subtracting(members.events).sorted(), [],
                "the wrapper no longer adds these chrome.\(augmentation.namespace) events; an extension registering for one throws at load"
            )
            XCTAssertEqual(
                Set(augmentation.properties).subtracting(members.properties.union(members.enums)).sorted(), [],
                "the wrapper no longer adds these chrome.\(augmentation.namespace) members"
            )
        }
    }

    func test_theWrapperLeavesAnUnprovidedNamespaceOutRatherThanInventingIt() throws {
        let session = try ChromeWrapperRuntime.start(manifestPermissions: [])
        for namespace in Inventory.namespaces where namespace.ungatedMethods.isEmpty {
            XCTAssertFalse(
                session.exists(namespace.name),
                "chrome.\(namespace.name) exists for an extension that declared no permissions"
            )
        }
        XCTAssertFalse(session.exists("privacy"), "chrome.privacy exists without the privacy permission")
    }

    // MARK: - The diff against upstream

    func test_everyMemberTheWrapperAddsExistsInTheVendoredUpstreamSchema() throws {
        let session = try wrapperSession()
        for augmentation in Inventory.augmentations {
            guard let upstream = try Schema.upstreamSurface(ofNamespace: augmentation.namespace) else { continue }
            XCTAssertEqual(
                Set(augmentation.functions).subtracting(upstream.functions).sorted(), [],
                "chrome.\(augmentation.namespace) functions the wrapper adds are not in the upstream schema"
            )
            XCTAssertEqual(
                Set(augmentation.events).subtracting(upstream.events).sorted(), [],
                "chrome.\(augmentation.namespace) events the wrapper adds are not in the upstream schema"
            )
        }
        for (namespace, gap) in try Schema.computeWrapperGaps(in: session) {
            for kind in Schema.comparedKinds {
                XCTAssertEqual(
                    gap.extra[kind] ?? [], [],
                    "chrome.\(namespace) defines \(kind.rawValue) the upstream schema does not declare"
                )
            }
        }
    }

    func test_theWrapperGapAgainstUpstreamIsExactlyTheCheckedInExpectation() throws {
        let session = try wrapperSession()
        let computed = try Schema.computeWrapperGaps(in: session)
        XCTAssertGreaterThanOrEqual(computed.count, 6, "diffed only \(computed.keys.sorted()); the wrapper probe found almost nothing")

        let expected = try Schema.readExpectations().namespaces
        let recorded = expected.filter { $0.value.provider == "wrapper" && computed[$0.key] != nil }
        XCTAssertEqual(
            Set(recorded.keys), Set(computed.keys),
            "every wrapper-provided namespace with a vendored schema needs an ExpectedAPIGaps.json row with provider \"wrapper\""
        )

        let computedLines = Schema.lines(for: computed)
        let expectedLines = Schema.lines(for: recorded)
        XCTAssertEqual(
            Set(computedLines).subtracting(expectedLines).sorted(), [],
            "the wrapper lost members ExpectedAPIGaps.json says it has, or gained members upstream does not declare. Each line is an extension API that silently stopped existing -- the exact failure mode this suite was built for. If the loss is deliberate, record it in the namespace's missing list and say why in its note."
        )
        XCTAssertEqual(
            Set(expectedLines).subtracting(computedLines).sorted(), [],
            "the wrapper now IMPLEMENTS members ExpectedAPIGaps.json still lists as missing. This is a pass-worthy failure: delete each line from the namespace's missing list to record the win."
        )
        for (name, gap) in recorded {
            let clean = (computed[name]?.missing.isEmpty ?? false) && (computed[name]?.extra.isEmpty ?? false)
            XCTAssertEqual(
                gap.status == "complete", clean,
                "\(name) is recorded as \(gap.status) but its member diff is \(clean ? "empty" : "not empty")"
            )
        }
    }

    // MARK: - Triage

    func test_everyAbsentNamespaceHasBeenTriaged() throws {
        let expected = try Schema.readExpectations()
        let untriaged = expected.namespaces
            .filter { $0.value.status == "absent" && ($0.value.reason ?? "unclassified") == "unclassified" }
            .keys.sorted()
        XCTAssertEqual(
            untriaged, [],
            "these chrome-layer namespaces are absent from Orbit and nobody has said why. A new upstream namespace lands here as `unclassified` on purpose: classify each as notPorted, outOfScope, chromeInternal or webkitImpossible in OrbitTests/Fixtures/ExpectedAPIGaps.json so 'what is still missing' stays a query rather than an investigation."
        )
        let allowedReasons: Set<String> = ["notPorted", "outOfScope", "chromeInternal", "webkitImpossible"]
        for (name, gap) in expected.namespaces where gap.status == "absent" {
            XCTAssertTrue(
                allowedReasons.contains(gap.reason ?? ""),
                "\(name) has reason \"\(gap.reason ?? "")\", which is not one of \(allowedReasons.sorted())"
            )
        }
        for (name, gap) in expected.namespaces where gap.status == "unverified" {
            XCTAssertEqual(gap.reason, "webkitVariable", "\(name) is unverified for a reason the suite does not know")
        }
    }

    func test_everyWebKitImpossibleNamespaceIsExplainedByTheInventory() throws {
        let expected = try Schema.readExpectations()
        let impossible = expected.namespaces.filter { $0.value.reason == "webkitImpossible" }.keys.sorted()
        XCTAssertFalse(impossible.isEmpty)
        for name in impossible {
            let reason = Inventory.impossibleOnWebKit[name] ?? ""
            XCTAssertGreaterThan(
                reason.count, 20,
                "\(name) is recorded as impossible on WebKit and ChromeAPISurfaceInventory.impossibleOnWebKit says nothing about why"
            )
        }
    }

    func test_theNamespacesTheExpectationsFileNamesStillExistUpstream() throws {
        let index = try Schema.upstreamIndex()
        let expected = try Schema.readExpectations()
        let phantom = expected.namespaces.keys.filter { !index.knownNamespaces.contains($0) }.sorted()
        XCTAssertEqual(
            phantom, [],
            "ExpectedAPIGaps.json records gaps for namespaces the vendored upstream snapshot does not have. They were removed upstream and the expectations were never re-synced, so the file is now recording fiction."
        )
    }

    func test_everyChromeLayerNamespaceHasARow() throws {
        let index = try Schema.upstreamIndex()
        let expected = try Schema.readExpectations()
        let unrecorded = index.chromeNamespaces.filter { expected.namespaces[$0] == nil }.sorted()
        XCTAssertEqual(
            unrecorded, [],
            "these upstream chrome-layer namespaces have no row in ExpectedAPIGaps.json, so nothing says whether Orbit provides them"
        )
    }

    // MARK: - Who provides what

    func test_theRecordedProviderOfEveryNamespaceAgreesWithTheInventory() throws {
        let expected = try Schema.readExpectations().namespaces
        let wrapperOnly = wrapperNamespaceNames
        let augmented = Set(Inventory.augmentations.map(\.namespace))
        let native = Set(Inventory.webKitNativeNamespaces)
        let allowed: Set<String> = ["wrapper", "webkit", "webkit+wrapper", "none"]

        for (name, gap) in expected.sorted(by: { $0.key < $1.key }) {
            let provider = gap.provider ?? ""
            XCTAssertTrue(allowed.contains(provider), "\(name) has provider \"\(provider)\"")
            if wrapperOnly.contains(name) {
                XCTAssertEqual(provider, "wrapper", "\(name) is created by the wrapper's inventory")
            } else if native.contains(name) && augmented.contains(name) {
                XCTAssertEqual(provider, "webkit+wrapper", "\(name) is WebKit's and the inventory augments it")
            } else if native.contains(name) {
                XCTAssertEqual(provider, "webkit", "\(name) is in the WebKit-native list and nothing augments it")
            } else {
                XCTAssertEqual(provider, "none", "\(name) is neither created by the wrapper nor provided by WebKit")
                XCTAssertTrue(
                    gap.status == "absent" || gap.status == "unverified",
                    "\(name) has no provider but status \(gap.status)"
                )
            }
        }
        for name in native.intersection(try Schema.upstreamIndex().chromeNamespaces) {
            XCTAssertNotNil(expected[name], "WebKit-native chrome-layer namespace \(name) has no row")
        }
    }

    func test_everyWebKitNativeNamespaceIsRequiredToBeDefinedAtRuntime() throws {
        let object = try Schema.readObject(Schema.repositoryFile("OrbitTests/Fixtures/RuntimeSurfaceExpectations.json"))
        let mustBeDefined = Set(object["mustBeDefined"] as? [String] ?? [])
        let missing = Set(Inventory.webKitNativeNamespaces).union(wrapperNamespaceNames).subtracting(mustBeDefined)
        XCTAssertEqual(
            missing.sorted(), [],
            "nothing asserts an extension can actually reach these namespaces at runtime. A namespace being declared is precisely what made chrome.scripting's absence invisible."
        )
    }

    // MARK: - Permissions

    func test_theChromePermissionsNobodyProvidesAreExactlyTheCheckedInExpectation() throws {
        let computed = Set(try Schema.permissionsWithoutProvider())
        let expected = Set(try Schema.readExpectations().permissionsWithoutProvider)
        XCTAssertGreaterThan(computed.count, 50, "computed only \(computed.count) unprovided permissions; the vendored index was not read")
        XCTAssertEqual(
            computed.subtracting(expected).sorted(), [],
            "these Chrome permissions lost their provider: the wrapper no longer acts on them or WebKit stopped recognising them. An extension declaring one silently gets nothing."
        )
        XCTAssertEqual(
            expected.subtracting(computed).sorted(), [],
            "these permissions now have a provider but ExpectedAPIGaps.json still lists them as unprovided. Delete them from permissionsWithoutProvider to record the win."
        )
    }

    func test_wrappedPermissionsAreRealChromePermissionsAnOrdinaryExtensionCanHold() throws {
        let index = try Schema.upstreamIndex()
        let wrapped = Inventory.wrappedPermissions
        XCTAssertGreaterThan(wrapped.count, 10)
        XCTAssertEqual(wrapped.subtracting(index.knownPermissions).sorted(), [], "the wrapper acts on permissions upstream does not define")
        XCTAssertFalse(try Schema.upstreamChromePermissionFeatures().isEmpty)
        for name in wrapped.sorted() {
            XCTAssertTrue(
                try Schema.isGrantableToAnOrdinaryExtension(name),
                "\(name) is a permission upstream Chrome withholds from an ordinary stable macOS extension, and the wrapper hands it to every extension that declares it"
            )
        }
    }

    /// The keys of `apiPermissionCatalog`, read out of the Swift literal.
    private func permissionWarningNames() throws -> Set<String> {
        let url = Schema.repositoryFile("Orbit/Engine/Extensions/ExtensionPermissionWarnings.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "apiPermissionCatalog: [String: (text: String, severity: ExtensionPermissionWarningSeverity)] = ["),
              let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex)
        else {
            XCTFail("could not find the apiPermissionCatalog literal in \(url.path)")
            return []
        }
        var names: Set<String> = []
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let closeQuote = trimmed.dropFirst().firstIndex(of: "\"") else { continue }
            let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeQuote])
            guard trimmed[trimmed.index(after: closeQuote)...].trimmingCharacters(in: .whitespaces).hasPrefix(":") else { continue }
            names.insert(name)
        }
        return names
    }

    func test_everyPermissionAnExtensionCanActuallyHoldHasInstallWarningText() throws {
        let warned = try permissionWarningNames()
        XCTAssertGreaterThan(warned.count, 20, "parsed only \(warned.count) permission warnings; the literal parse is wrong")

        // "menus" is WebKit's alias for contextMenus; no Chrome manifest names it.
        let holdable = Inventory.wrappedPermissions.union(Inventory.webKitNativePermissions).subtracting(["menus"])
        XCTAssertEqual(
            holdable.subtracting(warned).sorted(), [],
            "an extension installed in Orbit can really hold these -- the wrapper or WebKit acts on them -- and ExtensionPermissionWarnings has no text for any of them. The install sheet falls back to printing the raw permission name, so the user is asked to approve a capability nobody wrote down."
        )
        for name in holdable.sorted() {
            XCTAssertTrue(ExtensionPermissionWarnings.isKnownPermission(name), "\(name) has no install warning in the live catalogue")
        }
    }

    func test_everyPermissionWarningNamesARealChromePermission() throws {
        let known = try Schema.upstreamIndex().knownPermissions
        XCTAssertGreaterThan(known.count, 100, "the vendored permission lists are implausibly short")
        let invented = try permissionWarningNames().subtracting(known).sorted()
        XCTAssertEqual(
            invented, [],
            "ExtensionPermissionWarnings describes permissions upstream Chromium does not define. A typo here is silent: the entry simply never matches a real manifest, and the permission it was meant to describe falls back to its raw name in the install sheet."
        )
    }

    // MARK: - Declared-but-dead events

    func test_everyNeverDispatchedEventIsStillInTheLivenessTable() throws {
        let expected = try Schema.readExpectations()
        XCTAssertFalse(expected.neverDispatchedEvents.isEmpty)
        let table = try Schema.readObject(Schema.eventLivenessFile)
        let events = try XCTUnwrap(table["events"] as? [String: Any])
        XCTAssertEqual(expected.neverDispatchedEvents.filter { events[$0] == nil }, [])
    }

    func test_everyNeverDispatchedEventIsStillAnEventThatExists() throws {
        let session = try wrapperSession()
        for event in try Schema.readExpectations().neverDispatchedEvents {
            let parts = event.split(separator: ".", maxSplits: 1).map(String.init)
            let namespace = try XCTUnwrap(parts.first)
            let name = try XCTUnwrap(parts.last)
            let upstream = try XCTUnwrap(
                try Schema.upstreamSurface(ofNamespace: namespace),
                "\(event) names a namespace with no vendored schema"
            )
            XCTAssertTrue(upstream.events.contains(name), "\(event) is not an event upstream declares")
            XCTAssertTrue(
                Inventory.webKitNativeNamespaces.contains(namespace),
                "\(event) is listed as declared-but-dead in a namespace neither WebKit nor the wrapper provides"
            )
            if let augmentation = Inventory.augmentations.first(where: { $0.namespace == namespace }),
               augmentation.events.contains(name) {
                XCTAssertTrue(
                    session.members(of: namespace)?.events.contains(name) == true,
                    "\(event) is declared by the wrapper's inventory and the generated wrapper does not define it, so a worker registering for it would throw"
                )
            }
        }
    }

    // MARK: -

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
