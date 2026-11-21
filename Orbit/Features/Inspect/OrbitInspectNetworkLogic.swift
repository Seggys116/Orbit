// Foundation-only (no AppKit, SwiftUI or WebKit) so it compiles into the unit-test bundle alongside OrbitInspectDecode.swift.

import Foundation

/// Ids index elements by a sequence number that never changes on eviction, so inserts stay O(1) with no renumbering; positions are `sequence - firstSequence`.
struct OrbitRingBuffer<Element: Identifiable>: RandomAccessCollection, MutableCollection
where Element.ID: Hashable {
    typealias Index = Int

    let capacity: Int
    private var storage = ContiguousArray<Element>()
    private var head = 0
    private var firstSequence = 0
    private var sequenceByID: [Element.ID: Int] = [:]

    init(capacity: Int) {
        precondition(capacity > 0, "A ring buffer needs a positive capacity")
        self.capacity = capacity
        storage.reserveCapacity(Swift.min(capacity, 256))
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }
    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }

    private func slot(_ position: Int) -> Int {
        let raw = head + position
        return raw >= storage.count ? raw - storage.count : raw
    }

    subscript(position: Int) -> Element {
        get {
            precondition(position >= 0 && position < storage.count, "Ring buffer index out of range")
            return storage[slot(position)]
        }
        set {
            precondition(position >= 0 && position < storage.count, "Ring buffer index out of range")
            let target = slot(position)
            let oldID = storage[target].id
            if oldID != newValue.id {
                let sequence = firstSequence + position
                if sequenceByID[oldID] == sequence { sequenceByID.removeValue(forKey: oldID) }
                sequenceByID[newValue.id] = sequence
            }
            storage[target] = newValue
        }
    }

    /// At capacity the oldest entry is dropped and returned; appending an existing id re-points it at the new entry.
    @discardableResult
    mutating func append(_ element: Element) -> Element? {
        var evicted: Element?
        if storage.count < capacity {
            storage.append(element)
        } else {
            let old = storage[head]
            if sequenceByID[old.id] == firstSequence { sequenceByID.removeValue(forKey: old.id) }
            evicted = old
            storage[head] = element
            head = head + 1 == capacity ? 0 : head + 1
            firstSequence += 1
        }
        sequenceByID[element.id] = firstSequence + storage.count - 1
        if sequenceByID.count > capacity * 2 + 64 { dropStaleAliases() }
        return evicted
    }

    func position(forID id: Element.ID) -> Int? {
        guard let sequence = sequenceByID[id] else { return nil }
        let position = sequence - firstSequence
        return position >= 0 && position < storage.count ? position : nil
    }

    subscript(id id: Element.ID) -> Element? {
        position(forID: id).map { self[$0] }
    }

    /// An alias dies with its entry: once the entry is evicted the lookup returns nil.
    mutating func alias(_ id: Element.ID, toPosition position: Int) {
        precondition(position >= 0 && position < storage.count, "Ring buffer index out of range")
        sequenceByID[id] = firstSequence + position
    }

    mutating func removeAll() {
        firstSequence += storage.count
        storage.removeAll(keepingCapacity: true)
        head = 0
        sequenceByID.removeAll(keepingCapacity: true)
    }

    private mutating func dropStaleAliases() {
        let floor = firstSequence
        sequenceByID = sequenceByID.filter { $0.value >= floor }
    }
}


struct NetTimingBreakdown: Equatable, Sendable {
    var queuedMs: Double? = nil
    var dnsMs: Double? = nil
    var connectMs: Double? = nil
    var tlsMs: Double? = nil
    var waitingMs: Double? = nil
    var downloadMs: Double? = nil
    var totalMs: Double? = nil
    var redirectMs: Double? = nil
    /// True when per-phase fields are zero because the resource is cross-origin without Timing-Allow-Origin.
    var crossOriginOpaque: Bool = false
}

struct NetServerTimingEntry: Equatable, Sendable {
    var name: String = ""
    var duration: Double? = nil
    var description: String = ""
}

struct NetResourceTimingRaw: Equatable, Sendable {
    var name: String = ""
    var startTime: Double = 0
    var fetchStart: Double = 0
    var redirectStart: Double = 0
    var redirectEnd: Double = 0
    var domainLookupStart: Double = 0
    var domainLookupEnd: Double = 0
    var connectStart: Double = 0
    var connectEnd: Double = 0
    var secureConnectionStart: Double = 0
    var requestStart: Double = 0
    var responseStart: Double = 0
    var responseEnd: Double = 0
    var transferSize: Int = 0
    var encodedBodySize: Int = 0
    var decodedBodySize: Int = 0
    var nextHopProtocol: String = ""
    var initiatorType: String = ""
    var duration: Double = 0
    var serverTiming: [NetServerTimingEntry] = []
}

struct NetCookieParsed: Equatable, Sendable {
    var name: String = ""
    var value: String = ""
}

struct NetSetCookieParsed: Equatable, Sendable {
    var name: String = ""
    var value: String = ""
    var domain: String? = nil
    var path: String? = nil
    var expiresRaw: String? = nil
    var maxAge: Int? = nil
    var secure: Bool = false
    var httpOnly: Bool = false
    var sameSite: String? = nil
    var issues: [String] = []
}


