// Foundation-only (no AppKit, SwiftUI or WebKit) so it compiles into the unit test bundle.

import Foundation

enum OrbitApplicationLogic {


    struct StorageEntry: Identifiable, Equatable {
        var key: String
        var value: String
        var id: String { key }
        var size: Int { key.utf8.count + value.utf8.count }
    }


    struct CookieRecord: Identifiable, Equatable {
        var id: String
        var name: String
        var value: String
        var domain: String
        var path: String
        var expiresDate: Date?
        var isHTTPOnly: Bool
        var isSecure: Bool
        var sameSite: String
        var partitionKey: String
        var priority: String

        var size: Int { (name + "=" + value).utf8.count }
        var isSession: Bool { expiresDate == nil }
    }

    static func cookieRecord(from cookie: HTTPCookie) -> CookieRecord {
        let sameSite: String
        if let policy = cookie.sameSitePolicy {
            if policy == .sameSiteLax { sameSite = "Lax" }
            else if policy == .sameSiteStrict { sameSite = "Strict" }
            else { sameSite = policy.rawValue }
        } else {
            sameSite = ""
        }
        return CookieRecord(
            id: "\(cookie.name)|\(cookie.domain)|\(cookie.path)",
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path.isEmpty ? "/" : cookie.path,
            expiresDate: cookie.expiresDate,
            isHTTPOnly: cookie.isHTTPOnly,
            isSecure: cookie.isSecure,
            sameSite: sameSite,
            partitionKey: "",
            priority: ""
        )
    }

