import Foundation

// MARK: - Client

nonisolated public struct ChromeWebStoreClient: Sendable {

    public static let updateServiceEndpoint = URL(string: "https://clients2.google.com/service/update2/crx")!
    public let session: URLSession
    public let prodVersion: String
    public let maxDownloadBytes: Int
    public static let maxUpdateCheckResponseBytes = 1 * 1024 * 1024
    public let requestTimeout: TimeInterval

    public init(
        session: URLSession = .shared,
        prodVersion: String = String(ChromiumBuild.majorVersion),
        maxDownloadBytes: Int = 512 * 1024 * 1024,
        requestTimeout: TimeInterval = 30
    ) {
        self.session = session
        self.prodVersion = prodVersion
        self.maxDownloadBytes = maxDownloadBytes
        self.requestTimeout = requestTimeout
    }

    // MARK: - Request construction

    // Returns the UNENCODED inner string; callers must let URLComponents encode it, not pre-encode it themselves.
    static func updateServiceQueryValue(id: String, installedVersion: String?) -> String {
        if let installedVersion, !installedVersion.isEmpty {
            return "id=\(id)&v=\(installedVersion)&uc"
        }
        return "id=\(id)&uc"
    }

    public func downloadRequestURL(forExtensionID id: String) throws -> URL {
        guard ChromeExtensionID.isValid(id) else {
            throw ChromeWebStoreError.invalidExtensionID(id)
        }
        var components = URLComponents(url: Self.updateServiceEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "prodversion", value: prodVersion),
            URLQueryItem(name: "x", value: Self.updateServiceQueryValue(id: id, installedVersion: nil)),
        ]
        guard let url = components.url else {
            throw ChromeWebStoreError.network("Could not construct the extension download request URL.")
        }
        return url
    }

    public func updateCheckRequestURL(forExtensionID id: String, installedVersion: String?) throws -> URL {
        guard ChromeExtensionID.isValid(id) else {
            throw ChromeWebStoreError.invalidExtensionID(id)
        }
        var components = URLComponents(url: Self.updateServiceEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "prodversion", value: prodVersion),
            URLQueryItem(name: "x", value: Self.updateServiceQueryValue(id: id, installedVersion: installedVersion)),
        ]
        guard let url = components.url else {
            throw ChromeWebStoreError.network("Could not construct the update-check request URL.")
        }
        return url
    }

    // MARK: - Download

    public func download(id: String, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> Data {
        let url = try downloadRequestURL(forExtensionID: id)
        var request = URLRequest(url: url)
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
        let url = try updateCheckRequestURL(forExtensionID: id, installedVersion: installedVersion)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("text/xml, application/xml", forHTTPHeaderField: "Accept")

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
                guard let codebaseString = delegate.codebase, let version = delegate.version else {
                    throw ChromeWebStoreError.malformedUpdateResponse(
                        "<updatecheck status=\"ok\"> was missing its codebase or version attribute."
                    )
                }
                guard let codebase = URL(string: codebaseString) else {
                    throw ChromeWebStoreError.malformedUpdateResponse(
                        "<updatecheck>'s codebase attribute (\"\(codebaseString)\") is not a valid URL."
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
    private(set) var codebase: String?
    private(set) var version: String?
    private(set) var parseError: Error?

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
            codebase = attributeDict["codebase"]
            version = attributeDict["version"]
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
