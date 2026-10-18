import Foundation

// MARK: - Client

nonisolated public struct ChromeWebStoreClient: Sendable {

    // Omaha protocol 3.0 over POST. The legacy clients2.google.com/service/update2/crx GET (x=id=...&uc)
    // answers HTTP 204 for any prodversion older than the extension's minimum_chrome_version, which is
    // indistinguishable from "unknown extension" and is what broke installs; this endpoint answers
    // with an explicit <updatecheck status="..."> instead.
    public static let updateServiceEndpoint = URL(string: "https://update.googleapis.com/service/update2")!
    // Chrome's UA-reduced version format. Keep this on a current stable milestone: the service withholds
    // packages whose minimum_chrome_version is newer than the client claims to be.
    public static let defaultProdVersion = "150.0.0.0"
    public static let freshInstallVersion = "0.0.0.0"
    public let session: URLSession
    public let prodVersion: String
    public let maxDownloadBytes: Int
    public static let maxUpdateCheckResponseBytes = 1 * 1024 * 1024
    public let requestTimeout: TimeInterval

    public init(
        session: URLSession = .shared,
        prodVersion: String = ChromeWebStoreClient.defaultProdVersion,
        maxDownloadBytes: Int = 512 * 1024 * 1024,
        requestTimeout: TimeInterval = 30
    ) {
        self.session = session
        self.prodVersion = prodVersion
        self.maxDownloadBytes = maxDownloadBytes
        self.requestTimeout = requestTimeout
    }

    // MARK: - Request construction

    static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func escapeXMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    func updateCheckRequestBody(
        forExtensionID id: String,
        installedVersion: String?,
        requestID: UUID = UUID(),
        sessionID: UUID = UUID()
    ) -> String {
        let version = (installedVersion?.isEmpty == false ? installedVersion : nil) ?? Self.freshInstallVersion
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let prod = Self.escapeXMLAttribute(prodVersion)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <request protocol="3.0" version="chrome-\(prod)" prodversion="\(prod)" acceptformat="crx3" ismachine="0" \
        updaterversion="\(prod)" lang="en-US" requestid="{\(requestID.uuidString)}" sessionid="{\(sessionID.uuidString)}">
        <os platform="mac" arch="\(Self.hostArchitecture)" version="\(osVersion)"/>
        <app appid="\(Self.escapeXMLAttribute(id))" version="\(Self.escapeXMLAttribute(version))" installsource="ondemand">
        <updatecheck/>
        </app>
        </request>
        """
    }

    public func updateCheckRequest(forExtensionID id: String, installedVersion: String?) throws -> URLRequest {
        guard ChromeExtensionID.isValid(id) else {
            throw ChromeWebStoreError.invalidExtensionID(id)
        }
        var request = URLRequest(url: Self.updateServiceEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.httpBody = Data(updateCheckRequestBody(forExtensionID: id, installedVersion: installedVersion).utf8)
        request.setValue("text/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/xml, application/xml", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Download

    public func download(id: String, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> Data {
        let result = try await checkForUpdate(id: id, installedVersion: nil)
        guard case .updateAvailable(let info) = result else {
            throw ChromeWebStoreError.malformedUpdateResponse(
                "The update service reported no installable package for \"\(id)\" for Chrome \(prodVersion)."
            )
        }
        var request = URLRequest(url: info.downloadURL)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await fetch(request, maxBytes: maxDownloadBytes, onProgress: onProgress)
        try Self.validate(response: response, id: id)
        return data
    }

    // MARK: - Update check

    public func checkForUpdate(
        id: String,
        installedVersion: String?
    ) async throws -> ChromeWebStoreUpdateCheckResult {
        let request = try updateCheckRequest(forExtensionID: id, installedVersion: installedVersion)
        let (data, response) = try await fetch(request, maxBytes: Self.maxUpdateCheckResponseBytes)
        try Self.validate(response: response, id: id)
        return try Self.parseUpdateCheckResponse(data, id: id)
    }

    // MARK: - Shared response handling

    private func fetch(
        _ request: URLRequest,
        maxBytes: Int,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let delegate = BoundedFetchDelegate(maxBytes: maxBytes, onProgress: onProgress)
        return try await delegate.run(session: session, request: request)
    }

    static func validate(response: HTTPURLResponse, id: String) throws {
        let status = response.statusCode
        if status == 204 || status == 404 {
            throw ChromeWebStoreError.extensionNotFound(id)
        }
        guard (200..<300).contains(status) else {
            throw ChromeWebStoreError.httpStatus(status)
        }
        if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/html") {
            throw ChromeWebStoreError.unexpectedContentType(contentType)
        }
    }

    static func parseUpdateCheckResponse(_ data: Data, id: String) throws -> ChromeWebStoreUpdateCheckResult {
        let delegate = OmahaUpdateCheckXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = delegate.parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "the document was not well-formed XML"
            throw ChromeWebStoreError.malformedUpdateResponse(reason)
        }

        if let status = delegate.updateCheckStatus {
            switch status {
            case "ok":
                guard let codebaseString = delegate.resolvedCodebase, let version = delegate.version else {
                    throw ChromeWebStoreError.malformedUpdateResponse(
                        "<updatecheck status=\"ok\"> was missing its codebase or version attribute."
                    )
                }
                guard let codebase = URL(string: codebaseString), codebase.scheme?.lowercased() == "https" else {
                    throw ChromeWebStoreError.malformedUpdateResponse(
                        "<updatecheck>'s codebase (\"\(codebaseString)\") is not a valid https URL."
                    )
                }
                return .updateAvailable(ChromeWebStoreUpdateInfo(version: version, downloadURL: codebase))
            case "noupdate":
                return .upToDate
            default:
                if status.lowercased().contains("unknownapplication") {
                    throw ChromeWebStoreError.extensionNotFound(id)
                }
                throw ChromeWebStoreError.malformedUpdateResponse("Unexpected <updatecheck status=\"\(status)\">.")
            }
        }

        if let appStatus = delegate.appStatus {
            if appStatus.lowercased().contains("unknownapplication") {
                throw ChromeWebStoreError.extensionNotFound(id)
            }
            throw ChromeWebStoreError.malformedUpdateResponse("Unexpected <app status=\"\(appStatus)\">, no <updatecheck> element.")
        }

        throw ChromeWebStoreError.malformedUpdateResponse("No <app> or <updatecheck> element was found in the response.")
    }
}

// MARK: - Bounded streaming fetch

// Builds its own dedicated URLSession because neither dataTask(with:) on the injected session nor data(for:delegate:) invokes this delegate's callbacks; do not simplify back to either, or buffering becomes unbounded.
nonisolated private final class BoundedFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let onProgress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var buffer = Data()
    private var finalResponse: HTTPURLResponse?
    private var pendingFailure: ChromeWebStoreError?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var dedicatedSession: URLSession?
    private var expectedContentLength: Int64 = 0
    private var lastReportedBytes: Int64 = 0

    init(maxBytes: Int, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.maxBytes = maxBytes
        self.onProgress = onProgress
    }

    func run(session configurationSource: URLSession, request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let dedicated = URLSession(configuration: configurationSource.configuration, delegate: self, delegateQueue: nil)
            self.dedicatedSession = dedicated
            lock.unlock()
            dedicated.dataTask(with: request).resume()
        }
    }

    private func fail(_ error: ChromeWebStoreError) {
        lock.lock()
        if pendingFailure == nil {
            pendingFailure = error
        }
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(.network("The server did not respond over HTTP."))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0, response.expectedContentLength > Int64(maxBytes) {
            fail(.responseTooLarge)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        finalResponse = http
        expectedContentLength = max(response.expectedContentLength, 0)
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        let exceeded = buffer.count > maxBytes
        let received = Int64(buffer.count)
        let total = expectedContentLength
        // Throttled to roughly 1% steps (or 64KB, whichever is larger) so a large download
        // doesn't flood the reporter with hundreds of near-identical updates.
        let threshold = max(65_536, total / 100)
        let shouldReport = !exceeded && (received - lastReportedBytes >= threshold || received == total)
        if shouldReport { lastReportedBytes = received }
        lock.unlock()
        if exceeded {
            fail(.responseTooLarge)
            dataTask.cancel()
            return
        }
        if shouldReport {
            onProgress?(received, total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = pendingFailure
        let response = finalResponse
        let data = buffer
        let dedicated = dedicatedSession
        dedicatedSession = nil
        lock.unlock()

        dedicated?.finishTasksAndInvalidate()

        guard let continuation else { return }

        if let failure {
            continuation.resume(throwing: failure)
            return
        }
        if let error {
            continuation.resume(throwing: ChromeWebStoreError.network(error.localizedDescription))
            return
        }
        guard let response else {
            continuation.resume(throwing: ChromeWebStoreError.network("The request finished without producing a response."))
            return
        }
        continuation.resume(returning: (data, response))
    }
}

// MARK: - Omaha XML parsing

nonisolated private final class OmahaUpdateCheckXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var appStatus: String?
    private(set) var updateCheckStatus: String?
    private(set) var version: String?
    private(set) var parseError: Error?
    // Protocol 3.0 splits the download location: <url codebase=".../"> plus <package name="X.crx">.
    // The 2.0 shape put a complete URL in <updatecheck codebase="...">; both are accepted.
    private var legacyCodebase: String?
    private var urlCodebase: String?
    private var packageName: String?

    var resolvedCodebase: String? {
        if let legacyCodebase { return legacyCodebase }
        guard let urlCodebase else { return nil }
        guard let packageName, !packageName.isEmpty else { return urlCodebase }
        return urlCodebase.hasSuffix("/") ? urlCodebase + packageName : urlCodebase + "/" + packageName
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "app":
            appStatus = attributeDict["status"]
        case "updatecheck":
            updateCheckStatus = attributeDict["status"]
            legacyCodebase = attributeDict["codebase"]
            if let legacyVersion = attributeDict["version"] { version = legacyVersion }
        case "url":
            if urlCodebase == nil { urlCodebase = attributeDict["codebase"] }
        case "manifest":
            if let manifestVersion = attributeDict["version"] { version = manifestVersion }
        case "package":
            if packageName == nil { packageName = attributeDict["name"] }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

// MARK: - Update check result

nonisolated public struct ChromeWebStoreUpdateInfo: Sendable, Equatable {
    public let version: String
    public let downloadURL: URL

    public init(version: String, downloadURL: URL) {
        self.version = version
        self.downloadURL = downloadURL
    }
}

nonisolated public enum ChromeWebStoreUpdateCheckResult: Sendable, Equatable {
    case upToDate
    case updateAvailable(ChromeWebStoreUpdateInfo)
}

// MARK: - Errors

nonisolated public enum ChromeWebStoreError: LocalizedError, Equatable, Sendable {
    case unrecognizedInput(String)
    case invalidExtensionID(String)
    case network(String)
    case httpStatus(Int)
    case extensionNotFound(String)
    case responseTooLarge
    case unexpectedContentType(String)
    case malformedUpdateResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedInput(let text):
            return "\"\(text)\" doesn't look like a Chrome Web Store link or extension id."
        case .invalidExtensionID(let text):
            return "\"\(text)\" is not a valid Chrome extension id."
        case .network(let reason):
            return "The Chrome Web Store could not be reached: \(reason)"
        case .httpStatus(let status):
            return "The Chrome Web Store's update service returned an unexpected HTTP status (\(status))."
        case .extensionNotFound(let id):
            return "No extension with id \"\(id)\" was found on the Chrome Web Store. It may have been removed or made private."
        case .responseTooLarge:
            return "The download exceeded the maximum allowed extension size and was cancelled."
        case .unexpectedContentType(let contentType):
            return "The Chrome Web Store returned unexpected content (\(contentType)) instead of an extension package."
        case .malformedUpdateResponse(let reason):
            return "The Chrome Web Store's update response could not be understood: \(reason)"
        }
    }
}
