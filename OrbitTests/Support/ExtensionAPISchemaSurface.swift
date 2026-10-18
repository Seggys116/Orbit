// Host-less support for the schema, runtime-surface and permission guards: reads the vendored
// upstream snapshot and the fixtures, and runs the generated chrome wrapper in JavaScriptCore.

import Foundation
import JavaScriptCore
#if canImport(Orbit)
@testable import Orbit
#endif

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

    static let vendoredUpstreamDirectory = repositoryFile("OrbitTests/Fixtures/UpstreamAPISchemas")
    static let expectationsFile = repositoryFile("OrbitTests/Fixtures/ExpectedAPIGaps.json")
    static let eventLivenessFile = repositoryFile("OrbitTests/Fixtures/EventLiveness.json")
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

    /// Only dictionaries and enums are types: the per-event `interface FooEvent`
    /// and its `callback FooListener` are plumbing the compiler never emits.
    static func webidlSurfaces(inSchemaAt url: URL) throws -> [String: Surface] {
        let text = try uncommentedIDL(at: url)
        let nsText = text as NSString
        let whole = NSRange(location: 0, length: nsText.length)

        var bodies: [String: NSRange] = [:]
        var surface = Surface()
        let declaration = try NSRegularExpression(
            pattern: #"\b(dictionary|enum|interface)\s+([A-Za-z0-9_]+)\s*(?::\s*[A-Za-z0-9_]+\s*)?\{"#
        )
        for match in declaration.matches(in: text, range: whole) {
            let kind = nsText.substring(with: match.range(at: 1))
            let name = nsText.substring(with: match.range(at: 2))
            guard kind == "interface" else {
                surface.types.insert(name)
                continue
            }
            bodies[name] = bracedBody(nsText, from: match.range.location + match.range.length)
        }

        let attribute = try NSRegularExpression(
            pattern: #"static\s+attribute\s+([A-Za-z0-9_]+)\s+([A-Za-z0-9_]+)\s*;"#
        )
        guard let browser = bodies["Browser"],
              let binding = attribute.firstMatch(in: text, range: browser)
        else { return [:] }
        let namespace = nsText.substring(with: binding.range(at: 2))
        guard let body = bodies[nsText.substring(with: binding.range(at: 1))] else {
            return [namespace: surface]
        }

        for match in attribute.matches(in: text, range: body) {
            surface.events.insert(nsText.substring(with: match.range(at: 2)))
        }
        let constant = try NSRegularExpression(pattern: #"const\s+[A-Za-z0-9_]+\s+([A-Za-z0-9_]+)\s*="#)
        for match in constant.matches(in: text, range: body) {
            surface.properties.insert(nsText.substring(with: match.range(at: 1)))
        }
        let operation = try NSRegularExpression(pattern: #"static\s+((?:(?!attribute)[^;{}])*?)\("#)
        let trailing = try NSRegularExpression(pattern: #"([A-Za-z0-9_]+)\s*$"#)
        for match in operation.matches(in: text, range: body) {
            let signature = nsText.substring(with: match.range(at: 1))
            let signatureRange = NSRange(location: 0, length: (signature as NSString).length)
            if let name = trailing.firstMatch(in: signature, range: signatureRange) {
                surface.functions.insert((signature as NSString).substring(with: name.range(at: 1)))
            }
        }
        return [namespace: surface]
    }

    private static func bracedBody(_ text: NSString, from start: Int) -> NSRange {
        var depth = 1
        var cursor = start
        while cursor < text.length, depth > 0 {
            let character = text.character(at: cursor)
            if character == 123 { depth += 1 }
            if character == 125 { depth -= 1 }
            cursor += 1
        }
        return NSRange(location: start, length: max(0, cursor - 1 - start))
    }

    private static func uncommentedIDL(at url: URL) throws -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw SchemaError.unreadable(url)
        }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// `callback` declarations are not types: the compiler folds them into the
    /// function's returns_async rather than emitting one.
    static func idlSurfaces(inSchemaAt url: URL) throws -> [String: Surface] {
        let text = try uncommentedIDL(at: url)
        guard let namespace = firstMatch(in: text, pattern: #"(?m)^\s*namespace\s+([A-Za-z0-9_.]+)\s*\{"#) else {
            throw SchemaError.malformed(url, "no namespace declaration")
        }

        var surface = Surface()
        let blocks = try NSRegularExpression(pattern: #"(dictionary|enum|interface)\s+([A-Za-z0-9_]+)\s*\{"#)
        let members = try NSRegularExpression(pattern: #"static\s+[A-Za-z0-9_\[\]?]+\s*\??\s+([A-Za-z0-9_]+)\s*\("#)
        let nsText = text as NSString
        for block in blocks.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let kind = nsText.substring(with: block.range(at: 1))
            let name = nsText.substring(with: block.range(at: 2))
            if kind != "interface" {
                surface.types.insert(name)
                continue
            }
            let bodyStart = block.range.location + block.range.length
            var depth = 1
            var cursor = bodyStart
            while cursor < nsText.length, depth > 0 {
                let character = nsText.character(at: cursor)
                if character == 123 { depth += 1 }
                if character == 125 { depth -= 1 }
                cursor += 1
            }
            let body = NSRange(location: bodyStart, length: max(0, cursor - 1 - bodyStart))
            let names = Set(members.matches(in: text, range: body).map { nsText.substring(with: $0.range(at: 1)) })
            switch name {
            case "Functions": surface.functions.formUnion(names)
            case "Events": surface.events.formUnion(names)
            case "Properties": surface.properties.formUnion(names)
            default: break
            }
        }
        return [namespace: surface]
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))
        else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }

    // MARK: - Permission features

    /// `_permission_features.json` as name -> entry, where an entry is either a
    /// JSON object or a list of them (Chromium's ComplexFeature).
    static func permissionFeatures(at url: URL) throws -> [String: Any] {
        try readObject(url)
    }

    static func upstreamChromePermissionFeatures() throws -> [String: Any] {
        try permissionFeatures(at: upstreamChromePermissionFeaturesFile)
    }

    static func upstreamCorePermissionFeatures() throws -> [String: Any] {
        try permissionFeatures(at: upstreamCorePermissionFeaturesFile)
    }

    /// Both upstream layers' permission features, the chrome layer winning a name both state.
    static func effectivePermissionFeatures() throws -> [String: Any] {
        var features = try upstreamCorePermissionFeatures()
        for (name, value) in try upstreamChromePermissionFeatures() { features[name] = value }
        return features
    }

    /// Whether upstream Chrome lets an ordinary stable-channel macOS extension hold `permission`.
    static func isGrantableToAnOrdinaryExtension(_ permission: String) throws -> Bool {
        let features = try effectivePermissionFeatures()
        guard let value = features[permission] else { return false }
        return featureEntries(value).contains {
            isGrantableToAnOrdinaryExtension(resolvedEntry($0, named: permission, in: features))
        }
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

    /// Errs toward "yes": an unmodelled gate widens the set rather than hiding a permission from coverage.
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

        var knownNamespaces: Set<String> { chromeNamespaces.union(coreNamespaces) }
        var knownPermissions: Set<String> { chromePermissions.union(corePermissions) }
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

    /// The declared surface of `namespace` in the vendored snapshot, or nil when no schema file is vendored for it.
    static func upstreamSurface(ofNamespace namespace: String) throws -> Surface? {
        let names = try FileManager.default.contentsOfDirectory(atPath: vendoredUpstreamDirectory.path)
        for name in names.sorted() where !name.hasPrefix("_") {
            let url = vendoredUpstreamDirectory.appendingPathComponent(name)
            let surfaces: [String: Surface]
            switch url.pathExtension {
            case "json": surfaces = try Self.surfaces(inSchemaAt: url)
            case "idl": surfaces = try idlSurfaces(inSchemaAt: url)
            case "webidl": surfaces = try webidlSurfaces(inSchemaAt: url)
            default: continue
            }
            if let surface = surfaces[namespace] { return surface }
        }
        return nil
    }

    // MARK: - The diff

    /// Types are schema plumbing a runtime object cannot show, so only these are compared.
    static let comparedKinds: [MemberKind] = [.functions, .events, .properties]

    struct NamespaceGap: Equatable {
        var status: String
        var provider: String?
        var reason: String?
        var missing: [MemberKind: [String]] = [:]
        var extra: [MemberKind: [String]] = [:]
        /// Members WebKit's own version decides; the live suite accepts either state.
        var uncertain: [MemberKind: [String]] = [:]
    }

    /// What the generated wrapper defines for every namespace of the inventory that also has a
    /// vendored schema, against that schema. Types are not diffed: a runtime object cannot show them.
    static func computeWrapperGaps(in session: ChromeWrapperRuntime.Session) throws -> [String: NamespaceGap] {
        var paths = ChromeAPISurfaceInventory.namespaces.map(\.name)
        paths.append("privacy")
        var gaps: [String: NamespaceGap] = [:]
        for path in paths {
            guard let upstream = try upstreamSurface(ofNamespace: path) else { continue }
            let runtime = try requireMembers(session, path)
            var gap = NamespaceGap(status: "partial")
            for kind in comparedKinds {
                let provided = runtime.names(ofKind: kind)
                let wanted = upstream.names(ofKind: kind)
                let missing = wanted.subtracting(provided).sorted()
                let extra = provided.subtracting(wanted).sorted()
                if !missing.isEmpty { gap.missing[kind] = missing }
                if !extra.isEmpty { gap.extra[kind] = extra }
            }
            if gap.missing.isEmpty && gap.extra.isEmpty { gap.status = "complete" }
            gaps[path] = gap
        }
        return gaps
    }

    private static func requireMembers(_ session: ChromeWrapperRuntime.Session, _ path: String) throws -> ChromeWrapperRuntime.Members {
        guard let members = session.members(of: path) else {
            throw SchemaError.malformed(vendoredUpstreamDirectory, "the generated wrapper defines no chrome.\(path) with every permission granted")
        }
        return members
    }

    /// Chrome permissions neither the wrapper nor WebKit gives any meaning to.
    static func permissionsWithoutProvider() throws -> [String] {
        try upstreamIndex().knownPermissions
            .subtracting(ChromeAPISurfaceInventory.wrappedPermissions)
            .subtracting(ChromeAPISurfaceInventory.webKitNativePermissions)
            .sorted()
    }

    // MARK: - Expectations

    struct Expectations {
        var engine: String
        var upstreamVersion: String
        var neverDispatchedEvents: [String]
        var namespaces: [String: NamespaceGap]
        var permissionsWithoutProvider: [String]
    }

    static func readExpectations() throws -> Expectations {
        let object = try readObject(expectationsFile)
        guard let engine = object["engine"] as? String else {
            throw SchemaError.malformed(expectationsFile, "missing \"engine\"")
        }
        guard let upstreamVersion = object["upstreamVersion"] as? String else {
            throw SchemaError.malformed(expectationsFile, "missing \"upstreamVersion\"")
        }
        guard let rawNamespaces = object["namespaces"] as? [String: [String: Any]] else {
            throw SchemaError.malformed(expectationsFile, "missing \"namespaces\"")
        }
        var namespaces: [String: NamespaceGap] = [:]
        for (name, raw) in rawNamespaces {
            var gap = NamespaceGap(status: raw["status"] as? String ?? "")
            gap.provider = raw["provider"] as? String
            gap.reason = raw["reason"] as? String
            for kind in MemberKind.allCases {
                if let missing = raw[kind.missingKey] as? [String] { gap.missing[kind] = missing }
                if let extra = raw[kind.extraKey] as? [String] { gap.extra[kind] = extra }
                if let uncertain = raw[kind.uncertainKey] as? [String] { gap.uncertain[kind] = uncertain }
            }
            namespaces[name] = gap
        }
        return Expectations(
            engine: engine,
            upstreamVersion: upstreamVersion,
            neverDispatchedEvents: object["neverDispatchedEvents"] as? [String] ?? [],
            namespaces: namespaces,
            permissionsWithoutProvider: object["permissionsWithoutProvider"] as? [String] ?? []
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
            for kind in comparedKinds {
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

extension ExtensionAPISchemaSurface.MemberKind {
    /// The key this kind takes for members the live suite accepts either way.
    var uncertainKey: String { "uncertain" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

// MARK: - The generated wrapper, run

/// Runs the wrapper exactly as `ChromeAPIWrapperScript.install(in:)` writes it, in JavaScriptCore,
/// over a stand-in `chrome` that models nothing but the namespaces the wrapper extends.
enum ChromeWrapperRuntime {

    struct Members: Equatable {
        var functions: Set<String> = []
        var events: Set<String> = []
        var properties: Set<String> = []
        /// Objects made only of plain values: constants and enum tables, which a schema calls types.
        var enums: Set<String> = []

        func names(ofKind kind: ExtensionAPISchemaSurface.MemberKind) -> Set<String> {
            switch kind {
            case .functions: return functions
            case .events: return events
            case .properties: return properties
            case .types: return enums
            }
        }
    }

    struct GeneratedWrapper {
        var script: String
        var manifest: [String: Any]
    }

    enum RunError: Error, CustomStringConvertible {
        case noContext
        case scriptFailed([String])

        var description: String {
            switch self {
            case .noContext: return "JavaScriptCore could not create a context"
            case .scriptFailed(let failures): return "the wrapper threw while loading: \(failures.joined(separator: "; "))"
            }
        }
    }

    /// Every namespace the wrapper extends exists as an empty object, with the handful of native
    /// functions its own set-up calls. Nothing else is modelled, so everything found afterwards was added by the wrapper.
    static let nativeStub = """
    var __orbitNativeEvent = function () {
      return {
        addListener: function () {}, removeListener: function () {},
        hasListener: function () { return false; }, hasListeners: function () { return false; }
      };
    };
    var __orbitNoop = function () {};
    globalThis.setTimeout = function () { return 0; };
    globalThis.setInterval = function () { return 0; };
    globalThis.clearInterval = function () {};
    globalThis.chrome = {
      runtime: {
        onMessage: __orbitNativeEvent(),
        getURL: function (path) { return "chrome-extension://orbit-surface-probe/" + (path || ""); },
        getManifest: function () { return {}; },
        sendMessage: __orbitNoop
      },
      tabs: { query: __orbitNoop, get: __orbitNoop, reload: __orbitNoop },
      webNavigation: {},
      webRequest: {},
      cookies: { set: __orbitNoop, remove: __orbitNoop },
      permissions: { request: __orbitNoop },
      scripting: {},
      storage: { sync: { set: __orbitNoop }, local: { set: __orbitNoop } },
      commands: {}
    };
    """

    private static let reflection = """
    function __orbitReflect(path) {
      var parts = path.split(".");
      var value = globalThis.chrome;
      for (var i = 0; i < parts.length; i++) {
        if (value === null || value === undefined || typeof value !== "object") { return null; }
        value = value[parts[i]];
      }
      if (value === null || value === undefined || typeof value !== "object") { return null; }
      var report = { functions: [], events: [], properties: [], enums: [] };
      function isEvent(member) {
        return member !== null && typeof member === "object"
          && typeof member.addListener === "function" && typeof member.removeListener === "function"
          && typeof member.hasListener === "function";
      }
      function isPlain(member) { return member === null || (typeof member !== "object" && typeof member !== "function"); }
      function walk(object, prefix, depth) {
        Object.keys(object).forEach(function (key) {
          if (key.indexOf("__orbit") === 0) { return; }
          var member = object[key];
          if (typeof member === "function") { if (depth === 0) { report.functions.push(key); } return; }
          if (isEvent(member)) { if (depth === 0) { report.events.push(key); } return; }
          if (member !== null && typeof member === "object") {
            var keys = Object.keys(member);
            var hasFunction = keys.some(function (name) { return typeof member[name] === "function"; });
            if (hasFunction) {
              report.properties.push(prefix + key);
              keys.forEach(function (name) { if (isPlain(member[name])) { report.properties.push(prefix + key + "." + name); } });
              return;
            }
            if (keys.every(function (name) { return isPlain(member[name]); })) { report.enums.push(prefix + key); return; }
            report.properties.push(prefix + key);
            walk(member, prefix + key + ".", depth + 1);
            return;
          }
          report.properties.push(prefix + key);
        });
      }
      walk(value, "", 0);
      ["functions", "events", "properties", "enums"].forEach(function (name) { report[name].sort(); });
      return JSON.stringify(report);
    }
    """

    final class Session {
        let context: JSContext
        private(set) var failures: [String] = []

        fileprivate init(context: JSContext) {
            self.context = context
            context.exceptionHandler = { [unowned self] _, exception in
                self.failures.append(exception?.toString() ?? "unknown JavaScript exception")
            }
        }

        @discardableResult
        func evaluate(_ source: String) -> JSValue? {
            context.evaluateScript(source)
        }

        func exists(_ path: String) -> Bool {
            members(of: path) != nil
        }

        func members(of path: String) -> Members? {
            guard let value = evaluate("__orbitReflect(\(JavaScriptLiteral.string(path)))"),
                  value.isString,
                  let data = value.toString()?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
            else { return nil }
            return Members(
                functions: Set(object["functions"] ?? []),
                events: Set(object["events"] ?? []),
                properties: Set(object["properties"] ?? []),
                enums: Set(object["enums"] ?? [])
            )
        }

        /// Delivers the grant list Orbit pushes after an optional permission changes.
        func deliverGrants(_ granted: [String]) {
            let list = (try? JSONSerialization.data(withJSONObject: granted)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            evaluate("""
            globalThis.__orbitDeliverChromeEvent({ orbitChromeEvent: true, namespace: "__orbit", event: "grants", args: [\(list)] });
            """)
        }

        func value(of expression: String) -> Any? {
            evaluate(expression)?.toObject()
        }
    }

    /// The wrapper and the manifest as `install(in:)` leaves them, for a manifest declaring these permissions.
    static func generate(
        manifestPermissions: [String],
        optionalPermissions: [String] = [],
        grantedOptional: [String] = [],
        maxSessionResults: Int? = nil
    ) throws -> GeneratedWrapper {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-WrapperSurface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Orbit Wrapper Surface Probe",
            "version": "1.0",
            "permissions": manifestPermissions,
            "optional_permissions": optionalPermissions,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))

        var configuration = ChromeAPIWrapperScript.Configuration()
        configuration.grantedOptionalPermissions = grantedOptional
        if let maxSessionResults { configuration.maxSessionResults = maxSessionResults }
        try ChromeAPIWrapperScript.install(in: directory, configuration: configuration)

        let script = try String(contentsOf: directory.appendingPathComponent(ChromeAPIWrapperScript.fileName), encoding: .utf8)
        let rewritten = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        ) as? [String: Any] ?? [:]
        return GeneratedWrapper(script: script, manifest: rewritten)
    }

    static func start(
        manifestPermissions: [String],
        optionalPermissions: [String] = [],
        grantedOptional: [String] = [],
        maxSessionResults: Int? = nil,
        native: String = nativeStub
    ) throws -> Session {
        let generated = try generate(
            manifestPermissions: manifestPermissions, optionalPermissions: optionalPermissions,
            grantedOptional: grantedOptional, maxSessionResults: maxSessionResults
        )
        guard let context = JSContext() else { throw RunError.noContext }
        let session = Session(context: context)
        session.evaluate(native)
        session.evaluate(reflection)
        session.evaluate(generated.script)
        guard session.failures.isEmpty else { throw RunError.scriptFailed(session.failures) }
        return session
    }

    /// Every permission the wrapper acts on, declared, so every wrapper namespace exists.
    static func startWithEveryWrappedPermission() throws -> Session {
        try start(manifestPermissions: ChromeAPISurfaceInventory.wrappedPermissions.sorted())
    }
}
