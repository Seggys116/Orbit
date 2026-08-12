// The anti-subset check: fixture-driven tests can only exercise what their author
// believed exists, so a missing namespace stays invisible. Diffs Orbit's whole declared
// surface against upstream and asserts the delta is exactly ExpectedAPIGaps.json.

import CryptoKit
import XCTest

final class ExtensionSchemaConformanceTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface

    // MARK: - The snapshot is real, current, and unedited

    func test_vendoredUpstreamSnapshotMatchesThePinnedChromiumVersion() throws {
        let index = try Schema.upstreamIndex()
        let pinned = try Schema.pinnedChromiumVersion()
        XCTAssertEqual(
            index.chromiumVersion, pinned,
            "OrbitTests/Fixtures/UpstreamAPISchemas was captured from Chromium \(index.chromiumVersion) but Chromium/chromium-version.json now pins \(pinned). Every gap below is being measured against the wrong upstream. Run `Scripts/extension-schemas sync`, then `Scripts/extension-schemas update-expectations`, and re-triage the diff — a Chromium bump adds and removes API members, and this is the check that forces someone to look."
        )
    }

    func test_vendoredUpstreamSnapshotIsNotEmptyAndCoversEveryNamespaceOrbitPorts() throws {
        let index = try Schema.upstreamIndex()
        XCTAssertGreaterThan(
            index.chromeNamespaces.count, 100,
            "the vendored snapshot lists \(index.chromeNamespaces.count) chrome-layer namespaces; upstream has well over a hundred, so the sync captured nothing and every assertion below would pass vacuously"
        )
        XCTAssertGreaterThan(index.coreNamespaces.count, 40, "core namespace list is implausibly short")

        for (namespace, file) in try Schema.orbitPortedNamespaces() {
            let upstream = try Schema.upstreamSurface(namespace: namespace, file: file)
            XCTAssertFalse(
                upstream == Schema.Surface(),
                "Orbit ports \(namespace) from \(file) but the vendored upstream copy of \(file) declares no members for it. Re-run `Scripts/extension-schemas sync`."
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
                "\(file) no longer matches the hash `Scripts/extension-schemas sync` recorded for it. The vendored copies are upstream's bytes; editing one to make a gap disappear is the one way to defeat this whole suite."
            )
        }
    }

    // MARK: - The diff

    func test_theSchemaGapAgainstUpstreamIsExactlyTheCheckedInExpectation() throws {
        let computed = try Schema.computeGaps()
        let expected = try Schema.readExpectations()

        let computedLines = Schema.lines(for: computed.namespaces)
        let expectedLines = Schema.lines(for: expected.namespaces)

        let regressions = Set(computedLines).subtracting(expectedLines).sorted()
        let wins = Set(expectedLines).subtracting(computedLines).sorted()

        XCTAssertEqual(
            regressions, [],
            "Orbit's API surface lost members that ExpectedAPIGaps.json says it has. Each line is an extension API that silently stopped existing — the exact failure mode this suite was built for. If the loss is deliberate, record it with `Scripts/extension-schemas update-expectations` and say why in the namespace's `note`."
        )
        XCTAssertEqual(
            wins, [],
            "Orbit now IMPLEMENTS members that ExpectedAPIGaps.json still lists as missing. This is a pass-worthy failure: run `Scripts/extension-schemas sync && Scripts/extension-schemas update-expectations` to record the win, and delete any liveness entry in EventLiveness.json that marked a newly-dispatched event as notDispatched."
        )
    }

    func test_everyAbsentNamespaceHasBeenTriaged() throws {
        let expected = try Schema.readExpectations()
        let untriaged = expected.namespaces
            .filter { $0.value.status == "absent" && ($0.value.reason ?? "unclassified") == "unclassified" }
            .keys.sorted()
        XCTAssertEqual(
            untriaged, [],
            "these chrome-layer namespaces are absent from Orbit and nobody has said why. A Chromium bump that introduces a namespace lands it here as `unclassified` on purpose: classify each as notPorted, outOfScope or chromeInternal in OrbitTests/Fixtures/ExpectedAPIGaps.json (or in Scripts/extension_schemas.py's DEFAULT_REASONS) so 'what is still missing' stays a query rather than an investigation."
        )
        let allowedReasons: Set<String> = ["notPorted", "outOfScope", "chromeInternal"]
        for (name, gap) in expected.namespaces where gap.status == "absent" {
            XCTAssertTrue(
                allowedReasons.contains(gap.reason ?? ""),
                "\(name) has reason \"\(gap.reason ?? "")\", which is not one of \(allowedReasons.sorted())"
            )
        }
    }

    func test_theNamespacesTheExpectationsFileNamesStillExistUpstream() throws {
        let index = try Schema.upstreamIndex()
        let expected = try Schema.readExpectations()
        let ported = try Schema.orbitPortedNamespaces()
        let known = index.chromeNamespaces.union(ported.keys)
        let phantom = expected.namespaces.keys.filter { !known.contains($0) }.sorted()
        XCTAssertEqual(
            phantom, [],
            "ExpectedAPIGaps.json records gaps for namespaces upstream Chromium no longer has. They were removed by a Chromium bump and the expectations were never re-synced, so the file is now recording fiction."
        )
    }

    // MARK: - Permissions

    func test_theUnregisteredChromePermissionSetIsExactlyTheCheckedInExpectation() throws {
        let computed = try Schema.computeGaps().unregisteredChromePermissions
        let expected = try Schema.readExpectations().unregisteredChromePermissions

        let newlyUnregistered = Set(computed).subtracting(expected).sorted()
        let newlyRegistered = Set(expected).subtracting(computed).sorted()

        XCTAssertEqual(
            newlyUnregistered, [],
            "these chrome-layer permissions are no longer registered by OrbitExtensionsAPIProvider. Chromium drops an unknown permission from a manifest without an error, so every API feature depending on one resolves to nothing and its whole namespace is undefined at runtime — exactly what happened to chrome.scripting."
        )
        XCTAssertEqual(
            newlyRegistered, [],
            "OrbitExtensionsAPIProvider now registers permissions ExpectedAPIGaps.json still lists as unregistered. Record the win with `Scripts/extension-schemas update-expectations`."
        )
    }

    func test_theTwoPermissionsThatWereSilentlyDroppedAreRegistered() throws {
        let registered = try Schema.registeredPermissionNames()
        XCTAssertTrue(registered.contains("scripting"), "chrome.scripting is undefined in every extension without this")
        XCTAssertTrue(registered.contains("management"), "chrome.management keeps only its three no-permission members without this")
    }

    // MARK: - The ID table and the feature table have to agree

    func test_everyRegisteredPermissionHasAPermissionFeature() throws {
        let registered = try Schema.allRegisteredPermissionNames()
        XCTAssertGreaterThan(registered.count, 60, "read only \(registered.count) registered permissions; the parse is wrong and this assertion is vacuous")

        let undeclared = registered.subtracting(try Schema.declaredPermissionFeatureNames()).sorted()
        XCTAssertEqual(
            undeclared, [],
            "extensions/common/manifest_handlers/permissions_parser.cc DCHECKs `Could not find feature for <name>` when a permission resolves to an APIPermissionInfo and the permission FeatureProvider has nothing for it, so an ordinary manifest naming any of these takes the whole browser process down while it is being parsed — React Developer Tools' \"clipboardWrite\" did. CoreExtensionsAPIProvider registers these unconditionally and //extensions states no feature for them; Chrome covers them from chrome/common/extensions/api/_permission_features.json and Orbit has to cover them from Chromium/Embedder/common/api/_permission_features.json. Copy the pinned Chromium's entry for each — `Scripts/extension-schemas diff` prints the list."
        )
    }

    func test_theChromeLayerEntriesOrbitSuppliesAreVerbatimUpstream() throws {
        let upstream = try Schema.upstreamChromePermissionFeatures()
        let orbit = try Schema.orbitPermissionFeatures()
        let mustCopy = try Schema.permissionsCoreRegistersWithoutAFeature().sorted()
        XCTAssertFalse(mustCopy.isEmpty, "computed no chrome-layer-only permissions at all; the vendored index is not being read")

        for name in mustCopy {
            guard let mine = orbit[name] else { continue }
            guard let theirs = upstream[name] else {
                XCTFail("Orbit declares a permission feature for \(name), which the pinned Chromium's chrome layer does not define at all")
                continue
            }
            XCTAssertEqual(
                Schema.canonicalJSON(mine), Schema.canonicalJSON(theirs),
                "Orbit's permission feature for \(name) is not the one upstream Chromium states. These entries exist so a registered permission cannot DCHECK, not to decide what Orbit grants — an edited channel, platform, location or allowlist here hands an extension a permission Chromium would have withheld, and Orbit implements none of the enforcement that would make it safe. Copy chrome/common/extensions/api/_permission_features.json's entry unchanged."
            )
        }
    }

    func test_orbitDeclaresNoPermissionFeatureForAPermissionNothingRegisters() throws {
        let registered = try Schema.allRegisteredPermissionNames()
        let orphaned = try Schema.orbitPermissionFeatures().keys.filter { !registered.contains($0) }.sorted()
        XCTAssertEqual(
            orphaned, [],
            "Chromium/Embedder/common/api/_permission_features.json states availability for permissions no APIPermissionInfo is registered for, so PermissionsInfo::GetByName never returns one and the entry can never be consulted. Either the name is a typo or the registration in kOrbitPermissionsToRegister was dropped."
        )
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

        let grantable = try Schema.grantablePermissionNames()
        let withheld = try Schema.registeredPermissionNames().subtracting(grantable).sorted()
        XCTAssertEqual(
            withheld, [],
            "OrbitExtensionsAPIProvider registers these so extensions can use the APIs behind them, and their permission feature withholds them from an ordinary stable-channel macOS extension anyway, so every dependent API namespace is undefined at runtime"
        )
        let undescribed = grantable.subtracting(warned).sorted()
        XCTAssertEqual(
            undescribed, [],
            "an extension installed in Orbit can really hold these — they are registered and their permission feature grants them to a stable-channel macOS extension — and ExtensionPermissionWarnings has no text for any of them. The install sheet falls back to printing the raw permission name, so the user is asked to approve a capability nobody wrote down."
        )
    }

    func test_everyPermissionWarningNamesARealChromePermission() throws {
        let index = try Schema.upstreamIndex()
        let known = index.chromePermissions.union(index.corePermissions)
        XCTAssertGreaterThan(known.count, 100, "the vendored permission lists are implausibly short")
        let invented = try permissionWarningNames().subtracting(known).sorted()
        XCTAssertEqual(
            invented, [],
            "ExtensionPermissionWarnings describes permissions upstream Chromium does not define. A typo here is silent: the entry simply never matches a real manifest, and the permission it was meant to describe falls back to its raw name in the install sheet."
        )
    }

    // MARK: - Declared-but-dead events

    func test_everyNeverDispatchedEventIsStillAnEventOrbitDeclares() throws {
        let expected = try Schema.readExpectations()
        let declared = try Schema.orbitDeclaredEvents()
        XCTAssertFalse(declared.isEmpty, "parsed no events out of Orbit's own schemas")
        let phantom = expected.neverDispatchedEvents.filter { !declared.contains($0) }.sorted()
        XCTAssertEqual(
            phantom, [],
            "ExpectedAPIGaps.json's neverDispatchedEvents names events Orbit's schemas no longer declare. Either the event was removed (a regression the schema diff should also be reporting) or it was renamed and this list was not updated."
        )
    }

    // MARK: -

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