    /// HttpOnly cannot be set through the public Foundation API, so cookies built here never carry it.
    static func httpCookie(from record: CookieRecord) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: record.name,
            .value: record.value,
            .domain: record.domain,
            .path: record.path.isEmpty ? "/" : record.path,
        ]
        if record.isSecure { props[.secure] = "TRUE" }
        if let exp = record.expiresDate { props[.expires] = exp }
        switch record.sameSite {
        case "Lax":    props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case "Strict": props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case "None":   props[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: "none")
        default: break
        }
        return HTTPCookie(properties: props)
    }


    static func cookie(_ record: CookieRecord, matchesURL url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = record.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        if record.isSecure, url.scheme?.lowercased() != "https" { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(record.path)
    }

    /// Simple eTLD+1: the last two dotted components of a hostname.
    static func registrableDomain(of host: String) -> String {
        let clean = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let parts = clean.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return clean }
        return parts.suffix(2).joined(separator: ".")
    }


    enum ValueKind { case plainText, json, urlEncoded, base64 }

    static func detectValueKind(_ value: String) -> ValueKind {
        guard !value.isEmpty else { return .plainText }
        if value.first == "{" || value.first == "[" {
            if let data = value.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return .json
            }
        }
        if value.contains("%"),
           let decoded = value.removingPercentEncoding, decoded != value {
            return .urlEncoded
        }
        if value.count >= 16, value.count % 4 == 0 {
            let base64Chars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
            if value.unicodeScalars.allSatisfy({ base64Chars.contains($0) }),
               Data(base64Encoded: value) != nil {
                return .base64
            }
        }
        return .plainText
    }

    static func prettyJSON(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              // data(withJSONObject:) raises an uncatchable exception for anything but an array or dictionary.
              JSONSerialization.isValidJSONObject(obj),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let text = String(data: pretty, encoding: .utf8) else { return nil }
        return text
    }

    static func urlDecoded(_ value: String) -> String {
        (value.removingPercentEncoding ?? value).replacingOccurrences(of: "+", with: " ")
    }

    static func base64Decoded(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8) ?? "[\(data.count) bytes, not UTF-8]"
    }


    static func formatBytes(_ count: Int) -> String { OrbitDevToolsFormat.bytes(count) }

    static func quotaFraction(usage: Int, quota: Int) -> Double {
        guard quota > 0 else { return 0 }
        return min(1.0, Double(usage) / Double(quota))
    }

    static func formatCookieExpiry(_ date: Date?) -> String {
        guard let date else { return "Session" }
        if date < Date() { return "Expired" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - IDB key range

    struct IDBKeyRange: Equatable {
        enum Bound: Equatable {
            case none, string(String), number(Double)
        }
        var lower: Bound = .none
        var lowerOpen = false
        var upper: Bound = .none
        var upperOpen = false

        var isEmpty: Bool {
            if case .none = lower, case .none = upper { return true }
            return false
        }
    }

    /// Parse a user-entered key range. Formats: empty, single value, "a .. b".
    static func parseIDBKeyRange(_ text: String) -> IDBKeyRange? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return IDBKeyRange() }
        if t.contains("..") {
            let parts = t.components(separatedBy: "..").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            return IDBKeyRange(lower: .string(parts[0]), lowerOpen: false,
                               upper: .string(parts[1]), upperOpen: false)
        }
        return IDBKeyRange(lower: .string(t), lowerOpen: false, upper: .none, upperOpen: false)
    }

    /// Produce the JavaScript IDBKeyRange expression for a range, or "null" for no range.
    static func idbKeyRangeJS(_ range: IDBKeyRange) -> String {
        guard !range.isEmpty else { return "null" }
        func js(_ bound: IDBKeyRange.Bound) -> String {
            switch bound {
            case .none: return "null"
            case .string(let s):
                let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            case .number(let n):
                return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
            }
        }
        switch (range.lower, range.upper) {
        case (.none, .none): return "null"
        case (let l, .none) where l != .none:
            return "IDBKeyRange.lowerBound(\(js(l)), \(range.lowerOpen))"
        case (.none, let u) where u != .none:
            return "IDBKeyRange.upperBound(\(js(u)), \(range.upperOpen))"
        default:
            return "IDBKeyRange.bound(\(js(range.lower)), \(js(range.upper)), \(range.lowerOpen), \(range.upperOpen))"
        }
    }


    struct ManifestIcon: Identifiable, Equatable {
        var id: String { src + "|\(sizes)" }
        var src: String
        var sizes: String
        var type: String
        var purpose: String
    }

    struct ManifestShortcut: Identifiable, Equatable {
        var id: String { name + "|" + url }
        var name: String
        var url: String
        var description: String
    }

    struct ManifestData: Equatable {
        var name: String
        var shortName: String
        var startURL: String
        var scope: String
        var display: String
        var themeColor: String
        var backgroundColor: String
        var icons: [ManifestIcon]
        var shortcuts: [ManifestShortcut]
        var rawJSON: String
    }

    static func parseManifest(_ json: String) -> ManifestData? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let icons: [ManifestIcon] = (obj["icons"] as? [[String: Any]] ?? []).compactMap { icon in
            guard let src = icon["src"] as? String, !src.isEmpty else { return nil }
            return ManifestIcon(
                src: src,
                sizes: icon["sizes"] as? String ?? "",
                type: icon["type"] as? String ?? "",
                purpose: icon["purpose"] as? String ?? "any"
            )
        }
        let shortcuts: [ManifestShortcut] = (obj["shortcuts"] as? [[String: Any]] ?? []).map { s in
            ManifestShortcut(
                name: s["name"] as? String ?? "",
                url: s["url"] as? String ?? "",
                description: s["description"] as? String ?? ""
            )
        }
        return ManifestData(
            name: obj["name"] as? String ?? "",
            shortName: obj["short_name"] as? String ?? "",
            startURL: obj["start_url"] as? String ?? "",
            scope: obj["scope"] as? String ?? "",
            display: obj["display"] as? String ?? "",
            themeColor: obj["theme_color"] as? String ?? "",
            backgroundColor: obj["background_color"] as? String ?? "",
            icons: icons,
            shortcuts: shortcuts,
            rawJSON: json
        )
    }

    struct InstallabilityCheck: Identifiable {
        var id: String { label }
        var label: String
        var pass: Bool
        var detail: String
    }

    static func installabilityChecks(for manifest: ManifestData) -> [InstallabilityCheck] {
        let hasName = !manifest.name.isEmpty || !manifest.shortName.isEmpty
        let has192 = manifest.icons.contains { iconHasSize($0, "192x192") }
        let has512 = manifest.icons.contains { iconHasSize($0, "512x512") }
        let validDisplay = ["fullscreen", "standalone", "minimal-ui"].contains(manifest.display)
        return [
            InstallabilityCheck(label: "Has name or short_name", pass: hasName,
                                detail: hasName ? (manifest.name.isEmpty ? manifest.shortName : manifest.name) : "Missing"),
            InstallabilityCheck(label: "Has start_url", pass: !manifest.startURL.isEmpty,
                                detail: manifest.startURL.isEmpty ? "Missing" : manifest.startURL),
            InstallabilityCheck(label: "display is standalone/fullscreen/minimal-ui", pass: validDisplay,
                                detail: manifest.display.isEmpty ? "Missing" : manifest.display),
            InstallabilityCheck(label: "Has 192×192 icon", pass: has192,
                                detail: has192 ? "OK" : "No icon with sizes containing 192x192"),
            InstallabilityCheck(label: "Has 512×512 icon", pass: has512,
                                detail: has512 ? "OK" : "No icon with sizes containing 512x512"),
        ]
    }

    private static func iconHasSize(_ icon: ManifestIcon, _ size: String) -> Bool {
        icon.sizes.split(separator: " ").contains(Substring(size))
    }

    // MARK: - Storage diff

    /// Compute added/removed/changed entries between old and new, preserving order.
    static func diffStorage(
        old: [StorageEntry], new: [StorageEntry]
    ) -> (result: [StorageEntry], changed: Bool) {
        // Keys come from the page, which can send the same key twice: the last one wins, as in Storage itself.
        let oldMap = Dictionary(old.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        let newMap = Dictionary(new.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        if oldMap == newMap { return (old, false) }
        return (new, true)
    }
}
