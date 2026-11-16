
import Foundation
import WebKit


struct NetWSFrame: Identifiable, Sendable {
    var id: UUID = UUID()
    var direction: String = "in"   // "in" = received, "out" = sent
    var data: String = ""
    var binary: Bool = false
    var length: Int = 0
    var time: Double = 0           // performance.now() when the frame arrived
}

struct NetSSEMessage: Identifiable, Sendable {
    var id: UUID = UUID()
    var event: String = ""
    var data: String = ""
    var time: Double = 0
}

struct NetRedirectHop: Sendable {
    var fromURL: String = ""
    var toURL: String = ""
    var status: Int = 0
    var responseHeaders: [OrbitHeader] = []
}

struct NetNavigationTiming: Sendable, Equatable {
    var timeOriginMs: Double = 0   // performance.timeOrigin (epoch ms)
    var dclMs: Double? = nil       // DOMContentLoaded relative to navigationStart (ms)
    var loadMs: Double? = nil      // Load event relative to navigationStart (ms)
    var fcpMs: Double? = nil
    var lcpMs: Double? = nil
}

struct NetRecord: Identifiable, Sendable {
    /// The oldest frames and messages go first so a chatty socket open for hours cannot grow without bound.
    static let maxStreamItems = 1000

    var id: String                              // native resourceLoadID string, or "js-<n>-<epoch>" for JS-only
    var url: String = ""
    var method: String = "GET"
    var status: Int = 0
    var statusText: String = ""
    var resourceType: String = "other"
    var mimeType: String = ""
    var requestHeaders: [OrbitHeader] = []
    var responseHeaders: [OrbitHeader] = []
    var transferSize: Int? = nil
    var bodySize: Int? = nil
    var startTime: Double? = nil               // performance.now() (ms) when available
    var duration: Double? = nil
    var fromCache: Bool = false
    var diskCache: Bool = false
    var failed: Bool = false
    var cancelled: Bool = false
    var pending: Bool = true
    var isMainFrame: Bool = true
    var initiatorURL: String? = nil
    var initiatorStack: [String] = []
    var protocolName: String? = nil
    var remoteAddress: String? = nil
    var timingRaw: NetResourceTimingRaw? = nil
    var timingBreakdown: NetTimingBreakdown? = nil
    var requestBody: NetRequestBody? = nil
    var responseBody: String? = nil
    var responseBodyTruncated: Bool = false
    /// The page hook's code for why it did not capture the response body: "closed", "opaque", "stream", "type", "responseType", "empty" or "unreadable".
    var responseBodySkip: String = ""
    /// "fetch", "xhr" or "beacon" when the page's own hook reported the request.
    var jsSource: String = ""
    /// fetch Response.type: "basic", "cors", "opaque" and so on.
    var responseType: String = ""
    /// True once WebKit's own response headers were stored, which is the only source of Set-Cookie.
    var nativeResponseSeen: Bool = false
    var wsFrames: [NetWSFrame] = []
    var wsState: String = ""
    var sseMessages: [NetSSEMessage] = []
    var redirectChain: [NetRedirectHop] = []
    var nativeEventTimestamp: Double = 0
    var pageTimingMerged: Bool = false
    var cookieFromStore: Bool = false
    var errorMessage: String? = nil

    func asPublicRecord() -> OrbitNetworkRecord {
        let canon = OrbitNetworkLogic.canonicalType(resourceType: resourceType, mimeType: mimeType)
        let st = statusText.isEmpty ? OrbitNetworkLogic.statusText(for: status) : statusText
        return OrbitNetworkRecord(
            id: id,
            url: url,
            method: method,
            status: status,
            statusText: st,
            resourceType: canon,
            mimeType: mimeType,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            transferSize: transferSize,
            bodySize: bodySize,
            startTime: startTime,
            duration: duration,
            fromCache: fromCache,
            failed: failed,
            isMainFrame: isMainFrame,
            initiatorURL: initiatorURL,
            protocolName: protocolName
        )
    }

    var requestCookies: [NetCookieParsed] {
        guard let hdr = requestHeaders.first(where: { $0.name.caseInsensitiveCompare("cookie") == .orderedSame }) else { return [] }
        return OrbitNetworkLogic.parseCookieHeader(hdr.value)
    }

