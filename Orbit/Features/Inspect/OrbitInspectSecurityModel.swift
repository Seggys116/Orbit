// Everything shown is computed from these inputs by OrbitSecurityLogic, so the pane and Lighthouse always agree.

import Foundation
import WebKit

@MainActor
@Observable
final class OrbitSecurityModel: OrbitInspectModule {
    @ObservationIgnored weak var session: OrbitInspectSession?

    var messageTypes: Set<String> { ["sec.page"] }

    /// The commit hook only records the trust; the chain is described and evaluated off the main thread the first time these are read.
    var certificates: [OrbitSecurityCertificate] {
        resolveConnectionIfNeeded()
        return resolvedCertificates
    }

    var trust: OrbitSecurityTrust {
        resolveConnectionIfNeeded()
        return resolvedTrust
    }

    private var resolvedCertificates: [OrbitSecurityCertificate] = []
    private var resolvedTrust: OrbitSecurityTrust = .unavailable
    @ObservationIgnored private var pendingConnection: (trust: OrbitSecuritySupport.TrustHandle, host: String)?
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var resolvingGeneration: Int?
    private(set) var hasOnlySecureContent: Bool?

    private(set) var documentURL: String?
    private(set) var documentStatus: Int?
    private(set) var documentHeaders: [String: String]?

    private(set) var metaCSP: [String] = []
    private(set) var metaReferrer: String?
    private(set) var forms: [OrbitSecurityForm] = []
    private(set) var frames: [OrbitSecurityFrame] = []
    private(set) var domReferences: [OrbitSecurityRequest] = []
    private(set) var scripts: [OrbitSecurityScript] = []
    private(set) var links: [OrbitSecurityLink] = []
    private(set) var libraries: [LHLibrary] = []
    private(set) var isSecureContext: Bool?
    private(set) var pageDataReceived = false

    var expandedCheckIDs: Set<String> = []
    var expandedCertificateIndexes: Set<Int> = [0]

    /// The inputs as they are right now. Lighthouse calls this too, so both tools grade the same evidence.
    func currentInput() -> OrbitSecurityInput {
        let pageURL = [session?.pageURL, session?.contents?.webView.url?.absoluteString]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""

        var headers = documentHeaders
        var requests: [OrbitSecurityRequest] = []
        if let records = session?.network.records {
            if headers == nil {
                let document = records.last {
                    $0.isMainFrame && ($0.resourceType == "document" || $0.resourceType == "main_frame")
                        && !$0.responseHeaders.isEmpty && Self.sameDocument($0.url, pageURL)
                }
                if let document { headers = Self.lowercased(document.responseHeaders) }
            }
            requests = records.compactMap { record in
                guard !(record.isMainFrame && record.resourceType == "document"), !record.url.isEmpty else { return nil }
                return OrbitSecurityRequest(url: record.url, type: record.resourceType)
            }
        }

        return OrbitSecurityInput(
            pageURL: pageURL,
            certificates: certificates,
            trust: trust,
            hasOnlySecureContent: hasOnlySecureContent,
            documentHeaders: headers,
            metaCSP: metaCSP,
            metaReferrer: metaReferrer,
            requests: requests,
            domReferences: domReferences,
            forms: forms,
            frames: frames,
            scripts: scripts,
            links: links,
            libraries: libraries,
            cookies: session?.application.cookieRecords ?? []
        )
    }

    var report: OrbitSecurityReport {
        OrbitSecurityLogic.evaluate(currentInput())
    }


    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {
        guard type == "sec.page", frame.isMain else { return }
        pageDataReceived = true
        metaCSP = OrbitInspectDecode.strings(object, "metaCSP").filter { !$0.isEmpty }
        metaReferrer = OrbitInspectDecode.optionalString(object, "metaReferrer")
        isSecureContext = OrbitInspectDecode.bool(object, "secureContext")
        forms = OrbitInspectDecode.objects(object, "forms").map { entry in
            OrbitSecurityForm(
                action: OrbitInspectDecode.string(entry, "action"),
                method: OrbitInspectDecode.string(entry, "method"),
                hasPassword: OrbitInspectDecode.bool(entry, "pw"),
                nodeID: OrbitInspectDecode.integer(entry, "id"),
                selector: OrbitInspectDecode.string(entry, "sel")
            )
        }
        frames = OrbitInspectDecode.objects(object, "frames").map { entry in
            OrbitSecurityFrame(
                src: OrbitInspectDecode.string(entry, "src"),
                isSandboxed: OrbitInspectDecode.bool(entry, "sandbox"),
                isCrossOrigin: OrbitInspectDecode.bool(entry, "cross"),
                nodeID: OrbitInspectDecode.integer(entry, "id"),
                selector: OrbitInspectDecode.string(entry, "sel")
            )
        }
        scripts = OrbitInspectDecode.objects(object, "scripts").map { entry in
            OrbitSecurityScript(
                url: OrbitInspectDecode.string(entry, "url"),
                tag: OrbitInspectDecode.string(entry, "tag"),
                hasIntegrity: OrbitInspectDecode.bool(entry, "sri"),
                nodeID: OrbitInspectDecode.integer(entry, "id"),
                selector: OrbitInspectDecode.string(entry, "sel")
            )
        }
        links = OrbitInspectDecode.objects(object, "links").map { entry in
            OrbitSecurityLink(
                href: OrbitInspectDecode.string(entry, "href"),
                rel: OrbitInspectDecode.string(entry, "rel"),
                nodeID: OrbitInspectDecode.integer(entry, "id"),
                selector: OrbitInspectDecode.string(entry, "sel")
            )
        }
        libraries = OrbitInspectDecode.objects(object, "libs").map { entry in
            LHLibrary(
                name: OrbitInspectDecode.string(entry, "name"),
                version: OrbitInspectDecode.optionalString(entry, "version"),
                evidence: [OrbitInspectDecode.string(entry, "ev")].filter { !$0.isEmpty }
            )
        }
        domReferences = OrbitInspectDecode.objects(object, "refs").map { entry in
            OrbitSecurityRequest(
                url: OrbitInspectDecode.string(entry, "url"),
                type: OrbitInspectDecode.string(entry, "type"),
                nodeID: OrbitInspectDecode.integer(entry, "id"),
                selector: OrbitInspectDecode.string(entry, "sel")
            )
        }
    }

