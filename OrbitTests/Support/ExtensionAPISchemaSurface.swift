// Independent, second implementation of Scripts/extension_schemas.py: a bug shared by
// both would have to be written twice. Host-less -- reads only files in this repo.

import Foundation

enum ExtensionAPISchemaSurface {

    // MARK: - Repository layout

    /// The repository root, from this file's own location.
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func repositoryFile(_ relativePath: String) -> URL {
        repositoryRoot.appendingPathComponent(relativePath)
    }

    static let orbitSchemaDirectory = repositoryFile("Chromium/Embedder/common/api")
    static let vendoredUpstreamDirectory = repositoryFile("OrbitTests/Fixtures/UpstreamAPISchemas")
    static let expectationsFile = repositoryFile("OrbitTests/Fixtures/ExpectedAPIGaps.json")
    static let eventLivenessFile = repositoryFile("OrbitTests/Fixtures/EventLiveness.json")
    static let chromiumVersionFile = repositoryFile("Chromium/chromium-version.json")
    static let apiProviderFile = repositoryFile("Chromium/Embedder/common/orbit_extensions_api_provider.cc")
    static let orbitPermissionFeaturesFile = orbitSchemaDirectory.appendingPathComponent("_permission_features.json")
    static let upstreamChromePermissionFeaturesFile = vendoredUpstreamDirectory
        .appendingPathComponent("_chrome_permission_features.json")
    static let upstreamCorePermissionFeaturesFile = vendoredUpstreamDirectory
        .appendingPathComponent("_core_permission_features.json")

    enum SchemaError: Error, CustomStringConvertible {
        case unreadable(URL)
        case malformed(URL, String)

        var description: String {
            switch self {
            case .unreadable(let url):
                return "could not read \(url.path)"
            case .malformed(let url, let detail):
                return "\(url.path) is not the JSON this test expects: \(detail)"
            }
        }
    }

    // MARK: - JSON with // comments

    /// Chromium's schema files are JSON with C++ line comments, which
    /// JSONSerialization rejects. Strips them without touching string bodies,
    /// so a `//` inside a description survives.
    static func strippingLineComments(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var inString = false
        var iterator = text.startIndex
        while iterator < text.endIndex {
            let character = text[iterator]
            if inString {
                output.append(character)
                if character == "\\" {
                    let next = text.index(after: iterator)
                    if next < text.endIndex {
                        output.append(text[next])
                        iterator = text.index(after: next)
                        continue
                    }
                } else if character == "\"" {
                    inString = false
                }
                iterator = text.index(after: iterator)
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                iterator = text.index(after: iterator)
                continue
            }
            if character == "/" {
                let next = text.index(after: iterator)
                if next < text.endIndex, text[next] == "/" {
                    while iterator < text.endIndex, text[iterator] != "\n" {
                        iterator = text.index(after: iterator)
                    }
                    continue
                }
            }
            output.append(character)
            iterator = text.index(after: iterator)
        }
        return output
    }

