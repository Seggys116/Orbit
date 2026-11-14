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