    func pageDidReset(preservingLog: Bool) {
        metaCSP = []
        metaReferrer = nil
        forms = []
        frames = []
        domReferences = []
        scripts = []
        links = []
        libraries = []
        isSecureContext = nil
        pageDataReceived = false
        // The response and the TLS chain arrive before the page agent says hello. Keep them when they belong to this document.
        if let documentURL, let page = session?.pageURL, !page.isEmpty, !Self.sameDocument(documentURL, page) {
            clearNative()
        }
    }

    func panelDidAppear(force: Bool) {
        session?.command(["op": "sec.collect"])
        session?.application.loadCookiesNative()
        if let webView = session?.contents?.webView { readConnection(from: webView) }
    }

    func noteDocumentResponse(_ response: HTTPURLResponse) {
        guard let scheme = response.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        clearNative()
        documentURL = response.url?.absoluteString
        documentStatus = response.statusCode
        documentHeaders = Self.lowercased(response.allHeaderFields.map {
            OrbitHeader(name: "\($0.key)", value: "\($0.value)")
        })
    }

    func documentDidCommit(webView: WKWebView) {
        readConnection(from: webView)
    }

    func documentDidFinish(webView: WKWebView) {
        hasOnlySecureContent = webView.hasOnlySecureContent
    }

    private func readConnection(from webView: WKWebView) {
        hasOnlySecureContent = webView.hasOnlySecureContent
        connectionGeneration += 1
        guard let url = webView.url, url.scheme?.lowercased() == "https", let host = url.host,
              let serverTrust = webView.serverTrust else {
            pendingConnection = nil
            resolvedCertificates = []
            resolvedTrust = .unavailable
            return
        }
        pendingConnection = (OrbitSecuritySupport.TrustHandle(trust: serverTrust), host)
    }

    /// Called when the inspector opens so the chain is ready before Lighthouse or the Security pane reads it.
    func prefetchConnection() {
        resolveConnectionIfNeeded()
    }

    /// Starts the background snapshot for the latest recorded trust. A newer commit supersedes an in-flight result.
    private func resolveConnectionIfNeeded() {
        guard let pending = pendingConnection, resolvingGeneration != connectionGeneration else { return }
        let generation = connectionGeneration
        resolvingGeneration = generation
        OrbitSecuritySupport.snapshotInBackground(pending.trust, host: pending.host) { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self, self.connectionGeneration == generation else { return }
                self.pendingConnection = nil
                self.resolvingGeneration = nil
                self.resolvedCertificates = snapshot.certificates
                self.resolvedTrust = snapshot.trust
            }
        }
    }

    private func clearNative() {
        connectionGeneration += 1
        pendingConnection = nil
        resolvedCertificates = []
        resolvedTrust = .unavailable
        hasOnlySecureContent = nil
        documentURL = nil
        documentStatus = nil
        documentHeaders = nil
    }


    func toggleExpanded(checkID: String) {
        if expandedCheckIDs.contains(checkID) {
            expandedCheckIDs.remove(checkID)
        } else {
            expandedCheckIDs.insert(checkID)
        }
    }

    func toggleCertificate(index: Int) {
        if expandedCertificateIndexes.contains(index) {
            expandedCertificateIndexes.remove(index)
        } else {
            expandedCertificateIndexes.insert(index)
        }
    }

    func copyReport() {
        session?.copy(OrbitSecurityLogic.summaryText(report))
    }

    private static func lowercased(_ headers: [OrbitHeader]) -> [String: String] {
        var map: [String: String] = [:]
        for header in headers { map[header.name.lowercased()] = header.value }
        return map
    }

    /// Same scheme, host, port and path. Fragments and queries do not make a different document for header purposes.
    private static func sameDocument(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        guard let a = URL(string: left), let b = URL(string: right) else { return false }
        let pathA = a.path.isEmpty ? "/" : a.path
        let pathB = b.path.isEmpty ? "/" : b.path
        return a.scheme == b.scheme && a.host == b.host && a.port == b.port && pathA == pathB
    }
}
