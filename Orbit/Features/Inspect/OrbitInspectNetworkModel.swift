import Foundation
import AppKit

@MainActor
@Observable
final class OrbitNetworkModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?

    private(set) var records: [OrbitNetworkRecord] = []


    private(set) var navigationTiming: NetNavigationTiming? = nil


    var isRecording: Bool = true

    var searchQuery: String = "" { didSet { rebuildFiltered() } }
    var typeFilter: String = "all" { didSet { rebuildFiltered() } }
    var hideDataURLs: Bool = true { didSet { rebuildFiltered() } }
    var showOnlyFailed: Bool = false { didSet { rebuildFiltered() } }
    var showThirdPartyOnly: Bool = false { didSet { rebuildFiltered() } }
    var invertFilter: Bool = false { didSet { rebuildFiltered() } }
    var timeRange: ClosedRange<Double>? = nil { didSet { rebuildFiltered() } }
    var sortColumn: String = "order" { didSet { rebuildFiltered() } }
    var sortAscending: Bool = true { didSet { rebuildFiltered() } }

    var selectedID: String? = nil
    var detailTab: String = "headers"

    var columnWidths: [String: CGFloat] = [:]


    private(set) var filteredRecords: [OrbitNetworkRecord] = []
    private(set) var typeCounts: [String: Int] = [:]
    private(set) var summary: NetSummary = NetSummary()

    /// One log row: the rich record plus its public projection, kept in step so a change costs one projection.
    private struct Entry: Identifiable {
        var rich: NetRecord
        var pub: OrbitNetworkRecord
        var id: String { rich.id }
        init(_ rich: NetRecord) {
            self.rich = rich
            self.pub = rich.asPublicRecord()
        }
    }

    @ObservationIgnored private var _all = OrbitRingBuffer<Entry>(capacity: 5000)

    /// A page load is hundreds of messages, so derived state is rebuilt once per frame, not once per message.
    @ObservationIgnored private var derivedDirty = false
    @ObservationIgnored private var flushScheduled = false
    private static let flushDelay: Duration = .milliseconds(16)

    var messageTypes: Set<String> { ["net.batch", "net.nav"] }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        switch type {
        case "net.batch":
            for entry in OrbitInspectDecode.objects(object, "entries") {
                handleJSEntry(entry, frame: frame)
            }
        case "net.nav":
            handleNavTiming(object)
        default: break
        }
    }

    func pageDidReset(preservingLog: Bool) {
        if !preservingLog {
            // The main document is recorded before the agent's hello, which clears the log, so it must survive or the first request disappears.
            let page = session?.pageURL ?? ""
            let kept = _all.filter { entry in
                let rec = entry.rich
                guard rec.isMainFrame else { return false }
                guard rec.resourceType == "document" || rec.resourceType == "main_frame" || rec.id.hasPrefix("nav-") else { return false }
                return page.isEmpty || Self.sameDocument(rec.url, page)
            }
            _all.removeAll()
            for entry in kept { _all.append(entry) }
            navigationTiming = nil
        }
        selectedID = nil
        rebuildFiltered()
    }

    private static func sameDocument(_ recorded: String, _ page: String) -> Bool {
        if recorded == page { return true }
        guard let left = URL(string: recorded), let right = URL(string: page) else { return false }
        let leftPath = left.path.isEmpty ? "/" : left.path
        let rightPath = right.path.isEmpty ? "/" : right.path
        return left.scheme == right.scheme && left.host == right.host && left.port == right.port && leftPath == rightPath
    }

    func panelDidAppear(force: Bool) {
        if force {
            session?.command(["op": "net.refresh"])
        }
    }

    func nativeRequestSent(_ record: NetRecord) {
        guard isRecording else { return }
        // The page's fetch/XHR hook can report a request before WebKit does; fold that record into this one, in the page record's row.
        if getRecord(record.id) == nil, let jsIdx = findUnmergedPageRecord(url: record.url, method: record.method) {
            let page = _all[jsIdx].rich
            var merged = record
            merged.startTime = page.startTime ?? merged.startTime
            merged.initiatorStack = page.initiatorStack
            if merged.requestHeaders.isEmpty { merged.requestHeaders = page.requestHeaders }
            merged.requestBodySummary = page.requestBodySummary
            if merged.status == 0 { merged.status = page.status }
            if merged.responseHeaders.isEmpty { merged.responseHeaders = page.responseHeaders }
            if merged.mimeType.isEmpty { merged.mimeType = page.mimeType }
            if merged.duration == nil { merged.duration = page.duration }
            merged.responseBody = page.responseBody
            merged.responseBodyTruncated = page.responseBodyTruncated
            if !page.pending {
                merged.pending = false
                merged.failed = page.failed
                merged.cancelled = page.cancelled
                merged.errorMessage = page.errorMessage
            }
            merged.pageTimingMerged = true
            store(merged, at: jsIdx)
            _all.alias(page.id, toPosition: jsIdx)
            return
        }
        setRecord(record)
    }

    /// The resource-load delegate does not report the main document on current WebKit, so it is recorded from navigation policy and rebound if a callback arrives.
    func noteMainFrameRequest(url: URL, method: String, headers: [OrbitHeader]) {
        guard isRecording else { return }
        let absolute = url.absoluteString
        if let idx = provisionalMainDocumentIndex(url: absolute) {
            var rec = _all[idx].rich
            if rec.requestHeaders.isEmpty { rec.requestHeaders = headers }
            if !method.isEmpty { rec.method = method }
            rec.resourceType = "document"
            rec.isMainFrame = true
            setRecord(rec)
            return
        }
        var record = NetRecord(id: "nav-\(UUID().uuidString)")
        record.url = absolute
        record.method = method.isEmpty ? "GET" : method
        record.resourceType = "document"
        record.isMainFrame = true
        record.requestHeaders = headers
        record.pending = true
        setRecord(record)
    }

    func noteMainFrameResponse(_ response: HTTPURLResponse) {
        let absolute = response.url?.absoluteString ?? ""
        let headers = response.allHeaderFields
            .map { OrbitHeader(name: "\($0.key)", value: "\($0.value)") }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        let mime = response.mimeType ?? ""
        if let idx = provisionalMainDocumentIndex(url: absolute) ?? provisionalMainDocumentIndex(url: "") {
            var rec = _all[idx].rich
            rec.status = response.statusCode
            rec.statusText = OrbitNetworkLogic.statusText(for: response.statusCode)
            if rec.responseHeaders.isEmpty { rec.responseHeaders = headers }
            if !mime.isEmpty, rec.mimeType.isEmpty { rec.mimeType = mime }
            if !absolute.isEmpty { rec.url = absolute }
            rec.resourceType = "document"
            rec.isMainFrame = true
            rec.pending = false
            setRecord(rec)
            return
        }
        guard isRecording, !absolute.isEmpty else { return }
        var record = NetRecord(id: "nav-\(UUID().uuidString)")
        record.url = absolute
        record.method = "GET"
        record.resourceType = "document"
        record.isMainFrame = true
        record.status = response.statusCode
        record.statusText = OrbitNetworkLogic.statusText(for: response.statusCode)
        record.responseHeaders = headers
        record.mimeType = mime
        record.pending = false
        setRecord(record)
    }

    func adoptNativeMainDocument(
        loadID: String, url: String, method: String, headers: [OrbitHeader], timestamp: Double
    ) -> Bool {
        guard let idx = provisionalMainDocumentIndex(url: url),
              _all[idx].rich.id.hasPrefix("nav-") else { return false }
        var rec = _all[idx].rich
        rec.id = loadID
        rec.nativeEventTimestamp = timestamp
        if rec.requestHeaders.isEmpty { rec.requestHeaders = headers }
        if !method.isEmpty { rec.method = method }
        rec.resourceType = "document"
        rec.isMainFrame = true
        store(rec, at: idx)
        return true
    }

    func nativeResponseReceived(id: String, status: Int, statusText: String,
                                 headers: [OrbitHeader], mimeType: String,
                                 url: String?, fromCache: Bool, expectedBodySize: Int?) {
        guard var rec = getRecord(id) else { return }
        rec.status = status
        rec.statusText = statusText
        rec.responseHeaders = headers
        if !mimeType.isEmpty { rec.mimeType = mimeType }
        if let u = url, !u.isEmpty { rec.url = u }
        rec.fromCache = fromCache
        if let sz = expectedBodySize { rec.bodySize = sz }
        setRecord(rec)
    }

    func nativeRedirected(id: String, fromURL: String, status: Int,
                           responseHeaders: [OrbitHeader], toURL: String) {
        guard var rec = getRecord(id) else { return }
        rec.redirectChain.append(NetRedirectHop(
            fromURL: fromURL, toURL: toURL,
            status: status, responseHeaders: responseHeaders))
        if !toURL.isEmpty { rec.url = toURL }
        setRecord(rec)
    }

    func nativeCompleted(id: String, failed: Bool, cancelled: Bool,
                          fromCache: Bool, completionTimestamp: Double, errorMessage: String?) {
        guard var rec = getRecord(id) else { return }
        rec.pending = false
        rec.failed = failed
        rec.cancelled = cancelled
        rec.fromCache = fromCache
        if let msg = errorMessage { rec.errorMessage = msg }
        // eventTimestamp is a CFAbsoluteTime in seconds, so the difference is multiplied by 1000 for ms.
        if !rec.pageTimingMerged, rec.nativeEventTimestamp > 0,
           completionTimestamp > rec.nativeEventTimestamp {
            rec.duration = (completionTimestamp - rec.nativeEventTimestamp) * 1000
        }
        setRecord(rec)
    }

    func addCookieFromStore(id: String, value: String) {
        guard var rec = getRecord(id) else { return }
        let alreadyHas = rec.requestHeaders.contains {
            $0.name.caseInsensitiveCompare("cookie") == .orderedSame
        }
        guard !alreadyHas else { return }
        var hdrs = rec.requestHeaders
        hdrs.append(OrbitHeader(name: "Cookie", value: value + " (from cookie store)"))
        hdrs.sort { $0.name.lowercased() < $1.name.lowercased() }
        rec.requestHeaders = hdrs
        rec.cookieFromStore = true
        setRecord(rec)
    }

    func richRecord(id: String) -> NetRecord? {
        getRecord(id)
    }

    private func handleJSEntry(_ entry: [String: Any], frame: OrbitInspectFrame) {
        let kind = OrbitInspectDecode.string(entry, "k")
        switch kind {

        case "req":
            let id = OrbitInspectDecode.string(entry, "id")
            guard !id.isEmpty else { return }
            let url = OrbitInspectDecode.string(entry, "url")
            let method = OrbitInspectDecode.string(entry, "method")
            let src = OrbitInspectDecode.string(entry, "src")
            let startMs = OrbitInspectDecode.number(entry, "t") ?? 0
            let initiatorRaw = OrbitInspectDecode.string(entry, "initiator")
            let reqHeaders = OrbitInspectDecode.stringMap(entry, "headers")
            let bodyInfo = OrbitInspectDecode.object(entry, "body")
            let stack = initiatorRaw.split(separator: "\n").map(String.init)

            if let nativeIdx = findUnmergedNativeRecord(url: url) {
                var rec = _all[nativeIdx].rich
                rec.startTime = startMs
                rec.initiatorStack = stack
                // Native headers win: they carry the real Cookie, so page headers only supplement them.
                if rec.requestHeaders.isEmpty {
                    rec.requestHeaders = reqHeaders.map { OrbitHeader(name: $0.key, value: $0.value) }
                        .sorted { $0.name.lowercased() < $1.name.lowercased() }
                }
                rec.requestBodySummary = bodyInfo.flatMap { decodeBodyInfo($0) }
                rec.pageTimingMerged = true
                _all.alias(id, toPosition: nativeIdx)
                store(rec, at: nativeIdx)
            } else {
                guard isRecording else { return }
                var rec = NetRecord(id: id)
                rec.url = url
                rec.method = method.isEmpty ? "GET" : method.uppercased()
                rec.startTime = startMs
                rec.isMainFrame = frame.isMain
                rec.initiatorStack = stack
                rec.requestHeaders = reqHeaders.map { OrbitHeader(name: $0.key, value: $0.value) }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
                rec.requestBodySummary = bodyInfo.flatMap { decodeBodyInfo($0) }
                rec.resourceType = src == "xhr" ? "fetch" : (src == "beacon" ? "ping" : "fetch")
                setRecord(rec)
            }

        case "resp_headers":
            let id = OrbitInspectDecode.string(entry, "id")
            guard var rec = getRecord(id) else { return }
            let status = OrbitInspectDecode.integer(entry, "status")
            let headers = OrbitInspectDecode.stringMap(entry, "headers")
            let mime = OrbitInspectDecode.string(entry, "mime")
            let url = OrbitInspectDecode.string(entry, "url")
            let dur = OrbitInspectDecode.number(entry, "dur")
            if rec.status == 0 { rec.status = status }
            if rec.responseHeaders.isEmpty && !headers.isEmpty {
                rec.responseHeaders = headers.map { OrbitHeader(name: $0.key, value: $0.value) }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
            }
            if !mime.isEmpty && rec.mimeType.isEmpty { rec.mimeType = mime }
            if !url.isEmpty { rec.url = url }
            if let d = dur, rec.duration == nil { rec.duration = d }
            setRecord(rec)

        case "resp_body":
            let id = OrbitInspectDecode.string(entry, "id")
            guard var rec = getRecord(id) else { return }
            rec.responseBody = OrbitInspectDecode.string(entry, "body")
            rec.responseBodyTruncated = OrbitInspectDecode.bool(entry, "truncated")
            setRecord(rec)

        case "done":
            let id = OrbitInspectDecode.string(entry, "id")
            guard var rec = getRecord(id) else { return }
            rec.pending = false
            if OrbitInspectDecode.bool(entry, "failed") { rec.failed = true }
            if OrbitInspectDecode.bool(entry, "cancelled") { rec.cancelled = true }
            if let e = OrbitInspectDecode.optionalString(entry, "err") { rec.errorMessage = e }
            setRecord(rec)

        case "timing":
            let url = OrbitInspectDecode.string(entry, "url")
            guard !url.isEmpty else { return }
            let timing = decodeTimingEntry(entry)
            if let idx = findBestMatchRecord(url: url, approxStartMs: timing.startTime) {
                var rec = _all[idx].rich
                rec.timingRaw = timing
                rec.timingBreakdown = OrbitNetworkLogic.phases(from: timing)
                if rec.startTime == nil { rec.startTime = timing.startTime }
                if (rec.duration == nil || rec.duration == 0) && timing.duration > 0 {
                    rec.duration = timing.duration
                }
                if rec.transferSize == nil && timing.transferSize > 0 {
                    rec.transferSize = timing.transferSize
                }
                if rec.bodySize == nil && timing.encodedBodySize > 0 {
                    rec.bodySize = timing.encodedBodySize
                }
                if rec.protocolName == nil && !timing.nextHopProtocol.isEmpty {
                    rec.protocolName = timing.nextHopProtocol
                }
                rec.pageTimingMerged = true
                store(rec, at: idx)
            }

        case "ws_open":
            let id = OrbitInspectDecode.string(entry, "id")
            guard !id.isEmpty, isRecording else { return }
            var rec = NetRecord(id: id)
            rec.url = OrbitInspectDecode.string(entry, "url")
            rec.method = "GET"
            rec.resourceType = "websocket"
            rec.startTime = OrbitInspectDecode.number(entry, "t")
            rec.isMainFrame = frame.isMain
            rec.pending = true
            setRecord(rec)

        case "ws_state":
            let id = OrbitInspectDecode.string(entry, "id")
            guard var rec = getRecord(id) else { return }
            let state = OrbitInspectDecode.string(entry, "state")
            rec.wsState = state
            if state == "closed" || state == "error" {
                rec.pending = false
                rec.failed = state == "error"
                if let start = rec.startTime, let t = OrbitInspectDecode.number(entry, "t") {
                    rec.duration = t - start
                }
            }
            setRecord(rec)

        case "ws_frame":
            let id = OrbitInspectDecode.string(entry, "id")
            guard var rec = getRecord(id) else { return }
            if rec.wsFrames.count >= NetRecord.maxStreamItems { rec.wsFrames.removeFirst(rec.wsFrames.count - NetRecord.maxStreamItems + 1) }
            rec.wsFrames.append(NetWSFrame(
                direction: OrbitInspectDecode.string(entry, "dir"),
                data: OrbitInspectDecode.string(entry, "data"),
                binary: OrbitInspectDecode.bool(entry, "binary"),
                length: OrbitInspectDecode.integer(entry, "len"),
                time: OrbitInspectDecode.number(entry, "t") ?? 0))
            setRecord(rec)

        case "sse_open":
            let id = OrbitInspectDecode.string(entry, "id")
            guard !id.isEmpty, isRecording else { return }
            var rec = NetRecord(id: id)
            rec.url = OrbitInspectDecode.string(entry, "url")
            rec.method = "GET"
            rec.resourceType = "eventsource"
            rec.startTime = OrbitInspectDecode.number(entry, "t")
            rec.isMainFrame = frame.isMain
            setRecord(rec)

        case "sse_msg":
            let id = OrbitInspectDecode.string(entry, "id")
            guard var rec = getRecord(id) else { return }
            if rec.sseMessages.count >= NetRecord.maxStreamItems { rec.sseMessages.removeFirst(rec.sseMessages.count - NetRecord.maxStreamItems + 1) }
            rec.sseMessages.append(NetSSEMessage(
                event: OrbitInspectDecode.string(entry, "event"),
                data: OrbitInspectDecode.string(entry, "data"),
                time: OrbitInspectDecode.number(entry, "t") ?? 0))
            setRecord(rec)

        default: break
        }
    }

    private func handleNavTiming(_ obj: [String: Any]) {
        let origin = OrbitInspectDecode.number(obj, "origin") ?? 0
        let dcl = OrbitInspectDecode.number(obj, "dcl")
        let load = OrbitInspectDecode.number(obj, "load")
        let fcp = OrbitInspectDecode.number(obj, "fcp")
        let lcp = OrbitInspectDecode.number(obj, "lcp")
        navigationTiming = NetNavigationTiming(timeOriginMs: origin, dclMs: dcl, loadMs: load,
                                               fcpMs: fcp, lcpMs: lcp)
        markDirty()
    }

    private func getRecord(_ id: String) -> NetRecord? {
        _all[id: id]?.rich
    }

    private func setRecord(_ record: NetRecord) {
        if let idx = _all.position(forID: record.id) {
            store(record, at: idx)
        } else {
            _all.append(Entry(record))
            markDirty()
        }
    }

    private func store(_ record: NetRecord, at idx: Int) {
        _all[idx] = Entry(record)
        markDirty()
    }

    private func markDirty() {
        derivedDirty = true
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            self?.flushScheduled = false
            self?.flushIfDirty()
        }
    }

    func flushIfDirty() {
        if derivedDirty { rebuildFiltered() }
    }

    private func provisionalMainDocumentIndex(url: String) -> Int? {
        for i in stride(from: _all.count - 1, through: 0, by: -1) {
            let rec = _all[i].rich
            guard rec.pending, rec.isMainFrame else { continue }
            guard rec.resourceType == "document" || rec.resourceType == "main_frame" || rec.id.hasPrefix("nav-") else { continue }
            if url.isEmpty || rec.url == url { return i }
        }
        return nil
    }

    private func findUnmergedNativeRecord(url: String) -> Int? {
        for i in stride(from: _all.count - 1, through: 0, by: -1) {
            let rec = _all[i].rich
            guard !rec.id.hasPrefix("js-"), !rec.pageTimingMerged, rec.url == url else { continue }
            return i
        }
        return nil
    }

    private func findUnmergedPageRecord(url: String, method: String) -> Int? {
        for i in stride(from: _all.count - 1, through: 0, by: -1) {
            let rec = _all[i].rich
            // Only a load still in flight: a finished one (say, blocked before it reached the network) is not this load.
            guard rec.id.hasPrefix("js-"), rec.pending, rec.resourceType == "fetch" || rec.resourceType == "ping" else { continue }
            guard rec.url == url, rec.method.caseInsensitiveCompare(method) == .orderedSame else { continue }
            return i
        }
        return nil
    }

    private func findBestMatchRecord(url: String, approxStartMs: Double) -> Int? {
        let urlBase = url.prefix { $0 != "?" }
        var bestIdx: Int? = nil
        var bestDiff = Double.greatestFiniteMagnitude
        for i in 0..<_all.count {
            let rec = _all[i].rich
            guard rec.url.prefix(while: { $0 != "?" }) == urlBase || rec.url == url else { continue }
            if let st = rec.startTime {
                let diff = abs(st - approxStartMs)
                if diff < bestDiff { bestDiff = diff; bestIdx = i }
            } else if bestIdx == nil {
                bestIdx = i
            }
        }
        return bestIdx
    }

    private func rebuildFiltered() {
        derivedDirty = false
        let tokens = OrbitNetworkLogic.parseFilterQuery(searchQuery)
        let pageHost = URL(string: session?.pageURL ?? "")?.host
        let published = _all.map(\.pub)
        records = published

        var filtered = published.filter { r in
            if typeFilter != "all" {
                let canon = OrbitNetworkLogic.canonicalType(resourceType: r.resourceType, mimeType: r.mimeType)
                if canon != typeFilter { return false }
            }
            if hideDataURLs && r.url.hasPrefix("data:") { return false }
            if showOnlyFailed && !r.failed { return false }
            if showThirdPartyOnly, let host = pageHost {
                if URL(string: r.url)?.host == host { return false }
            }
            if let range = timeRange, let t = r.startTime, !range.contains(t) { return false }
            if !tokens.isEmpty {
                let matches = OrbitNetworkLogic.matchesFilter(r, tokens: tokens)
                if invertFilter ? matches : !matches { return false }
            }
            return true
        }

        switch sortColumn {
        case "status":
            filtered.sort { sortAscending ? $0.status < $1.status : $0.status > $1.status }
        case "method":
            filtered.sort { sortAscending ? $0.method < $1.method : $0.method > $1.method }
        case "type":
            filtered.sort { sortAscending ? $0.resourceType < $1.resourceType : $0.resourceType > $1.resourceType }
        case "size":
            filtered.sort {
                let a = $0.transferSize ?? 0; let b = $1.transferSize ?? 0
                return sortAscending ? a < b : a > b
            }
        case "time":
            filtered.sort {
                let a = $0.duration ?? 0; let b = $1.duration ?? 0
                return sortAscending ? a < b : a > b
            }
        case "domain":
            filtered.sort {
                let a = URL(string: $0.url)?.host ?? ""; let b = URL(string: $1.url)?.host ?? ""
                return sortAscending ? a < b : a > b
            }
        default: break
        }

        filteredRecords = filtered
        typeCounts = OrbitNetworkLogic.typeCounts(published)
        summary = OrbitNetworkLogic.summary(all: published, filtered: filtered,
                                             dclMs: navigationTiming?.dclMs,
                                             loadMs: navigationTiming?.loadMs)
    }


    private func decodeTimingEntry(_ e: [String: Any]) -> NetResourceTimingRaw {
        func d(_ k: String) -> Double { OrbitInspectDecode.number(e, k) ?? 0 }
        func i(_ k: String) -> Int { OrbitInspectDecode.integer(e, k) }
        let serverTiming = OrbitInspectDecode.objects(e, "serverTiming").map { st -> NetServerTimingEntry in
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

    private func decodeBodyInfo(_ obj: [String: Any]) -> String? {
        let type = OrbitInspectDecode.string(obj, "type")
        switch type {
        case "string":
            return "Text: \(OrbitDevToolsFormat.bytes(OrbitInspectDecode.integer(obj, "size")))"
        case "FormData":
            let n = OrbitInspectDecode.integer(obj, "fields")
            return "FormData: \(n) field\(n == 1 ? "" : "s")"
        case "URLSearchParams":
            return "URLSearchParams: \(OrbitDevToolsFormat.bytes(OrbitInspectDecode.integer(obj, "size")))"
        case "Blob":
            return "Blob: \(OrbitDevToolsFormat.bytes(OrbitInspectDecode.integer(obj, "size")))"
        case "ArrayBuffer":
            return "ArrayBuffer: \(OrbitDevToolsFormat.bytes(OrbitInspectDecode.integer(obj, "size")))"
        default: return nil
        }
    }
}