    var responseCookies: [NetSetCookieParsed] {
        responseHeaders
            .filter { $0.name.caseInsensitiveCompare("set-cookie") == .orderedSame }
            .flatMap { OrbitNetworkLogic.splitSetCookieHeader($0.value) }
            .map { OrbitNetworkLogic.parseSetCookieHeader($0) }
    }

    var initiatorFrames: [NetStackFrame] {
        OrbitNetworkLogic.stackFrames(initiatorStack)
    }

    /// The timing API's initiator type when it reported one, which is the only initiator WebKit gives for loads that did not start from fetch or XHR.
    var timingInitiatorType: String {
        timingRaw?.initiatorType ?? ""
    }
}

/// Subresources arrive through WebKit's private resource-load delegate; the main document arrives through the navigation delegate instead.
enum OrbitInspectNativeNetwork {

    @MainActor
    static func requestSent(contents: WebKitWebContents, info: NSObject, request: URLRequest) {
        guard let url = request.url else { return }
        let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
        let net = session.network
        let loadID = String(kvcUInt64(info, "resourceLoadID"))
        let isMain = kvcIsMain(info)
        let timestamp = kvcDouble(info, "eventTimestamp")

        var headers = (request.allHTTPHeaderFields ?? [:])
            .map { OrbitHeader(name: $0.key, value: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        if isMain, net.adoptNativeMainDocument(
            loadID: loadID, url: url.absoluteString, method: request.httpMethod ?? "GET",
            headers: headers, timestamp: timestamp
        ) {
            supplementCookies(contents: contents, session: session, url: url, loadID: loadID, headers: headers)
            return
        }

        var record = NetRecord(id: loadID)
        record.url = url.absoluteString
        record.method = request.httpMethod ?? "GET"
        record.resourceType = nativeType(info, isMainFrame: isMain)
        record.isMainFrame = isMain
        record.nativeEventTimestamp = timestamp
        record.requestHeaders = headers
        record.requestBody = nativeBody(request)
        record.pending = true

        net.nativeRequestSent(record)
        supplementCookies(contents: contents, session: session, url: url, loadID: loadID, headers: headers)
    }

    @MainActor
    static func mainFrameWillLoad(contents: WebKitWebContents, request: URLRequest) {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
        let headers = (request.allHTTPHeaderFields ?? [:])
            .map { OrbitHeader(name: $0.key, value: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        session.network.noteMainFrameRequest(
            url: url, method: request.httpMethod ?? "GET", headers: headers, body: nativeBody(request))
    }

    /// WebKit usually strips the body from the requests it reports, so this is nil more often than not; the page hooks fill the gap.
    private static func nativeBody(_ request: URLRequest) -> NetRequestBody? {
        guard let data = request.httpBody, !data.isEmpty else { return nil }
        var body = NetRequestBody(kind: "native", size: data.count)
        if data.count > 65536 {
            body.note = "Large payload; its content is not captured."
        } else if let text = String(data: data, encoding: .utf8) {
            body.text = text
        } else {
            body.note = "Binary payload; its content cannot be shown as text."
        }
        return body
    }

    @MainActor
    static func mainFrameDidReceive(contents: WebKitWebContents, response: HTTPURLResponse) {
        guard let scheme = response.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
        session.network.noteMainFrameResponse(response)
    }

    @MainActor
    private static func supplementCookies(
        contents: WebKitWebContents, session: OrbitInspectSession, url: URL, loadID: String, headers: [OrbitHeader]
    ) {
        // Reading the whole cookie store for each request is only worth it when someone can see the result.
        guard session.isPresented else { return }
        let hasCookieHeader = headers.contains { $0.name.caseInsensitiveCompare("cookie") == .orderedSame }
        guard !hasCookieHeader else { return }
        Task { @MainActor [weak session, weak contents] in
            guard let contents else { return }
            let matching = await storeCookies(contents: contents, url: url)
            guard !matching.isEmpty else { return }
            let cookieVal = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            session?.network.addCookieFromStore(id: loadID, value: cookieVal)
        }
    }

    /// Cookies in the page's cookie store that match `url`, HttpOnly ones included; this is the only place a script-invisible Cookie header can be derived from.
    @MainActor
    static func storeCookies(contents: WebKitWebContents, url: URL) async -> [NetStoreCookie] {
        let cookieStore = contents.webView.configuration.websiteDataStore.httpCookieStore
        let all: [HTTPCookie] = await withCheckedContinuation { cont in
            cookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        return OrbitNetworkLogic.matchingCookies(all, url: url)
    }

    @MainActor
    static func responseReceived(contents: WebKitWebContents, info: NSObject, response: URLResponse) {
        let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
        let loadID = String(kvcUInt64(info, "resourceLoadID"))
        let fromCache = (info.value(forKey: "loadedFromCache") as? Bool) == true

        guard let http = response as? HTTPURLResponse else {
            session.network.nativeResponseReceived(
                id: loadID, status: 0, statusText: "",
                headers: [], mimeType: response.mimeType ?? "",
                url: response.url?.absoluteString, fromCache: fromCache, expectedBodySize: nil)
            return
        }

        let status = http.statusCode
        let statusText = OrbitNetworkLogic.statusText(for: status)
        var headers = http.allHeaderFields
            .map { OrbitHeader(name: "\($0.key)", value: "\($0.value)") }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        let mime = response.mimeType ?? ""
        let expectedSize = response.expectedContentLength
        session.network.nativeResponseReceived(
            id: loadID, status: status, statusText: statusText,
            headers: headers, mimeType: mime,
            url: response.url?.absoluteString, fromCache: fromCache,
            expectedBodySize: expectedSize > 0 ? Int(expectedSize) : nil)
    }

    @MainActor
    static func redirected(contents: WebKitWebContents, info: NSObject, response: URLResponse, newRequest: URLRequest) {
        let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
        let loadID = String(kvcUInt64(info, "resourceLoadID"))
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let headers = (http?.allHeaderFields ?? [:])
            .map { OrbitHeader(name: "\($0.key)", value: "\($0.value)") }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        session.network.nativeRedirected(
            id: loadID, fromURL: response.url?.absoluteString ?? "",
            status: status, responseHeaders: headers,
            toURL: newRequest.url?.absoluteString ?? "")
    }

    @MainActor
    static func completed(contents: WebKitWebContents, info: NSObject, error: Error?, response: URLResponse?) {
        let session = OrbitDevToolsStore.shared.ensureSession(for: contents)
        let loadID = String(kvcUInt64(info, "resourceLoadID"))
        let fromCache = (info.value(forKey: "loadedFromCache") as? Bool) == true
        let isCancelled = (error as? URLError)?.code == .cancelled
        let isFailed = error != nil && !isCancelled
        session.network.nativeCompleted(
            id: loadID, failed: isFailed, cancelled: isCancelled,
            fromCache: fromCache, completionTimestamp: kvcDouble(info, "eventTimestamp"),
            errorMessage: error?.localizedDescription)
    }


    private static func kvcUInt64(_ obj: NSObject, _ key: String) -> UInt64 {
        (obj.value(forKey: key) as? NSNumber)?.uint64Value ?? 0
    }

    private static func kvcIsMain(_ obj: NSObject) -> Bool {
        let p = obj.value(forKey: "parentFrame")
        return p == nil || p is NSNull
    }

    private static func kvcDouble(_ obj: NSObject, _ key: String) -> Double {
        (obj.value(forKey: key) as? NSNumber)?.doubleValue ?? 0
    }

    private static func nativeType(_ info: NSObject, isMainFrame: Bool) -> String {
        switch (info.value(forKey: "resourceType") as? NSNumber)?.intValue ?? -1 {
        case 3: return isMainFrame ? "document" : "sub_frame"
        case 10: return "script"
        case 11: return "stylesheet"
        case 4: return "image"
        case 6: return "font"
        case 8: return "object"
        case 5, 12: return "fetch"
        case 1, 9: return "ping"
        case 2: return "csp_report"
        case 7: return "media"
        default: return "other"
        }
    }
}