struct NetFormField: Equatable, Sendable {
    var name: String = ""
    var value: String = ""
    /// Set for a file input of a FormData body: the page can see the name and size but the content is never read.
    var fileName: String? = nil
    var fileSize: Int? = nil
}

/// What the page could see of a request body; WebKit exposes no request bodies natively, so this comes from the fetch/XHR/beacon/form hooks.
struct NetRequestBody: Equatable, Sendable {
    /// "string", "FormData", "URLSearchParams", "Blob", "ArrayBuffer", "Request", "ReadableStream" or "other".
    var kind: String = ""
    var text: String? = nil
    var truncated = false
    var size: Int? = nil
    var mime: String = ""
    var fields: [NetFormField] = []
    /// Total fields in a FormData, which can exceed the `fields` that were kept.
    var fieldCount: Int? = nil
    /// The Content-Type the browser adds for this body type when the page sets none.
    var impliedContentType: String? = nil
    /// Why the content is missing when `text` and `fields` are empty.
    var note: String? = nil
}

struct NetStackFrame: Equatable, Sendable {
    var function: String = ""
    var url: String = ""
    var line: Int? = nil
    var column: Int? = nil

    var isNative: Bool { url == "[native code]" }
    /// Only http(s) and file scripts can be opened in the Sources panel.
    var isOpenable: Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://")
    }
}

struct NetStoreCookie: Equatable, Sendable {
    var name: String = ""
    var value: String = ""
    var domain: String = ""
    var path: String = "/"
    var expires: Date? = nil
    var secure = false
    var httpOnly = false
    var sameSite: String? = nil

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate
        secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly
        sameSite = cookie.sameSitePolicy?.rawValue
    }
}

/// The result of re-reading a response body from inside the page, on demand.
enum NetFetchedBody: Equatable, Sendable {
    case loading
    case text(String, truncated: Bool)
    case image(Data)
    case unavailable(String)
}

enum NetBodyFetchability: Equatable, Sendable {
    case refetch
    case unavailable(String)
}

struct NetFilterToken: Equatable, Sendable {
    indirect enum Kind: Equatable, Sendable {
        case domain(String)
        case method(String)
        case statusCode(Int)
        case mimeType(String)
        case largerThan(Int)   // bytes
        case scheme(String)
        case hasResponseHeader(String)
        case isRunning
        case text(String)
        case regex(String)
        case negated(Kind)
    }
    var kind: Kind
}


struct NetSummary: Equatable, Sendable {
    var totalRequests: Int = 0
    var filteredRequests: Int = 0
    var transferredBytes: Int = 0
    var resourceBytes: Int = 0
    var finishMs: Double? = nil
    var dclMs: Double? = nil
    var loadMs: Double? = nil
}


enum OrbitNetworkLogic {

    /// Cross-origin resources without Timing-Allow-Origin have zero per-phase values but non-zero duration; those are flagged `crossOriginOpaque`.
    static func phases(from t: NetResourceTimingRaw) -> NetTimingBreakdown {
        let hasDetail = t.requestStart > 0 || t.responseStart > 0 || t.connectStart > 0
        if !hasDetail {
            if t.duration > 0 {
                return NetTimingBreakdown(totalMs: t.duration, crossOriginOpaque: true)
            }
            return NetTimingBreakdown()
        }

        let ref = t.fetchStart > 0 ? t.fetchStart : t.startTime

        func span(_ a: Double, _ b: Double) -> Double? {
            guard a > 0, b >= a else { return nil }
            return b - a
        }

        let redirectMs = span(t.redirectStart, t.redirectEnd)

        let firstPhase: Double?
        if t.domainLookupStart > 0 { firstPhase = t.domainLookupStart }
        else if t.connectStart > 0 { firstPhase = t.connectStart }
        else { firstPhase = t.requestStart > 0 ? t.requestStart : nil }

        let queuedRaw: Double? = firstPhase.map { max(0, $0 - ref) }
        let queuedMs: Double? = queuedRaw.flatMap { $0 < 0.001 ? nil : $0 }

        let dnsMs = span(t.domainLookupStart, t.domainLookupEnd)

        let connectMs: Double?
        let tlsMs: Double?
        if t.connectStart > 0 && t.connectEnd > 0 {
            if t.secureConnectionStart > 0 && t.secureConnectionStart < t.connectEnd {
                connectMs = max(0, t.secureConnectionStart - t.connectStart)
                tlsMs = t.connectEnd - t.secureConnectionStart
            } else {
                connectMs = t.connectEnd - t.connectStart
                tlsMs = nil
            }
        } else {
            connectMs = nil; tlsMs = nil
        }

        let waitingMs = span(t.requestStart, t.responseStart)
        let downloadMs = span(t.responseStart, t.responseEnd)

        let totalMs: Double?
        if t.responseEnd > ref {
            totalMs = t.responseEnd - ref
        } else if t.duration > 0 {
            totalMs = t.duration
        } else {
            totalMs = nil
        }

        return NetTimingBreakdown(
            queuedMs: queuedMs,
            dnsMs: dnsMs,
            connectMs: connectMs,
            tlsMs: tlsMs,
            waitingMs: waitingMs,
            downloadMs: downloadMs,
            totalMs: totalMs,
            redirectMs: redirectMs,
            crossOriginOpaque: false
        )
    }


