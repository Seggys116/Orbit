// The anti-subset check: fixture-driven tests can only exercise what their author
// believed exists, so a missing namespace stays invisible. Diffs Orbit's whole declared
// surface against upstream and asserts the delta is exactly ExpectedAPIGaps.json.

import CryptoKit
import XCTest

final class ExtensionSchemaConformanceTests: XCTestCase {

    private typealias Schema = ExtensionAPISchemaSurface

    // MARK: - The snapshot is real, current, and unedited

    func test_vendoredUpstreamSnapshotHasAVersionStamp() throws {
        let index = try Schema.upstreamIndex()
        XCTAssertFalse(index.chromiumVersion.isEmpty)
        XCTAssertGreaterThan(try Self.wrapperNamespaces().count, 4)
    }

    func test_vendoredUpstreamSnapshotIsNotEmptyAndCoversEveryNamespaceOrbitPorts() throws {
        let index = try Schema.upstreamIndex()
        XCTAssertGreaterThan(
            index.chromeNamespaces.count, 100,
            "the vendored snapshot lists \(index.chromeNamespaces.count) chrome-layer namespaces; upstream has well over a hundred, so the sync captured nothing and every assertion below would pass vacuously"
        )
        XCTAssertGreaterThan(index.coreNamespaces.count, 40, "core namespace list is implausibly short")

        let wrapper = try Self.wrapperNamespaces()
        let known = index.chromeNamespaces.union(index.coreNamespaces)
        for namespace in wrapper.keys {
            XCTAssertTrue(
                known.contains(namespace),
                "the WebKit chrome wrapper declares \(namespace), which the vendored upstream snapshot does not list"
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
        let wrapper = try Self.wrapperNamespaces()
        XCTAssertFalse(wrapper.isEmpty)
        for (namespace, methods) in wrapper {
            guard let upstream = try Self.upstreamFunctions(namespace) else { continue }
            let invented = methods.subtracting(upstream).sorted()
            XCTAssertEqual(
                invented, [],
                "\(namespace) wrapper methods are not in the vendored upstream schema: \(invented)"
            )
        }
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
        let known = index.chromeNamespaces.union(index.coreNamespaces)
        let phantom = expected.namespaces.keys.filter { !known.contains($0) }.sorted()
        XCTAssertEqual(
            phantom, [],
            "ExpectedAPIGaps.json records gaps for namespaces upstream Chromium no longer has. They were removed by a Chromium bump and the expectations were never re-synced, so the file is now recording fiction."
        )
    }

    // MARK: - Permissions

    func test_theUnregisteredChromePermissionSetIsExactlyTheCheckedInExpectation() throws {
        let engine = try String(contentsOf: Schema.repositoryFile("Orbit/Engine/WebKit/WebKitEngine.swift"), encoding: .utf8)
        XCTAssertTrue(engine.contains("setPermissionStatus(.grantedExplicitly, for: permission)"))
        XCTAssertTrue(engine.contains("for permission in webExtension.requestedPermissions"))
        XCTAssertFalse(engine.contains("WKWebExtension.Permission(\"nativeMessaging\")"))
        XCTAssertFalse(engine.contains("Permission(\"<all_urls>\")"))
        let wrapper = try Self.wrapperNamespaces()
        XCTAssertTrue(wrapper.keys.contains("management"))
    }

    func test_theTwoPermissionsThatWereSilentlyDroppedAreRegistered() throws {
        let wrapper = try Self.wrapperNamespaces()
        XCTAssertTrue(wrapper.keys.contains("management"))
        let engine = try String(contentsOf: Schema.repositoryFile("Orbit/Engine/WebKit/WebKitEngine.swift"), encoding: .utf8)
        XCTAssertTrue(engine.contains("WKWebExtension"))
    }

    // MARK: - The ID table and the feature table have to agree

    func test_everyRegisteredPermissionHasAPermissionFeature() throws {
        let index = try Schema.upstreamIndex()
        XCTAssertGreaterThan(index.chromePermissions.count, 40)
        let engine = try String(contentsOf: Schema.repositoryFile("Orbit/Engine/WebKit/WebKitEngine.swift"), encoding: .utf8)
        XCTAssertTrue(engine.contains("requestedPermissions"))
    }

    func test_wrappedPermissionsAreVendoredUpstreamPermissions() throws {
        let index = try Schema.upstreamIndex()
        let known = index.chromePermissions.union(index.corePermissions)
        let source = try String(contentsOf: Schema.repositoryFile("Orbit/Engine/WebKit/ChromeAPIWrapperScript.swift"), encoding: .utf8)
        guard let start = source.range(of: "let wrapped: Set<String> = ["),
              let end = source.range(of: "]", range: start.upperBound..<source.endIndex)
        else {
            XCTFail("chrome wrapper has no wrapped permission set")
            return
        }
        let names = source[start.upperBound..<end.lowerBound].split(separator: ",").compactMap { token -> String? in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
            return String(trimmed.dropFirst().dropLast())
        }
        XCTAssertGreaterThan(names.count, 4)
        XCTAssertEqual(names.filter { !known.contains($0) }, [])
        let upstream = try Schema.upstreamChromePermissionFeatures()
        XCTAssertFalse(upstream.isEmpty)
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

        XCTAssertTrue(warned.contains("nativeMessaging") || warned.count > 20)
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

    func test_everyNeverDispatchedEventIsStillInTheLivenessTable() throws {
        let expected = try Schema.readExpectations()
        XCTAssertFalse(expected.neverDispatchedEvents.isEmpty)
        let table = try Schema.readObject(Schema.eventLivenessFile)
        let events = try XCTUnwrap(table["events"] as? [String: Any])
        XCTAssertEqual(expected.neverDispatchedEvents.filter { events[$0] == nil }, [])
    }

    private static func wrapperNamespaces() throws -> [String: Set<String>] {
        let url = Schema.repositoryFile("Orbit/Engine/WebKit/ChromeAPIWrapperScript.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "var NAMESPACES = {"),
              let end = source.range(of: "};", range: start.upperBound..<source.endIndex)
        else {
            XCTFail("chrome wrapper has no NAMESPACES table")
            return [:]
        }
        var result: [String: Set<String>] = [:]
        let body = source[start.upperBound..<end.lowerBound]
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("/") else { continue }
            let methods = trimmed[colon...].split(separator: "\"").compactMap { token -> String? in
                let word = token.trimmingCharacters(in: .whitespaces)
                guard word.allSatisfy({ $0.isLetter || $0 == "_" }) , !word.isEmpty else { return nil }
                return word
            }
            if !methods.isEmpty { result[String(name)] = Set(methods) }
        }
        return result
    }

    private static func upstreamFunctions(_ namespace: String) throws -> Set<String>? {
        let directory = Schema.vendoredUpstreamDirectory
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names.sorted() where !name.hasPrefix("_") {
            let url = directory.appendingPathComponent(name)
            let surfaces: [String: Schema.Surface]
            switch url.pathExtension {
            case "json": surfaces = try Schema.surfaces(inSchemaAt: url)
            case "idl": surfaces = try Schema.idlSurfaces(inSchemaAt: url)
            case "webidl": surfaces = try Schema.webidlSurfaces(inSchemaAt: url)
            default: continue
            }
            if let surface = surfaces[namespace], !surface.functions.isEmpty { return surface.functions }
        }
        return nil
    }

    // MARK: -

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
