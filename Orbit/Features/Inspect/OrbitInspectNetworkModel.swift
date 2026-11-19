import Foundation
import AppKit

@MainActor
@Observable
final class OrbitNetworkModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?

    /// Every record, in arrival order. Other tools read this on demand, so it is projected lazily when the log changed while the Network panel was not on screen.
    var records: [OrbitNetworkRecord] {
        access(keyPath: \.records)
        if publishedStale {
            publishedRecords = _all.map(\.pub)
            publishedStale = false
        }
        return publishedRecords
    }

    @ObservationIgnored private var publishedRecords: [OrbitNetworkRecord] = []
    @ObservationIgnored private var publishedStale = false

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
    /// The public projection is built the first time a panel or another tool reads it, then kept for this version of the record.
    private struct Entry: Identifiable {
        private final class Projection { var value: OrbitNetworkRecord? }

        let rich: NetRecord
        private let projection = Projection()
        var id: String { rich.id }
        init(_ rich: NetRecord) {
            self.rich = rich
        }
        var pub: OrbitNetworkRecord {
            if let value = projection.value { return value }
            let value = rich.asPublicRecord()
            projection.value = value
            return value
        }
    }

    /// Ids of page-reported (js-) fetch and ping records still in flight, so a native request looks only at these instead of scanning the log.
    @ObservationIgnored private var pendingPageIDs: Set<String> = []

    private func trackPendingPage(_ record: NetRecord, replacing previousID: String? = nil) {
        if let previousID, previousID != record.id { pendingPageIDs.remove(previousID) }
        if record.id.hasPrefix("js-"), record.pending, record.resourceType == "fetch" || record.resourceType == "ping" {
            pendingPageIDs.insert(record.id)
        } else {
            pendingPageIDs.remove(record.id)
        }
    }

    /// Response bodies re-read from the page on demand, keyed by record id and bounded so images cannot pile up.
    private(set) var fetchedBodies: [String: NetFetchedBody] = [:]
    /// Cookies in the cookie store that match a record's URL, looked up when the Cookies tab is shown.
    private(set) var storeCookies: [String: [NetStoreCookie]] = [:]

    @ObservationIgnored private var fetchedOrder: [String] = []
    @ObservationIgnored private var storeCookieOrder: [String] = []
    private static let maxCachedLookups = 24

    /// The page's body re-read is a real request that WebKit reports too; its URL is remembered briefly so it is not listed as a page load.
    @ObservationIgnored private var suppressedRefetches: [String: Date] = [:]
    private static let refetchSuppressionWindow: TimeInterval = 5

    /// A form post is a navigation, so its body arrives from the page's submit event, possibly before or after the navigation is recorded.
    @ObservationIgnored private var pendingForms: [(url: String, body: NetRequestBody)] = []
    private static let maxPendingForms = 8

    /// Resource-timing entries already attached to a record, so a re-delivery (panel refresh, re-attach) cannot land on another request for the same URL.
    @ObservationIgnored private var consumedTimings: Set<String> = []

    private static let logCapacity = 5000
    @ObservationIgnored private var _all = OrbitRingBuffer<Entry>(capacity: OrbitNetworkModel.logCapacity)

    /// Record ids by URL with the query removed, so a timing entry finds its candidates without scanning the log.
    /// Ids that no longer resolve, or whose URL moved elsewhere, are dropped when a lookup meets them.
    @ObservationIgnored private var idsByURLBase: [String: [String]] = [:]
    @ObservationIgnored private var indexedReferences = 0

    /// A page load is hundreds of messages, so derived state is rebuilt once per frame, not once per message.
    @ObservationIgnored private var derivedDirty = false
    @ObservationIgnored private var flushScheduled = false
    private static let flushDelay: Duration = .milliseconds(16)

    /// Overrides the session lookup for whether the Network panel is on screen; a model without a session has no other way to say so.
    @ObservationIgnored var presentationProbe: (() -> Bool)?

    /// Rebuilding the filtered table, counts and summary is only worth it while someone can see them; the log itself is always kept.
    private var isPanelPresented: Bool {
        if let presentationProbe { return presentationProbe() }
        guard let session else { return false }
        return session.isPresented && session.panel == .network
    }

    var messageTypes: Set<String> { ["net.batch", "net.nav", "net.form", "net.body"] }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        switch type {
        case "net.batch":
            for entry in OrbitInspectDecode.objects(object, "entries") {
                handleJSEntry(entry, frame: frame)
            }
        case "net.nav":
            handleNavTiming(object)
        case "net.form":
            handleFormSubmission(object)
        case "net.body":
            if let (id, body) = OrbitNetworkLogic.decodeFetchedBody(object) { setFetchedBody(body, for: id) }
        default: break
        }
    }

    func pageDidReset(preservingLog: Bool) {
        if !preservingLog {
            fetchedBodies.removeAll()
            fetchedOrder.removeAll()
            storeCookies.removeAll()
            storeCookieOrder.removeAll()
            consumedTimings.removeAll()
            // The main document is recorded before the agent's hello, which clears the log, so it must survive or the first request disappears.
            let page = session?.pageURL ?? ""
            let kept = _all.filter { entry in
                let rec = entry.rich
                guard rec.isMainFrame else { return false }
                guard rec.resourceType == "document" || rec.resourceType == "main_frame" || rec.id.hasPrefix("nav-") else { return false }
                return page.isEmpty || Self.sameDocument(rec.url, page)
            }
            _all.removeAll()
            pendingPageIDs.removeAll()
            for entry in kept { _all.append(entry) }
            rebuildTimingIndex()
            navigationTiming = nil
        }
        selectedID = nil
        if isPanelPresented {
            rebuildFiltered()
        } else {
            invalidateDerived()
        }
    }

    private static func sameDocument(_ recorded: String, _ page: String) -> Bool {
        if recorded == page { return true }
        guard let left = URL(string: recorded), let right = URL(string: page) else { return false }
        let leftPath = left.path.isEmpty ? "/" : left.path
        let rightPath = right.path.isEmpty ? "/" : right.path
        return left.scheme == right.scheme && left.host == right.host && left.port == right.port && leftPath == rightPath
    }

    func panelDidAppear(force: Bool) {
        // Changes made while the panel was hidden were not projected, so show them now, once.
        flushIfDirty()
        if force {
            session?.command(["op": "net.refresh"])
        }
    }

    func nativeRequestSent(_ record: NetRecord) {
        guard isRecording else { return }
        if consumeRefetchSuppression(url: record.url) { return }
        // The page's fetch/XHR hook can report a request before WebKit does; fold that record into this one, in the page record's row.
        if _all.position(forID: record.id) == nil, let jsIdx = findUnmergedPageRecord(url: record.url, method: record.method) {
            let page = _all[jsIdx].rich
            var merged = record
            merged.startTime = page.startTime ?? merged.startTime
            merged.initiatorStack = page.initiatorStack
            merged.initiatorURL = page.initiatorURL
            merged.jsSource = page.jsSource
            if !merged.hasRequestHeaders { merged.requestHeaders = page.requestHeaders }
            merged.requestBody = page.requestBody ?? merged.requestBody
            if merged.status == 0 { merged.status = page.status }
            if !merged.hasResponseHeaders { merged.responseHeaders = page.responseHeaders }
            if merged.mimeType.isEmpty { merged.mimeType = page.mimeType }
            if merged.duration == nil { merged.duration = page.duration }
            merged.responseBody = page.responseBody
            merged.responseBodyTruncated = page.responseBodyTruncated
            merged.responseBodySkip = page.responseBodySkip
            merged.responseType = page.responseType
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
        var record = record
        if record.requestBody == nil, record.resourceType == "sub_frame" || record.resourceType == "document" {
            record.requestBody = takePendingForm(url: record.url, method: record.method)
        }
        setRecord(record)
    }

    /// The resource-load delegate does not report the main document on current WebKit, so it is recorded from navigation policy and rebound if a callback arrives.
    func noteMainFrameRequest(url: URL, method: String, headers: [OrbitHeader], body: NetRequestBody?) {
        guard isRecording else { return }
        let absolute = url.absoluteString
        if let idx = provisionalMainDocumentIndex(url: absolute) {
            var rec = _all[idx].rich
            if rec.requestHeaders.isEmpty { rec.requestHeaders = headers }
            if !method.isEmpty { rec.method = method }
            rec.resourceType = "document"
            rec.isMainFrame = true
            if rec.requestBody == nil { rec.requestBody = body ?? takePendingForm(url: absolute, method: rec.method) }
            setRecord(rec)
            return
        }
        var record = NetRecord(id: "nav-\(UUID().uuidString)")
        record.url = absolute
        record.method = method.isEmpty ? "GET" : method
        record.resourceType = "document"
        record.isMainFrame = true
        record.requestHeaders = headers
        record.requestBody = body ?? takePendingForm(url: absolute, method: record.method)
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
            rec.nativeResponseSeen = true
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
        record.nativeResponseSeen = true
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
                                 url: String?, fromCache: Bool, expectedBodySize: Int?,
                                 headersUnsorted: Bool = false) {
        guard var rec = getRecord(id) else { return }
        rec.status = status
        rec.statusText = statusText
        rec.responseHeaderStorage = headers
        rec.responseHeadersUnsorted = headersUnsorted
        rec.nativeResponseSeen = true
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
        hdrs.append(OrbitHeader(name: "Cookie", value: value))
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
            let body = bodyInfo.flatMap { OrbitNetworkLogic.decodeRequestBody($0) }
            let scriptURL = OrbitNetworkLogic.initiatorLocation(OrbitNetworkLogic.stackFrames(stack))?.url

            if let nativeIdx = findUnmergedNativeRecord(url: url) {
                var rec = _all[nativeIdx].rich
                rec.startTime = startMs
                rec.initiatorStack = stack
                rec.initiatorURL = scriptURL
                rec.jsSource = src
                // Native headers win: they carry the real Cookie, so page headers only supplement them.
                if rec.requestHeaders.isEmpty {
                    rec.requestHeaders = reqHeaders.map { OrbitHeader(name: $0.key, value: $0.value) }
                        .sorted { $0.name.lowercased() < $1.name.lowercased() }
                }
                rec.requestBody = body ?? rec.requestBody
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
                rec.initiatorURL = scriptURL
                rec.jsSource = src
                rec.requestHeaders = reqHeaders.map { OrbitHeader(name: $0.key, value: $0.value) }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
                rec.requestBody = body
                rec.resourceType = src == "xhr" ? "fetch" : (src == "beacon" ? "ping" : "fetch")
                setRecord(rec)
            }

        case "req_body":
            let id = OrbitInspectDecode.string(entry, "id")
            guard var rec = getRecord(id),
                  let info = OrbitInspectDecode.object(entry, "body"),
                  let body = OrbitNetworkLogic.decodeRequestBody(info) else { return }
            rec.requestBody = body
            setRecord(rec)

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
            rec.responseType = OrbitInspectDecode.string(entry, "rtype")
            setRecord(rec)

        case "resp_body":
            let id = OrbitInspectDecode.string(entry, "id")
            guard var rec = getRecord(id) else { return }
            if let skip = OrbitInspectDecode.optionalString(entry, "skip") {
                rec.responseBodySkip = skip
                if rec.mimeType.isEmpty { rec.mimeType = OrbitInspectDecode.string(entry, "mime") }
            } else {
                rec.responseBody = OrbitInspectDecode.string(entry, "body")
                rec.responseBodyTruncated = OrbitInspectDecode.bool(entry, "truncated")
                rec.responseBodySkip = ""
            }
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
            let timing = OrbitNetworkLogic.decodeResourceTiming(entry)
            let timingKey = "\(url)|\(timing.startTime)|\(timing.responseEnd)"
            guard consumedTimings.insert(timingKey).inserted else { return }
            if consumedTimings.count > 20000 { consumedTimings = [timingKey] }
            if let idx = findTimingTarget(url: url, startMs: timing.startTime, isNavigation: timing.initiatorType == "navigation") {
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
            } else {
                // Nothing to attach it to yet, so a later refresh may still place it.
                consumedTimings.remove(timingKey)
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
            trackPendingPage(record)
            indexForTiming(record)
            markDirty()
        }
    }

    private func store(_ record: NetRecord, at idx: Int) {
        let previous = _all[idx].rich
        _all[idx] = Entry(record)
        trackPendingPage(record, replacing: previous.id)
        // A record already indexed under the same id and URL base needs nothing; the rest are added and the old keys are dropped lazily.
        if previous.id != record.id || (previous.url != record.url && urlBase(previous.url) != urlBase(record.url)) {
            indexForTiming(record)
        }
        markDirty()
    }

    private func markDirty() {
        derivedDirty = true
        publishedStale = true
        guard isPanelPresented, !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard let self else { return }
            self.flushScheduled = false
            // Hidden again before the frame: stay dirty, and panelDidAppear projects the log when it is shown.
            guard self.isPanelPresented else { return }
            self.flushIfDirty()
        }
    }

    /// Marks derived state out of date without projecting it, for changes made while the panel is hidden.
    private func invalidateDerived() {
        derivedDirty = true
        publishedStale = true
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
        var best: Int?
        for id in pendingPageIDs {
            guard let i = _all.position(forID: id) else { pendingPageIDs.remove(id); continue }
            let rec = _all[i].rich
            // Only a load still in flight: a finished one (say, blocked before it reached the network) is not this load.
            guard rec.id.hasPrefix("js-"), rec.pending, rec.resourceType == "fetch" || rec.resourceType == "ping" else { continue }
            guard rec.url == url, rec.method.caseInsensitiveCompare(method) == .orderedSame else { continue }
            if best == nil || i > best! { best = i }
        }
        return best
    }

    /// A timing entry belongs to a record of the same URL that has no timing yet; exact URLs win over ones that differ only in the query.
    private func findTimingTarget(url: String, startMs: Double, isNavigation: Bool) -> Int? {
        let base = urlBase(url)
        let key = String(base)
        guard let bucket = idsByURLBase[key] else { return nil }

        // Resolve the bucket to live positions, dropping ids that were evicted, retimed or moved to another URL.
        var seen = Set<Int>()
        var positions: [Int] = []
        var live: [String] = []
        live.reserveCapacity(bucket.count)
        for id in bucket {
            guard let i = _all.position(forID: id) else { continue }
            let rec = _all[i].rich
            guard rec.timingRaw == nil, urlBase(rec.url) == base else { continue }
            live.append(id)
            if seen.insert(i).inserted { positions.append(i) }
        }
        if live.count != bucket.count {
            indexedReferences -= bucket.count - live.count
            if live.isEmpty { idsByURLBase.removeValue(forKey: key) } else { idsByURLBase[key] = live }
        }
        // Positions are visited in log order so ties resolve to the earliest record, as a scan of the whole log would.
        positions.sort()

        var exact: [Int] = []
        var sameBase: [Int] = []
        for i in positions {
            let rec = _all[i].rich
            guard rec.timingRaw == nil else { continue }
            if isNavigation {
                let isDocument = rec.resourceType == "document" || rec.resourceType == "main_frame"
                    || rec.resourceType == "sub_frame" || rec.id.hasPrefix("nav-")
                guard isDocument else { continue }
            }
            if rec.url == url { exact.append(i) }
            else { sameBase.append(i) }
        }
        let pool = exact.isEmpty ? sameBase : exact
        var best: Int? = nil
        var bestDiff = Double.greatestFiniteMagnitude
        for i in pool {
            guard let start = _all[i].rich.startTime else { continue }
            let diff = abs(start - startMs)
            if diff < bestDiff { bestDiff = diff; best = i }
        }
        return best ?? pool.first
    }

    private func urlBase(_ url: String) -> Substring {
        url.prefix { $0 != "?" }
    }

    private func indexForTiming(_ record: NetRecord) {
        guard record.timingRaw == nil else { return }
        idsByURLBase[String(urlBase(record.url)), default: []].append(record.id)
        indexedReferences += 1
        // Evicted and re-keyed records leave dead ids behind; sweeping the whole index now and then bounds them.
        if indexedReferences > Self.logCapacity * 3 { rebuildTimingIndex() }
    }

    private func rebuildTimingIndex() {
        idsByURLBase.removeAll(keepingCapacity: true)
        indexedReferences = 0
        for i in 0..<_all.count {
            let rec = _all[i].rich
            guard rec.timingRaw == nil else { continue }
            idsByURLBase[String(urlBase(rec.url)), default: []].append(rec.id)
            indexedReferences += 1
        }
    }

    /// Whether `url` is the page's own body re-read, which must not appear as a page request; each mark is used once.
    private func consumeRefetchSuppression(url: String) -> Bool {
        let now = Date()
        suppressedRefetches = suppressedRefetches.filter { $0.value > now }
        guard suppressedRefetches.removeValue(forKey: url) != nil else { return false }
        return true
    }

    private func takePendingForm(url: String, method: String) -> NetRequestBody? {
        guard method.caseInsensitiveCompare("POST") == .orderedSame,
              let index = pendingForms.firstIndex(where: { $0.url == url }) else { return nil }
        return pendingForms.remove(at: index).body
    }

    private func handleFormSubmission(_ object: [String: Any]) {
        guard isRecording,
              let info = OrbitInspectDecode.object(object, "body"),
              let body = OrbitNetworkLogic.decodeRequestBody(info) else { return }
        let url = OrbitInspectDecode.string(object, "url")
        // WebKit may have reported the navigation before the page's message arrived.
        for i in stride(from: _all.count - 1, through: max(0, _all.count - 20), by: -1) {
            var rec = _all[i].rich
            let isDocument = rec.resourceType == "document" || rec.resourceType == "sub_frame" || rec.id.hasPrefix("nav-")
            guard isDocument, rec.requestBody == nil, rec.url == url,
                  rec.method.caseInsensitiveCompare("POST") == .orderedSame else { continue }
            rec.requestBody = body
            store(rec, at: i)
            return
        }
        pendingForms.append((url: url, body: body))
        if pendingForms.count > Self.maxPendingForms { pendingForms.removeFirst(pendingForms.count - Self.maxPendingForms) }
    }

    private func setFetchedBody(_ body: NetFetchedBody, for id: String) {
        if fetchedBodies[id] == nil { fetchedOrder.append(id) }
        fetchedBodies[id] = body
        while fetchedOrder.count > Self.maxCachedLookups {
            fetchedBodies.removeValue(forKey: fetchedOrder.removeFirst())
        }
    }

    /// Asks the page to re-read a response body that no hook captured (scripts, styles, images, documents), once per record.
    func fetchBodyIfNeeded(id: String) {
        guard let rec = getRecord(id), rec.responseBody == nil, fetchedBodies[id] == nil,
              rec.responseBodySkip != "stream", rec.responseBodySkip != "opaque",
              case .refetch = OrbitNetworkLogic.bodyFetchability(
                method: rec.method, status: rec.status, mimeType: rec.mimeType, resourceType: rec.resourceType,
                url: rec.url, pending: rec.pending, failed: rec.failed, cancelled: rec.cancelled)
        else { return }
        setFetchedBody(.loading, for: id)
        suppressedRefetches[rec.url] = Date().addingTimeInterval(Self.refetchSuppressionWindow)
        session?.command(["op": "net.body", "id": id, "url": rec.url])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.fetchedBodies[id] == .loading else { return }
            self.setFetchedBody(.unavailable("The page did not return the body in time."), for: id)
        }
    }

    /// Looks up the cookie store for cookies matching the record's URL, used when no Cookie header was observed.
    func loadStoreCookies(id: String) async {
        guard let rec = getRecord(id), storeCookies[id] == nil,
              let contents = session?.contents, let url = URL(string: rec.url) else { return }
        let found = await OrbitInspectNativeNetwork.storeCookies(contents: contents, url: url)
        if storeCookies[id] == nil { storeCookieOrder.append(id) }
        storeCookies[id] = found
        while storeCookieOrder.count > Self.maxCachedLookups {
            storeCookies.removeValue(forKey: storeCookieOrder.removeFirst())
        }
    }

    private func rebuildFiltered() {
        derivedDirty = false
        let tokens = OrbitNetworkLogic.parseFilterQuery(searchQuery)
        let pageHost = URL(string: session?.pageURL ?? "")?.host
        let published = _all.map(\.pub)
        withMutation(keyPath: \.records) {
            publishedRecords = published
            publishedStale = false
        }

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
}
