// A manifest permission needs both a kOrbitPermissionsToRegister row and a
// _permission_features.json entry; miss either and Chromium silently drops the
// permission and its whole namespace goes undefined at runtime. Host-less.

import XCTest

final class ExtensionPermissionRegistrationGuardTests: XCTestCase {

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func text(at url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(
            text.count, 500,
            "Walked \(text.count) characters of \(url.path). That is far too few — the path resolution is wrong and every check below would pass vacuously."
        )
        return text
    }

    /// The permission names in `kOrbitPermissionsToRegister`, read out of the
    /// C++ literal itself.
    private func registeredPermissionNames() throws -> Set<String> {
        let source = try text(at: repositoryFile("Chromium/Embedder/common/orbit_extensions_api_provider.cc"))
        guard let start = source.range(of: "kOrbitPermissionsToRegister[] = {"),
              let end = source.range(of: "};", range: start.upperBound..<source.endIndex)
        else {
            XCTFail("could not find the kOrbitPermissionsToRegister array literal")
            return []
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        var names: Set<String> = []
        // Each row is {APIPermissionID::kFoo, "foo", flags}; take the string.
        for line in body.split(separator: "\n") {
            guard line.contains("APIPermissionID::") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            guard let openQuote = trimmed.firstIndex(of: "\"") else { continue }
            let afterOpen = trimmed.index(after: openQuote)
            guard let closeQuote = trimmed[afterOpen...].firstIndex(of: "\"") else { continue }
            names.insert(String(trimmed[afterOpen..<closeQuote]))
        }
        return names
    }

    /// Permissions `//extensions` core registers an `APIPermissionID` for on its
    /// own -- CoreExtensionsAPIProvider gives Orbit these unconditionally, so an
    /// entry for one of them here needs no `kOrbitPermissionsToRegister` row.
    /// Read from the vendored upstream snapshot, not ThirdParty/chromium, so this
    /// stays host-less; OrbitTests/ExtensionSchemaConformanceTests keeps it synced
    /// to the pinned Chromium version.
    private func coreRegisteredPermissionNames() throws -> Set<String> {
        let url = repositoryFile("OrbitTests/Fixtures/UpstreamAPISchemas/_index.json")
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let registered = object["core_registered_permissions"] as? [String],
              let internalOnly = object["core_internal_permissions"] as? [String]
        else {
            XCTFail("could not read core_registered_permissions/core_internal_permissions from \(url.path)")
            return []
        }
        // kFlagInternal permissions are dropped by APIPermissionSet::ParseFromJSON
        // before the feature lookup, so they need no feature entry either.
        return Set(registered).subtracting(internalOnly)
    }

    /// The keys of `_permission_features.json`, which is JSON with // comments.
    private func permissionFeatureNames() throws -> Set<String> {
        let source = try text(at: repositoryFile("Chromium/Embedder/common/api/_permission_features.json"))
        var names: Set<String> = []
        var depth = 0
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            if depth == 1, let openQuote = line.firstIndex(of: "\"") {
                let afterOpen = line.index(after: openQuote)
                if let closeQuote = line[afterOpen...].firstIndex(of: "\""),
                   line[line.index(after: closeQuote)...].trimmingCharacters(in: .whitespaces).hasPrefix(":") {
                    names.insert(String(line[afterOpen..<closeQuote]))
                }
            }
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count
        }
        return names
    }

    func test_everyPermissionFeatureEntryHasAMatchingNameToIDRegistration() throws {
        let registered = try registeredPermissionNames().union(try coreRegisteredPermissionNames())
        let features = try permissionFeatureNames()
        XCTAssertFalse(features.isEmpty, "parsed no permission feature entries")

        let unregistered = features.subtracting(registered).sorted()
        XCTAssertEqual(
            unregistered, [],
            "_permission_features.json declares \(unregistered) but neither OrbitExtensionsAPIProvider::RegisterPermissions nor //extensions core's own permissions_to_register maps those names to an APIPermissionID. Chromium drops an unknown permission from the manifest without an error, so every API feature depending on it resolves to nothing and its whole namespace is undefined at runtime."
        )
    }

    func test_everyRegisteredPermissionHasAMatchingFeatureAvailabilityEntry() throws {
        let registered = try registeredPermissionNames()
        let features = try permissionFeatureNames()
        XCTAssertFalse(registered.isEmpty, "parsed no registered permissions")

        let unavailable = registered.subtracting(features).sorted()
        XCTAssertEqual(
            unavailable, [],
            "OrbitExtensionsAPIProvider::RegisterPermissions registers \(unavailable) but _permission_features.json names no context that may request them, so no manifest can actually declare them."
        )
    }

    /// The two permissions this guard was written for. Named explicitly so
    /// that deleting either registration fails by name, not just as a set
    /// difference somewhere in the two tests above.
    func test_scriptingAndManagementAreRegistered() throws {
        let registered = try registeredPermissionNames()
        XCTAssertTrue(
            registered.contains("scripting"),
            "without this, chrome.scripting — executeScript, insertCSS, removeCSS and the content-script registration functions — is undefined in every extension"
        )
        XCTAssertTrue(
            registered.contains("management"),
            "without this, chrome.management keeps only getSelf, uninstallSelf and getPermissionWarningsByManifest"
        )
    }
}