    static func readJSON(_ url: URL) throws -> Any {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SchemaError.unreadable(url)
        }
        let data = Data(strippingLineComments(text).utf8)
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw SchemaError.malformed(url, String(describing: error))
        }
    }

    static func readObject(_ url: URL) throws -> [String: Any] {
        guard let object = try readJSON(url) as? [String: Any] else {
            throw SchemaError.malformed(url, "expected a JSON object at the top level")
        }
        return object
    }

    // MARK: - Member surface

    struct Surface: Equatable {
        var functions: Set<String> = []
        var events: Set<String> = []
        var types: Set<String> = []
        var properties: Set<String> = []

        func names(ofKind kind: MemberKind) -> Set<String> {
            switch kind {
            case .functions: return functions
            case .events: return events
            case .types: return types
            case .properties: return properties
            }
        }
    }

    enum MemberKind: String, CaseIterable {
        case functions, events, types, properties

        /// The key this kind takes in ExpectedAPIGaps.json.
        var missingKey: String { "missing" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        var extraKey: String { "extra" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        var singular: String { rawValue == "properties" ? "property" : String(rawValue.dropLast()) }
    }

    /// Nested property groups flattened to dotted paths, because the missing
    /// GROUP is what throws a TypeError, not the missing leaf -- see
    /// EXTENSION_CONFORMANCE.md section 1.3 on chrome.privacy.websites.
    private static func propertyPaths(_ properties: [String: Any]?, prefix: String = "") -> Set<String> {
        var paths: Set<String> = []
        for (key, value) in properties ?? [:] {
            paths.insert(prefix + key)
            if let object = value as? [String: Any], let nested = object["properties"] as? [String: Any] {
                paths.formUnion(propertyPaths(nested, prefix: prefix + key + "."))
            }
        }
        return paths
    }

    /// namespace -> Surface for one schema file.
    static func surfaces(inSchemaAt url: URL) throws -> [String: Surface] {
        let parsed = try readJSON(url)
        let entries: [[String: Any]]
        if let list = parsed as? [[String: Any]] {
            entries = list
        } else if let object = parsed as? [String: Any] {
            entries = [object]
        } else {
            throw SchemaError.malformed(url, "expected a list of namespace objects")
        }
        var result: [String: Surface] = [:]
        for entry in entries {
            guard let namespace = entry["namespace"] as? String else { continue }
            var surface = Surface()
            for function in entry["functions"] as? [[String: Any]] ?? [] {
                if let name = function["name"] as? String { surface.functions.insert(name) }
            }
            for event in entry["events"] as? [[String: Any]] ?? [] {
                if let name = event["name"] as? String { surface.events.insert(name) }
            }
            for type in entry["types"] as? [[String: Any]] ?? [] {
                if let identifier = type["id"] as? String { surface.types.insert(identifier) }
            }
            surface.properties = propertyPaths(entry["properties"] as? [String: Any])
            result[namespace] = surface
        }
        return result
    }

    /// Every namespace Orbit's embedder declares, with the file it came from.
    static func orbitPortedNamespaces() throws -> [String: String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: orbitSchemaDirectory.path)
        var ported: [String: String] = [:]
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix("_") {
            for namespace in try surfaces(inSchemaAt: orbitSchemaDirectory.appendingPathComponent(name)).keys {
                ported[namespace] = name
            }
        }
        return ported
    }

    static func orbitSurface(namespace: String, file: String) throws -> Surface {
        try surfaces(inSchemaAt: orbitSchemaDirectory.appendingPathComponent(file))[namespace] ?? Surface()
    }

    static func upstreamSurface(namespace: String, file: String) throws -> Surface {
        try surfaces(inSchemaAt: vendoredUpstreamDirectory.appendingPathComponent(file))[namespace] ?? Surface()
    }

    /// Every event Orbit declares, as "namespace.eventName".
    static func orbitDeclaredEvents() throws -> Set<String> {
        var events: Set<String> = []
        for (namespace, file) in try orbitPortedNamespaces() {
            for event in try orbitSurface(namespace: namespace, file: file).events {
                events.insert("\(namespace).\(event)")
            }
        }
        return events
    }

    // MARK: - Permissions

    /// The permission names in `kOrbitPermissionsToRegister`, read out of the
    /// C++ literal itself.
    static func registeredPermissionNames() throws -> Set<String> {
        guard let source = try? String(contentsOf: apiProviderFile, encoding: .utf8) else {
            throw SchemaError.unreadable(apiProviderFile)
        }
        guard let start = source.range(of: "kOrbitPermissionsToRegister[] = {"),
              let end = source.range(of: "};", range: start.upperBound..<source.endIndex)
        else {
            throw SchemaError.malformed(apiProviderFile, "no kOrbitPermissionsToRegister array literal")
        }
        var names: Set<String> = []
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            guard line.contains("APIPermissionID::") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let openQuote = trimmed.firstIndex(of: "\"") else { continue }
            let afterOpen = trimmed.index(after: openQuote)
            guard let closeQuote = trimmed[afterOpen...].firstIndex(of: "\"") else { continue }
            names.insert(String(trimmed[afterOpen..<closeQuote]))
        }
        return names
    }

    // MARK: - Permission features

    /// `_permission_features.json` as name -> entry, where an entry is either a
    /// JSON object or a list of them (Chromium's ComplexFeature).
    static func permissionFeatures(at url: URL) throws -> [String: Any] {
        try readObject(url)
    }

    static func orbitPermissionFeatures() throws -> [String: Any] {
        try permissionFeatures(at: orbitPermissionFeaturesFile)
    }

    static func upstreamChromePermissionFeatures() throws -> [String: Any] {
        try permissionFeatures(at: upstreamChromePermissionFeaturesFile)
    }

    static func upstreamCorePermissionFeatures() throws -> [String: Any] {
        try permissionFeatures(at: upstreamCorePermissionFeaturesFile)
    }

    /// Every permission feature an Orbit build answers with, in provider order:
    /// `CoreExtensionsAPIProvider` first, `OrbitExtensionsAPIProvider` after it.
    static func effectivePermissionFeatures() throws -> [String: Any] {
        var features = try upstreamCorePermissionFeatures()
        for (name, value) in try orbitPermissionFeatures() { features[name] = value }
        return features
    }

    /// Permissions Chromium resolves to an `APIPermissionInfo`: `//extensions` core's
    /// table plus `kOrbitPermissionsToRegister`, minus ones `ParseFromJSON` refuses.
    static func allRegisteredPermissionNames() throws -> Set<String> {
        let index = try upstreamIndex()
        return index.coreRegisteredPermissions
            .union(try registeredPermissionNames())
            .subtracting(index.coreInternalPermissions)
    }

    /// Every name the permission FeatureProvider answers for in an Orbit build.
    static func declaredPermissionFeatureNames() throws -> Set<String> {
        try upstreamIndex().corePermissions.union(try orbitPermissionFeatures().keys)
    }

    /// The chrome-layer entries Orbit has to supply itself: registered by
    /// `CoreExtensionsAPIProvider`, stated by no core feature.
    static func permissionsCoreRegistersWithoutAFeature() throws -> Set<String> {
        let index = try upstreamIndex()
        return index.coreRegisteredPermissions
            .subtracting(index.coreInternalPermissions)
            .subtracting(index.corePermissions)
    }

    /// A JSON value rendered so two of them can be compared and printed. Object
    /// key order is normalised; list order is not, because a feature's
    /// `extension_types` and `allowlist` are ordered upstream data.
    static func canonicalJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func featureEntries(_ value: Any) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let object = value as? [String: Any] { return [object] }
        return []
    }

    /// A child feature ("fileSystem.write") inherits its parent's values and
    /// then overrides them, so it cannot be judged on its own body -- an empty
    /// `{}` child is exactly as restricted as its parent.
    private static func resolvedEntry(
        _ entry: [String: Any], named name: String, in features: [String: Any]
    ) -> [String: Any] {
        guard entry["noparent"] == nil, let separator = name.lastIndex(of: ".") else { return entry }
        var merged = defaultEntry(forFeature: String(name[name.startIndex..<separator]), in: features)
        merged["default_parent"] = nil
        for (key, value) in entry { merged[key] = value }
        return merged
    }

    private static func defaultEntry(forFeature name: String, in features: [String: Any]) -> [String: Any] {
        guard let value = features[name] else { return [:] }
        let entries = featureEntries(value)
        let chosen = entries.first { $0["default_parent"] as? Bool == true } ?? entries.first
        guard let chosen else { return [:] }
        return resolvedEntry(chosen, named: name, in: features)
    }

    /// Whether an ordinary extension can hold this permission. Errs toward "yes": an
    /// unmodelled gate widens the set rather than hiding a permission from coverage.
    private static func isGrantableToAnOrdinaryExtension(_ entry: [String: Any]) -> Bool {
        if let channel = entry["channel"] as? String, channel != "stable" { return false }
        if let platforms = entry["platforms"] as? [String], !platforms.contains("mac") { return false }
        if let types = entry["extension_types"] as? [String], !types.contains("extension") { return false }
        if let allowlist = entry["allowlist"] as? [String], !allowlist.isEmpty { return false }
        if let location = entry["location"] as? String, location != "unpacked" { return false }
        if let minimum = entry["min_manifest_version"] as? Int, minimum > 3 { return false }
        if let sessions = entry["session_types"] as? [String], !sessions.contains("regular") { return false }
        if entry["feature_flag"] != nil || entry["command_line_switch"] != nil { return false }
        if entry["developer_mode_only"] as? Bool == true { return false }
        if entry["requires_delegated_availability_check"] as? Bool == true { return false }
        if entry["internal"] as? Bool == true { return false }
        return true
    }

    /// The permissions an extension installed in Orbit can really end up
    /// holding: registered, and with a feature that grants them to it.
    static func grantablePermissionNames() throws -> Set<String> {
        let features = try effectivePermissionFeatures()
        var granted: Set<String> = []
        for name in try allRegisteredPermissionNames() {
            guard let value = features[name] else { continue }
            let grantable = featureEntries(value).contains {
                isGrantableToAnOrdinaryExtension(resolvedEntry($0, named: name, in: features))
            }
            if grantable { granted.insert(name) }
        }
        return granted
    }

    // MARK: - Vendored snapshot

    struct UpstreamIndex {
        var chromiumVersion: String
        var chromeNamespaces: Set<String>
        var coreNamespaces: Set<String>
        var chromePermissions: Set<String>
        var corePermissions: Set<String>
        var coreRegisteredPermissions: Set<String>
        var coreInternalPermissions: Set<String>
        var schemaSHA256: [String: String]
    }

    static func upstreamIndex() throws -> UpstreamIndex {
        let url = vendoredUpstreamDirectory.appendingPathComponent("_index.json")
        let object = try readObject(url)
        func strings(_ key: String) throws -> Set<String> {
            guard let list = object[key] as? [String] else {
                throw SchemaError.malformed(url, "missing string list \"\(key)\"")
            }
            return Set(list)
        }
        guard let version = object["chromium_version"] as? String else {
            throw SchemaError.malformed(url, "missing \"chromium_version\"")
        }
        return UpstreamIndex(
            chromiumVersion: version,
            chromeNamespaces: try strings("chrome_namespaces"),
            coreNamespaces: try strings("core_namespaces"),
            chromePermissions: try strings("chrome_permissions"),
            corePermissions: try strings("core_permissions"),
            coreRegisteredPermissions: try strings("core_registered_permissions"),
            coreInternalPermissions: try strings("core_internal_permissions"),
            schemaSHA256: object["schema_sha256"] as? [String: String] ?? [:]
        )
    }

    static func pinnedChromiumVersion() throws -> String {
        guard let version = try readObject(chromiumVersionFile)["chromium_version"] as? String else {
            throw SchemaError.malformed(chromiumVersionFile, "missing \"chromium_version\"")
        }
        return version
    }

    // MARK: - The diff

    struct NamespaceGap: Equatable {
        var status: String
        var reason: String?
        var missing: [MemberKind: [String]] = [:]
        var extra: [MemberKind: [String]] = [:]
    }

    struct Gaps: Equatable {
        var namespaces: [String: NamespaceGap]
        var unregisteredChromePermissions: [String]
    }

    /// Orbit's surface, diffed against the vendored upstream snapshot. Core
    /// `//extensions` namespaces cancel out: both Orbit and Chrome compile the
    /// same ones, so a difference there would not be an Orbit gap.
    static func computeGaps() throws -> Gaps {
        let index = try upstreamIndex()
        let ported = try orbitPortedNamespaces()

        var namespaces: [String: NamespaceGap] = [:]
        for name in index.chromeNamespaces.subtracting(index.coreNamespaces).subtracting(ported.keys) {
            namespaces[name] = NamespaceGap(status: "absent")
        }

        for (namespace, file) in ported {
            let upstream = try upstreamSurface(namespace: namespace, file: file)
            let orbit = try orbitSurface(namespace: namespace, file: file)
            var gap = NamespaceGap(status: "partial")
            for kind in MemberKind.allCases {
                let missing = upstream.names(ofKind: kind).subtracting(orbit.names(ofKind: kind)).sorted()
                let extra = orbit.names(ofKind: kind).subtracting(upstream.names(ofKind: kind)).sorted()
                if !missing.isEmpty { gap.missing[kind] = missing }
                if !extra.isEmpty { gap.extra[kind] = extra }
            }
            if gap.missing.isEmpty && gap.extra.isEmpty { gap.status = "complete" }
            namespaces[namespace] = gap
        }

        let permissions = index.chromePermissions
            .subtracting(index.corePermissions)
            .subtracting(try registeredPermissionNames())
            .sorted()
        return Gaps(namespaces: namespaces, unregisteredChromePermissions: permissions)
    }

    // MARK: - Expectations

    struct Expectations {
        var chromiumVersion: String
        var neverDispatchedEvents: [String]
        var namespaces: [String: NamespaceGap]
        var unregisteredChromePermissions: [String]
    }

    static func readExpectations() throws -> Expectations {
        let object = try readObject(expectationsFile)
        guard let version = object["chromium_version"] as? String else {
            throw SchemaError.malformed(expectationsFile, "missing \"chromium_version\"")
        }
        guard let rawNamespaces = object["namespaces"] as? [String: [String: Any]] else {
            throw SchemaError.malformed(expectationsFile, "missing \"namespaces\"")
        }
        var namespaces: [String: NamespaceGap] = [:]
        for (name, raw) in rawNamespaces {
            var gap = NamespaceGap(status: raw["status"] as? String ?? "")
            gap.reason = raw["reason"] as? String
            for kind in MemberKind.allCases {
                if let missing = raw[kind.missingKey] as? [String] { gap.missing[kind] = missing }
                if let extra = raw[kind.extraKey] as? [String] { gap.extra[kind] = extra }
            }
            namespaces[name] = gap
        }
        return Expectations(
            chromiumVersion: version,
            neverDispatchedEvents: object["neverDispatchedEvents"] as? [String] ?? [],
            namespaces: namespaces,
            unregisteredChromePermissions: object["unregisteredChromePermissions"] as? [String] ?? []
        )
    }

    /// A stable one-line-per-member rendering, so an XCTAssertEqual failure
    /// prints the exact members that moved rather than two opaque dictionaries.
    static func lines(for namespaces: [String: NamespaceGap]) -> [String] {
        var lines: [String] = []
        for (name, gap) in namespaces.sorted(by: { $0.key < $1.key }) {
            if gap.status == "absent" {
                lines.append("\(name): namespace absent")
                continue
            }
            for kind in MemberKind.allCases {
                for member in gap.missing[kind] ?? [] {
                    lines.append("\(name).\(member) (\(kind.singular)) missing")
                }
                for member in gap.extra[kind] ?? [] {
                    lines.append("\(name).\(member) (\(kind.singular)) Orbit-only")
                }
            }
        }
        return lines
    }
}
