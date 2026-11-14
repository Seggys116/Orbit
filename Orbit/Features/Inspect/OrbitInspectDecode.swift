
import Foundation

enum OrbitInspectDecode {
    static func number(_ object: [String: Any], _ key: String) -> Double? {
        switch object[key] {
        case let value as Double: return value.isFinite ? value : nil
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue.isFinite ? value.doubleValue : nil
        default: return nil
        }
    }

    static func integer(_ object: [String: Any], _ key: String) -> Int {
        integer(object[key]) ?? 0
    }

    /// `Int(Double)` traps outside Int's range and page messages can carry 1e300, so page numbers are rounded and clamped.
    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as Double: return Int(clamping: value)
        case let value as NSNumber: return Int(clamping: value.doubleValue)
        default: return nil
        }
    }
}

extension Int {
    init(clamping value: Double) {
        guard !value.isNaN else { self = 0; return }
        let rounded = value.rounded()
        if rounded >= 9.2e18 { self = Int.max; return }
        if rounded <= -9.2e18 { self = Int.min; return }
        self = Int(rounded)
    }
}

extension OrbitInspectDecode {

    static func bool(_ object: [String: Any], _ key: String) -> Bool {
        switch object[key] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as Int: return value != 0
        default: return false
        }
    }

    static func string(_ object: [String: Any], _ key: String) -> String {
        object[key] as? String ?? ""
    }

    static func optionalString(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    static func strings(_ object: [String: Any], _ key: String) -> [String] {
        if let values = object[key] as? [String] { return values }
        if let values = object[key] as? [Any] { return values.compactMap { $0 as? String } }
        return []
    }

    static func stringMap(_ object: [String: Any], _ key: String) -> [String: String] {
        guard let raw = object[key] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (name, value) in raw {
            if let text = value as? String { result[name] = text }
            else if let number = value as? NSNumber { result[name] = number.stringValue }
        }
        return result
    }

    static func objects(_ object: [String: Any], _ key: String) -> [[String: Any]] {
        object[key] as? [[String: Any]] ?? []
    }

    static func object(_ object: [String: Any], _ key: String) -> [String: Any]? {
        object[key] as? [String: Any]
    }

    /// JSONSerialization raises an uncatchable exception for a top-level scalar, so the value is wrapped in an array, written, and unwrapped.
    static func jsonLiteral(_ value: Any) -> String? {
        let wrapped: [Any] = [value]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped),
              var text = String(data: data, encoding: .utf8), text.count >= 2 else { return nil }
        text.removeFirst()
        text.removeLast()
        return text
    }
}

enum OrbitDevToolsFormat {
    static func bytes(_ count: Int) -> String {
        if count < 0 { return "—" }
        if count < 1024 { return "\(count) B" }
        let kilobytes = Double(count) / 1024
        if kilobytes < 1024 { return String(format: "%.1f KB", kilobytes) }
        return String(format: "%.1f MB", kilobytes / 1024)
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value < 1 { return String(format: "%.2f ms", value) }
        if value < 1000 { return "\(Int(value.rounded())) ms" }
        return String(format: "%.2f s", value / 1000)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Turns bundler names from source maps and stack traces (webpack, Vite, file URLs) into openable file paths.
enum OrbitInspectEditorPaths {
    struct Resolved: Equatable {
        var absolute: String?
        var relatives: [String]
    }

    static func resolve(_ source: String) -> Resolved {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<query]) }

        if text.hasPrefix("file://") {
            let path = String(text.dropFirst("file://".count))
            return Resolved(absolute: path.removingPercentEncoding ?? path, relatives: [])
        }

        var path = text
        if path.hasPrefix("webpack-internal://") {
            path = String(path.dropFirst("webpack-internal://".count))
        } else if path.hasPrefix("webpack://") {
            path = String(path.dropFirst("webpack://".count))
            // webpack://<namespace>/<path>: the namespace is the package name or "_N_E", never part of the path.
            if let slash = path.firstIndex(of: "/"), !path.hasPrefix("/"), !path.hasPrefix(".") {
                path = String(path[path.index(after: slash)...])
            }
        } else if let url = URL(string: path), let scheme = url.scheme, scheme == "http" || scheme == "https" {
            path = url.path
        }

        while path.hasPrefix("/(") || path.hasPrefix("(") {
            guard let close = path.firstIndex(of: ")") else { break }
            path = String(path[path.index(after: close)...])
        }

        if path.hasPrefix("/@fs/") { return Resolved(absolute: String(path.dropFirst(4)), relatives: []) }

        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        let relative = parts.joined(separator: "/").removingPercentEncoding ?? parts.joined(separator: "/")
        let isAbsolute = text.hasPrefix("/") && !text.hasPrefix("//") && FileManagerProbe.looksLikeFilesystemPath(text)
        if isAbsolute { return Resolved(absolute: text, relatives: relative.isEmpty ? [] : [relative]) }
        guard !relative.isEmpty else { return Resolved(absolute: nil, relatives: []) }

        // Also try with leading folders dropped, so "packages/web/src/a.ts" can match a root inside the repo.
        var candidates = [relative]
        var trimmed = parts
        while trimmed.count > 1 {
            trimmed.removeFirst()
            candidates.append(trimmed.joined(separator: "/"))
        }
        return Resolved(absolute: nil, relatives: candidates)
    }

    private enum FileManagerProbe {
        static func looksLikeFilesystemPath(_ text: String) -> Bool {
            ["/Users/", "/home/", "/var/", "/private/", "/opt/", "/tmp/", "/Volumes/", "/usr/", "/srv/"].contains { text.hasPrefix($0) }
        }
    }
}


struct OrbitHeader: Equatable, Sendable, Hashable {
    var name: String
    var value: String
}

/// The one network type other tools may rely on; every load is published through `OrbitNetworkModel.records` (oldest first).
struct OrbitNetworkRecord: Identifiable, Equatable, Sendable {
    var id: String
    var url: String
    var method: String = "GET"
    var status: Int = 0
    var statusText: String = ""
    var resourceType: String = "other"
    var mimeType: String = ""
    var requestHeaders: [OrbitHeader] = []
    var responseHeaders: [OrbitHeader] = []
    var transferSize: Int?
    var bodySize: Int?
    /// Milliseconds on the page's `performance.now()` clock. Nil when unknown.
    var startTime: Double?
    var duration: Double?
    var fromCache = false
    var failed = false
    var isMainFrame = true
    var initiatorURL: String?
    var protocolName: String?

    func header(_ name: String, in headers: [OrbitHeader]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func responseHeader(_ name: String) -> String? { header(name, in: responseHeaders) }
    func requestHeader(_ name: String) -> String? { header(name, in: requestHeaders) }
}