    static func canonicalType(resourceType: String, mimeType: String) -> String {
        switch resourceType.lowercased() {
        case "document", "main_frame": return "document"
        case "sub_frame": return "document"
        case "script": return "script"
        case "stylesheet": return "stylesheet"
        case "image": return "image"
        case "font": return "font"
        case "media": return "media"
        case "fetch", "xmlhttprequest", "xhr": return "fetch"
        case "websocket", "ws": return "websocket"
        case "eventsource": return "eventsource"
        case "manifest": return "manifest"
        case "wasm": return "wasm"
        case "ping", "beacon", "csp_report": return "other"
        default: break
        }
        let mime = mimeType.lowercased()
        if mime.contains("javascript") || mime.contains("ecmascript") { return "script" }
        if mime.contains("css") { return "stylesheet" }
        if mime.hasPrefix("image/") { return "image" }
        if mime.contains("font") || mime.contains("woff") { return "font" }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return "media" }
        if mime.contains("wasm") { return "wasm" }
        if mime.contains("html") { return "document" }
        if mime.contains("json") || (mime.contains("xml") && !mime.contains("html")) { return "fetch" }
        return "other"
    }


    static func statusText(for code: Int) -> String {
        guard code > 0 else { return "Pending" }
        switch code {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 410: return "Gone"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return HTTPURLResponse.localizedString(forStatusCode: code)
        }
    }


    static func sizeLabel(
        transferSize: Int?,
        bodySize: Int?,
        fromCache: Bool,
        diskCache: Bool = false
    ) -> (transferred: String, resource: String) {
        if fromCache {
            let label = diskCache ? "(disk cache)" : "(memory cache)"
            return (label, bodySize.map { OrbitDevToolsFormat.bytes($0) } ?? "—")
        }
        return (
            transferSize.map { OrbitDevToolsFormat.bytes($0) } ?? "—",
            bodySize.map { OrbitDevToolsFormat.bytes($0) } ?? "—"
        )
    }


    static func parseFilterQuery(_ raw: String) -> [NetFilterToken] {
        var result: [NetFilterToken] = []
        var s = raw.trimmingCharacters(in: .whitespaces)
        while !s.isEmpty {
            s = s.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { break }
            let negate = s.hasPrefix("-")
            if negate { s = String(s.dropFirst()) }
            var kind: NetFilterToken.Kind?
            if s.hasPrefix("/") {
                let inner = String(s.dropFirst())
                if let end = inner.firstIndex(of: "/") {
                    let pattern = String(inner[..<end])
                    let skip = 1 + inner.distance(from: inner.startIndex, to: end) + 1
                    s = String(s.dropFirst(skip))
                    kind = .regex(pattern)
                } else { break }
            } else {
                let wordEnd = s.firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
                let word = String(s[..<wordEnd])
                s = String(s[wordEnd...])
                if let colon = word.firstIndex(of: ":") {
                    let key = String(word[..<colon]).lowercased()
                    let val = String(word[word.index(after: colon)...])
                    if !val.isEmpty {
                        switch key {
                        case "domain": kind = .domain(val)
                        case "method": kind = .method(val.uppercased())
                        case "status-code": kind = Int(val).map { .statusCode($0) }
                        case "mime-type": kind = .mimeType(val)
                        case "larger-than": kind = parseSizeString(val).map { .largerThan($0) }
                        case "scheme": kind = .scheme(val.lowercased())
                        case "has-response-header": kind = .hasResponseHeader(val.lowercased())
                        case "is": if val.lowercased() == "running" { kind = .isRunning }
                        default: kind = .text(word)
                        }
                    } else { kind = .text(word) }
                } else if !word.isEmpty {
                    kind = .text(word)
                }
            }
            if let k = kind {
                result.append(NetFilterToken(kind: negate ? .negated(k) : k))
            }
        }
        return result
    }

    private static func parseSizeString(_ s: String) -> Int? {
        let lower = s.lowercased()
        if lower.hasSuffix("kb") { return Double(s.dropLast(2)).map { Int(clamping: $0 * 1024) } }
        if lower.hasSuffix("k") { return Double(s.dropLast()).map { Int(clamping: $0 * 1024) } }
        if lower.hasSuffix("mb") { return Double(s.dropLast(2)).map { Int(clamping: $0 * 1024 * 1024) } }
        if lower.hasSuffix("m") { return Double(s.dropLast()).map { Int(clamping: $0 * 1024 * 1024) } }
        return Int(s)
    }


    static func matchesFilter(_ r: OrbitNetworkRecord, tokens: [NetFilterToken]) -> Bool {
        tokens.allSatisfy { matchToken(r, $0.kind) }
    }

    private static func matchToken(_ r: OrbitNetworkRecord, _ k: NetFilterToken.Kind) -> Bool {
        switch k {
        case .domain(let d):
            return URL(string: r.url)?.host?.lowercased().contains(d.lowercased()) == true
        case .method(let m):
            return r.method.uppercased() == m
        case .statusCode(let c):
            return r.status == c
        case .mimeType(let m):
            return r.mimeType.lowercased().contains(m.lowercased())
        case .largerThan(let b):
            return (r.transferSize ?? r.bodySize ?? 0) > b
        case .scheme(let s):
            return URL(string: r.url)?.scheme?.lowercased() == s
        case .hasResponseHeader(let n):
            return r.responseHeaders.contains { $0.name.lowercased() == n }
        case .isRunning:
            return r.status == 0 && !r.failed
        case .text(let t):
            let l = t.lowercased()
            return r.url.lowercased().contains(l) || r.resourceType.lowercased().contains(l)
        case .regex(let p):
            guard let re = try? NSRegularExpression(pattern: p) else { return true }
            return re.firstMatch(in: r.url, range: NSRange(r.url.startIndex..., in: r.url)) != nil
        case .negated(let inner):
            return !matchToken(r, inner)
        }
    }


    static func curlBash(_ r: OrbitNetworkRecord, body: String? = nil) -> String {
        var parts = ["curl \(OrbitDevToolsFormat.shellQuote(r.url))"]
        if r.method != "GET" { parts.append("-X \(OrbitDevToolsFormat.shellQuote(r.method))") }
        let skip: Set<String> = ["host", ":authority", ":method", ":path", ":scheme"]
        for h in r.requestHeaders where !skip.contains(h.name.lowercased()) {
            parts.append("-H \(OrbitDevToolsFormat.shellQuote("\(h.name): \(h.value)"))")
        }
        if let b = body, !b.isEmpty {
            parts.append("--data-raw \(OrbitDevToolsFormat.shellQuote(b))")
        }
        return parts.joined(separator: " \\\n  ")
    }

    static func curlWindows(_ r: OrbitNetworkRecord, body: String? = nil) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var parts = ["curl.exe \(q(r.url))"]
        if r.method != "GET" { parts.append("-X \(q(r.method))") }
        let skip: Set<String> = ["host", ":authority", ":method", ":path", ":scheme"]
        for h in r.requestHeaders where !skip.contains(h.name.lowercased()) {
            parts.append("-H \(q("\(h.name): \(h.value)"))")
        }
        if let b = body, !b.isEmpty { parts.append("--data-raw \(q(b))") }
        return parts.joined(separator: " ^\n  ")
    }

    static func fetchExpression(_ r: OrbitNetworkRecord, body: String? = nil) -> String {
        var opts: [String] = []
        if r.method != "GET" { opts.append("  method: \(jsLiteral(r.method))") }
        let skip: Set<String> = ["host", ":authority", ":method", ":path", ":scheme", "content-length"]
        let hdrs = r.requestHeaders.filter { !skip.contains($0.name.lowercased()) }
            .map { "    \(jsLiteral($0.name)): \(jsLiteral($0.value))" }
        if !hdrs.isEmpty { opts.append("  headers: {\n" + hdrs.joined(separator: ",\n") + "\n  }") }
        if let b = body, !b.isEmpty { opts.append("  body: \(jsLiteral(b))") }
        if opts.isEmpty { return "fetch(\(jsLiteral(r.url)))" }
        return "fetch(\(jsLiteral(r.url)), {\n" + opts.joined(separator: ",\n") + "\n})"
    }

    private static func jsLiteral(_ s: String) -> String {
        // A bare string is not a valid top-level JSON object (it raises an Objective-C exception), so wrap it in an array.
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              var r = String(data: d, encoding: .utf8), r.count >= 2 else {
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        r.removeFirst()
        r.removeLast()
        return r
    }


    static func harJSON(
        records: [OrbitNetworkRecord],
        timings: [String: NetTimingBreakdown] = [:],
        pageURL: String,
        pageTitle: String
    ) -> String {
        let fmt = ISO8601DateFormatter()
        let now = fmt.string(from: Date())
        let entries: [[String: Any]] = records.map { rec in
            ["startedDateTime": now,
             "time": rec.duration ?? -1,
             "request": harRequest(rec),
             "response": harResponse(rec),
             "cache": [:] as [String: Any],
             "timings": harTimings(rec, timings[rec.id]),
             "_resourceType": rec.resourceType]
        }
        let obj: [String: Any] = ["log": [
            "version": "1.2",
            "creator": ["name": "Orbit", "version": "1.0"],
            "pages": [["startedDateTime": now, "id": "page_1", "title": pageTitle,
                       "pageTimings": [:] as [String: Any]]],
            "entries": entries
        ] as [String: Any]]
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let txt = String(data: d, encoding: .utf8) else { return "{}" }
        return txt
    }

    private static func harRequest(_ r: OrbitNetworkRecord) -> [String: Any] {
        var qs: [[String: String]] = []
        if let u = URL(string: r.url), let c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            qs = (c.queryItems ?? []).map { ["name": $0.name, "value": $0.value ?? ""] }
        }
        return [
            "method": r.method, "url": r.url,
            "httpVersion": r.protocolName ?? "HTTP/1.1",
            "headers": r.requestHeaders.map { ["name": $0.name, "value": $0.value] },
            "queryString": qs, "cookies": [] as [[String: String]],
            "headersSize": -1, "bodySize": -1
        ]
    }

    private static func harResponse(_ r: OrbitNetworkRecord) -> [String: Any] {
        [
            "status": r.status, "statusText": r.statusText,
            "httpVersion": r.protocolName ?? "HTTP/1.1",
            "headers": r.responseHeaders.map { ["name": $0.name, "value": $0.value] },
            "cookies": [] as [[String: String]],
            "content": ["size": r.bodySize ?? -1,
                        "mimeType": r.mimeType.isEmpty ? "application/octet-stream" : r.mimeType],
            "redirectURL": r.responseHeader("Location") ?? "",
            "headersSize": -1, "bodySize": r.transferSize ?? -1
        ]
    }

    private static func harTimings(_ r: OrbitNetworkRecord, _ b: NetTimingBreakdown?) -> [String: Any] {
        guard let b else { return ["send": 0.0, "wait": r.duration ?? -1, "receive": 0.0] }
        var d: [String: Any] = [
            "blocked": b.queuedMs ?? -1, "dns": b.dnsMs ?? -1,
            "connect": b.connectMs ?? -1, "send": 0.0,
            "wait": b.waitingMs ?? -1, "receive": b.downloadMs ?? -1
        ]
        if let tls = b.tlsMs { d["ssl"] = tls }
        return d
    }

    /// RFC 6265 5.1.3: a domain cookie matches on a dot boundary, so "evilexample.com" is not a subdomain of "example.com".
    static func cookieDomainMatches(host: String, cookieDomain: String) -> Bool {
        let host = host.lowercased()
        var domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty, !host.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    static func cookiePathMatches(requestPath: String, cookiePath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        return requestPath.dropFirst(cookiePath.count).first == "/"
    }


    static func parseCookieHeader(_ value: String) -> [NetCookieParsed] {
        value.split(separator: ";").compactMap { part -> NetCookieParsed? in
            let s = part.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            if let eq = s.firstIndex(of: "=") {
                let name = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
                let val = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return NetCookieParsed(name: name, value: val)
            }
            return NetCookieParsed(name: s, value: "")
        }
    }

    static func parseSetCookieHeader(_ value: String) -> NetSetCookieParsed {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else {
            return NetSetCookieParsed(issues: ["Empty Set-Cookie header"])
        }
        let name: String; let cookieVal: String
        if let eq = first.firstIndex(of: "=") {
            name = String(first[..<eq]).trimmingCharacters(in: .whitespaces)
            cookieVal = String(first[first.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        } else { name = first; cookieVal = "" }

        var domain: String? = nil; var path: String? = nil
        var expiresRaw: String? = nil; var maxAge: Int? = nil
        var secure = false; var httpOnly = false; var sameSite: String? = nil

        for attr in parts.dropFirst() {
            let lo = attr.lowercased()
            if lo == "secure" { secure = true }
            else if lo == "httponly" { httpOnly = true }
            else if lo.hasPrefix("domain=") { domain = String(attr.dropFirst(7)) }
            else if lo.hasPrefix("path=") { path = String(attr.dropFirst(5)) }
            else if lo.hasPrefix("expires=") { expiresRaw = String(attr.dropFirst(8)) }
            else if lo.hasPrefix("max-age=") { maxAge = Int(attr.dropFirst(8)) }
            else if lo.hasPrefix("samesite=") { sameSite = String(attr.dropFirst(9)) }
        }
        var issues: [String] = []
        if !secure { issues.append("Secure flag not set") }
        if !httpOnly { issues.append("HttpOnly flag not set") }
        if sameSite == nil { issues.append("SameSite attribute not set") }
        return NetSetCookieParsed(name: name, value: cookieVal, domain: domain, path: path,
                                  expiresRaw: expiresRaw, maxAge: maxAge,
                                  secure: secure, httpOnly: httpOnly, sameSite: sameSite, issues: issues)
    }


    /// A Set-Cookie header read through NSHTTPURLResponse arrives with every cookie joined by ", "; a comma only starts a new cookie when a `name=` follows, which keeps an Expires date whole.
    static func splitSetCookieHeader(_ value: String) -> [String] {
        func startsCookiePair(_ chars: [Character], from index: Int) -> Bool {
            var j = index
            while j < chars.count, chars[j] == " " { j += 1 }
            let nameStart = j
            while j < chars.count, !"=;, \t".contains(chars[j]) { j += 1 }
            return j > nameStart && j < chars.count && chars[j] == "="
        }
        let chars = Array(value)
        var result: [String] = []
        var current = ""
        for (index, c) in chars.enumerated() {
            if c == ",", startsCookiePair(chars, from: index + 1) {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { result.append(last) }
        return result
    }

    /// The cookies WebKit would attach to a request for `url`, in the order RFC 6265 sends them. SameSite and third-party blocking are not applied.
    static func matchingCookies(_ cookies: [HTTPCookie], url: URL, now: Date = Date()) -> [NetStoreCookie] {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let isSecure = url.scheme?.lowercased() == "https"
        return cookies
            .filter { cookie in
                if let expires = cookie.expiresDate, expires <= now { return false }
                return cookieDomainMatches(host: host, cookieDomain: cookie.domain)
                    && cookiePathMatches(requestPath: path, cookiePath: cookie.path)
                    && (!cookie.isSecure || isSecure)
            }
            .sorted { $0.path.count != $1.path.count ? $0.path.count > $1.path.count : $0.name < $1.name }
            .map(NetStoreCookie.init)
    }


    // MARK: - Request payload

    static func decodeRequestBody(_ object: [String: Any]) -> NetRequestBody? {
        let kind = OrbitInspectDecode.string(object, "type")
        guard !kind.isEmpty else { return nil }
        var body = NetRequestBody(kind: kind)
        body.text = object["text"] as? String
        body.truncated = OrbitInspectDecode.bool(object, "truncated")
        body.size = OrbitInspectDecode.integer(object["size"])
        body.mime = OrbitInspectDecode.string(object, "mime")
        body.fieldCount = OrbitInspectDecode.integer(object["count"])
        body.impliedContentType = OrbitInspectDecode.optionalString(object, "ct")
        body.note = OrbitInspectDecode.optionalString(object, "note")
        body.fields = OrbitInspectDecode.objects(object, "entries").map { entry in
            NetFormField(
                name: OrbitInspectDecode.string(entry, "n"),
                value: OrbitInspectDecode.string(entry, "v"),
                fileName: OrbitInspectDecode.optionalString(entry, "f"),
                fileSize: OrbitInspectDecode.integer(entry["s"]))
        }
        return body
    }

    static func requestBodySummary(_ body: NetRequestBody) -> String {
        let size = body.size.map { OrbitDevToolsFormat.bytes($0) }
        switch body.kind {
        case "FormData":
            let n = body.fieldCount ?? body.fields.count
            return "FormData, \(n) field\(n == 1 ? "" : "s")"
        case "string": return "Text" + (size.map { ", \($0)" } ?? "")
        default: return body.kind + (size.map { ", \($0)" } ?? "")
        }
    }

    /// Only text that was really sent is exported; a FormData or binary body has no honest single-string form.
    static func exportableBodyText(_ body: NetRequestBody?) -> String? {
        guard let body, !body.truncated, let text = body.text, !text.isEmpty else { return nil }
        return text
    }

    /// Decodes application/x-www-form-urlencoded text, where "+" means a space.
    static func decodeFormEncoded(_ text: String) -> [NetFormField] {
        func decode(_ part: Substring) -> String {
            let spaced = part.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        return text.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            if let eq = pair.firstIndex(of: "=") {
                return NetFormField(name: decode(pair[..<eq]), value: decode(pair[pair.index(after: eq)...]))
            }
            return NetFormField(name: decode(pair), value: "")
        }
    }

    static func queryParameters(of url: String) -> [NetFormField] {
        guard let query = URL(string: url)?.query, !query.isEmpty else { return [] }
        return decodeFormEncoded(query)
    }

    /// Re-indents valid JSON without parsing it into a dictionary, so key order and number formatting stay as the server sent them.
    static func prettyJSON(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        let chars = Array(trimmed)
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        func lineBreak() { out += "\n" + String(repeating: "  ", count: depth) }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"":
                    inString = true
                    out.append(c)
                case "{", "[":
                    var j = i + 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    let closer: Character = c == "{" ? "}" : "]"
                    out.append(c)
                    if j < chars.count, chars[j] == closer {
                        out.append(closer)
                        i = j
                    } else {
                        depth += 1
                        lineBreak()
                    }
                case "}", "]":
                    depth -= 1
                    lineBreak()
                    out.append(c)
                case ",":
                    out.append(c)
                    lineBreak()
                case ":":
                    out += ": "
                default:
                    if !c.isWhitespace { out.append(c) }
                }
            }
            i += 1
        }
        return out
    }


    static func decodeResourceTiming(_ e: [String: Any]) -> NetResourceTimingRaw {
        func d(_ key: String) -> Double { OrbitInspectDecode.number(e, key) ?? 0 }
        func i(_ key: String) -> Int { OrbitInspectDecode.integer(e, key) }
        let serverTiming = OrbitInspectDecode.objects(e, "serverTiming").map { st in
            NetServerTimingEntry(
                name: OrbitInspectDecode.string(st, "name"),
                duration: OrbitInspectDecode.number(st, "dur"),
                description: OrbitInspectDecode.string(st, "desc"))
        }
        return NetResourceTimingRaw(
            name: OrbitInspectDecode.string(e, "url"),
            startTime: d("st"), fetchStart: d("fetchStart"),
            redirectStart: d("rdStart"), redirectEnd: d("rdEnd"),
            domainLookupStart: d("dnsStart"), domainLookupEnd: d("dnsEnd"),
            connectStart: d("connStart"), connectEnd: d("connEnd"),
            secureConnectionStart: d("tlsStart"),
            requestStart: d("reqStart"), responseStart: d("respStart"),
            responseEnd: d("respEnd"),
            transferSize: i("xfer"), encodedBodySize: i("encBody"), decodedBodySize: i("decBody"),
            nextHopProtocol: OrbitInspectDecode.string(e, "proto"),
            initiatorType: OrbitInspectDecode.string(e, "init"),
            duration: d("dur"), serverTiming: serverTiming)
    }


    // MARK: - Initiator

    /// Parses a WebKit stack line, "name@https://host/app.js:12:34"; a line without a location is not a frame.
    static func parseStackFrame(_ raw: String) -> NetStackFrame? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        var function = ""
        var location = line
        if let at = line.firstIndex(of: "@") {
            function = String(line[..<at])
            location = String(line[line.index(after: at)...])
        }
        var frame = NetStackFrame(function: function)
        let parts = location.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3, let column = Int(parts[parts.count - 1]), let lineNumber = Int(parts[parts.count - 2]) {
            frame.line = lineNumber
            frame.column = column
            frame.url = parts.dropLast(2).joined(separator: ":")
        } else {
            frame.url = location
        }
        return frame.url.isEmpty ? nil : frame
    }

    static func stackFrames(_ lines: [String]) -> [NetStackFrame] {
        lines.compactMap(parseStackFrame)
    }

    /// The first frame a developer can open: the script that called fetch or XHR.
    static func initiatorLocation(_ frames: [NetStackFrame]) -> NetStackFrame? {
        frames.first { $0.isOpenable }
    }

    /// Names what started a load from the hook that saw it or the resource-timing `initiatorType`; nil when neither says.
    static func initiatorKind(jsSource: String, timingInitiatorType: String, resourceType: String) -> (title: String, detail: String)? {
        switch jsSource {
        case "fetch": return ("fetch()", "Started by a call to window.fetch from page script.")
        case "xhr": return ("XMLHttpRequest", "Started by an XMLHttpRequest send() from page script.")
        case "beacon": return ("navigator.sendBeacon()", "Started by a call to navigator.sendBeacon from page script.")
        default: break
        }
        switch resourceType.lowercased() {
        case "websocket": return ("WebSocket", "Opened by new WebSocket() in page script.")
        case "eventsource": return ("EventSource", "Opened by new EventSource() in page script.")
        default: break
        }
        switch timingInitiatorType.lowercased() {
        case "": break
        case "script": return ("Script element", "Loaded by a <script> element, either parsed from the HTML or created by script.")
        case "link": return ("Link element", "Loaded by a <link> element: a stylesheet, preload, prefetch, modulepreload or icon.")
        case "css": return ("CSS", "Loaded from inside a stylesheet by url(), @import or @font-face.")
        case "img", "image": return ("Image element", "Loaded by an <img>, <picture> or SVG <image> element.")
        case "iframe", "frame": return ("Frame", "Loaded as the document of an <iframe> or <frame>.")
        case "video", "audio", "track": return ("Media element", "Loaded by a <video>, <audio> or <track> element.")
        case "object", "embed": return ("Embedded object", "Loaded by an <object> or <embed> element.")
        case "navigation": return ("Navigation", "The page itself: typed in the address bar, a link click, a form submission or a redirect.")
        case "fetch": return ("fetch()", "Started by fetch() (possibly before DevTools was attached, or from a worker).")
        case "xmlhttprequest": return ("XMLHttpRequest", "Started by an XMLHttpRequest (possibly before DevTools was attached, or from a worker).")
        case "beacon": return ("navigator.sendBeacon()", "Started by navigator.sendBeacon.")
        case "other": return ("Other", "The browser reports no specific initiator type for this load.")
        case let other: return (other, "Initiator type reported by PerformanceResourceTiming.")
        }
        switch resourceType.lowercased() {
        case "document", "main_frame": return ("Navigation", "The page itself: typed in the address bar, a link click, a form submission or a redirect.")
        default: return nil
        }
    }

    /// Nil when either URL cannot be parsed. Origin means scheme, host and port.
    static func isCrossOrigin(_ url: String, pageURL: String) -> Bool? {
        guard let a = URL(string: url), let b = URL(string: pageURL),
              let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased() else { return nil }
        func port(_ u: URL) -> Int {
            u.port ?? (u.scheme?.lowercased() == "https" ? 443 : (u.scheme?.lowercased() == "http" ? 80 : 0))
        }
        return a.scheme?.lowercased() != b.scheme?.lowercased() || hostA != hostB || port(a) != port(b)
    }


    // MARK: - Response body

    static func isTextualMime(_ mime: String) -> Bool {
        let m = mime.lowercased()
        return m.hasPrefix("text/") || m.contains("json") || m.contains("javascript") || m.contains("ecmascript")
            || m.contains("xml") || m.contains("x-www-form-urlencoded") || m.contains("graphql")
    }

    /// Whether a response body can be re-read from the page when the hooks did not capture it, or why not.
    static func bodyFetchability(
        method: String, status: Int, mimeType: String, resourceType: String, url: String,
        pending: Bool, failed: Bool, cancelled: Bool
    ) -> NetBodyFetchability {
        if pending { return .unavailable("The request has not finished yet.") }
        if failed { return .unavailable("The request failed, so there is no response body.") }
        if cancelled { return .unavailable("The request was cancelled before a response body arrived.") }
        let scheme = URL(string: url)?.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            return .unavailable("Only http and https responses can be re-read.")
        }
        switch resourceType.lowercased() {
        case "websocket", "eventsource":
            return .unavailable("Streams are shown as messages, not as a single body.")
        default: break
        }
        if method.uppercased() != "GET" {
            return .unavailable("Re-reading a \(method.uppercased()) response would send the request again, so it is not done. Only bodies captured by the page hooks while DevTools was open are shown.")
        }
        if status == 0 { return .unavailable("No response status was recorded for this request.") }
        if status == 204 || status == 205 { return .unavailable("Status \(status) has no response body.") }
        if status >= 300 && status < 400 && status != 304 {
            return .unavailable("A redirect response; the content comes from the request it redirects to.")
        }
        let mime = mimeType.lowercased()
        if mime.isEmpty || isTextualMime(mime) || mime.hasPrefix("image/") { return .refetch }
        return .unavailable("Binary content (\(mimeType)) cannot be shown as text or an image.")
    }

    static func decodeFetchedBody(_ object: [String: Any]) -> (id: String, body: NetFetchedBody)? {
        let id = OrbitInspectDecode.string(object, "id")
        guard !id.isEmpty else { return nil }
        switch OrbitInspectDecode.string(object, "kind") {
        case "text":
            return (id, .text(OrbitInspectDecode.string(object, "text"), truncated: OrbitInspectDecode.bool(object, "truncated")))
        case "image":
            guard let data = Data(base64Encoded: OrbitInspectDecode.string(object, "b64")), !data.isEmpty else {
                return (id, .unavailable("The image data could not be decoded."))
            }
            return (id, .image(data))
        default:
            return (id, .unavailable(fetchFailureReason(
                code: OrbitInspectDecode.string(object, "reason"), detail: OrbitInspectDecode.string(object, "detail"))))
        }
    }

    static func fetchFailureReason(code: String, detail: String) -> String {
        switch code {
        case "opaque":
            return "This is an opaque response: the browser hides its status, headers and body from page script."
        case "binary":
            return "Binary content (\(detail.isEmpty ? "unknown type" : detail)) cannot be shown as text or an image."
        case "too_large":
            let size = Int(detail).map { OrbitDevToolsFormat.bytes($0) } ?? detail
            return "The image (\(size)) is too large to preview."
        case "error":
            return "The page could not re-read this response (\(detail.isEmpty ? "request failed" : detail)). A cross-origin response is readable only when the server allows it with CORS."
        default:
            return "The response body is not available."
        }
    }

    /// Reasons the page hooks gave for not capturing a body; they are shown instead of an empty pane.
    static func captureSkipReason(code: String, mime: String) -> String? {
        switch code {
        case "": return nil
        case "closed": return "DevTools was closed when this response arrived, so its body was not read."
        case "opaque": return "This is an opaque (no-cors) response: the browser hides its body from page script."
        case "stream": return "A streaming response (text/event-stream) is never buffered."
        case "type": return "Binary or unsupported content type\(mime.isEmpty ? "" : " (\(mime))"): only text responses are captured."
        case "responseType": return "This XMLHttpRequest asked for a non-text response type, which is not captured."
        case "empty": return "The response had no body."
        case "unreadable": return "The response body could not be read by the page hook."
        case "large": return "The response is large, so it is read again when you select it."
        default: return nil
        }
    }


    static func applyTimeRange(_ records: [OrbitNetworkRecord], range: ClosedRange<Double>?) -> [OrbitNetworkRecord] {
        guard let range else { return records }
        return records.filter { r in
            guard let t = r.startTime else { return true }
            return range.contains(t)
        }
    }


    static func summary(
        all: [OrbitNetworkRecord],
        filtered: [OrbitNetworkRecord],
        dclMs: Double?,
        loadMs: Double?
    ) -> NetSummary {
        let xfer = filtered.reduce(0) { $0 + ($1.transferSize ?? 0) }
        let res = filtered.reduce(0) { $0 + ($1.bodySize ?? 0) }
        let starts = all.compactMap { $0.startTime }
        let ends = all.compactMap { r -> Double? in
            guard let s = r.startTime, let d = r.duration else { return nil }
            return s + d
        }
        var finish: Double? = nil
        if let first = starts.min(), let last = ends.max(), last > first {
            finish = last - first
        }
        return NetSummary(totalRequests: all.count, filteredRequests: filtered.count,
                          transferredBytes: xfer, resourceBytes: res,
                          finishMs: finish, dclMs: dclMs, loadMs: loadMs)
    }


    static func typeCounts(_ records: [OrbitNetworkRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in records {
            let t = canonicalType(resourceType: r.resourceType, mimeType: r.mimeType)
            counts[t, default: 0] += 1
        }
        return counts
    }
}
