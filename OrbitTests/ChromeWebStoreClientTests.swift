// ChromeWebStoreClient talks to Google's live update service; this suite is not
// allowed to, so every test drives it against StubURLProtocol instead.

import Foundation
import XCTest

final class ChromeWebStoreClientTests: XCTestCase {

    private let ublockOriginLiteID = "ddkjiahejlhfcafbddmgiahcphecmpfh"

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - Request construction (no stub needed — nothing is sent)

    private func bodyString(of request: URLRequest) throws -> String {
        String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
    }

    func test_updateCheckRequest_isAnOmahaProtocol3PostToTheUpdateService() throws {
        let client = ChromeWebStoreClient(prodVersion: "151.0.0.0")
        let request = try client.updateCheckRequest(forExtensionID: ublockOriginLiteID, installedVersion: nil)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, ChromeWebStoreClient.updateServiceEndpoint)
        XCTAssertEqual(request.url?.host, "update.googleapis.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/xml; charset=UTF-8")
        XCTAssertNil(request.url?.query, "The legacy x=id=...&uc query string must not be sent.")
    }

    func test_updateCheckRequestBody_carriesIDProtocolProdversionPlatformAndCRX3() throws {
        let client = ChromeWebStoreClient(prodVersion: "151.0.0.0")
        let body = try bodyString(of: try client.updateCheckRequest(forExtensionID: ublockOriginLiteID, installedVersion: nil))

        XCTAssertTrue(body.contains(#"protocol="3.0""#))
        XCTAssertTrue(body.contains(#"acceptformat="crx3""#), "CRX2 must never be requested — see the file header for why.")
        XCTAssertTrue(body.contains(#"prodversion="151.0.0.0""#))
        XCTAssertTrue(body.contains(#"<os platform="mac" arch="\#(ChromeWebStoreClient.hostArchitecture)""#))
        XCTAssertTrue(body.contains(#"<app appid="\#(ublockOriginLiteID)" version="0.0.0.0""#))
        XCTAssertTrue(body.contains("<updatecheck/>"))
        XCTAssertNotNil(try? XMLDocument(xmlString: body, options: []), "The request body must be well-formed XML.")
    }

    func test_updateCheckRequestBody_withAnInstalledVersion_sendsItAsTheAppVersion() throws {
        let client = ChromeWebStoreClient(prodVersion: "151.0.0.0")
        let body = try bodyString(of: try client.updateCheckRequest(forExtensionID: ublockOriginLiteID, installedVersion: "1.2.3"))
        XCTAssertTrue(body.contains(#"<app appid="\#(ublockOriginLiteID)" version="1.2.3""#))
    }

    func test_updateCheckRequestBody_escapesTheInstalledVersion() throws {
        let client = ChromeWebStoreClient()
        let body = try bodyString(of: try client.updateCheckRequest(forExtensionID: ublockOriginLiteID, installedVersion: #"1"/><x a=""#))
        XCTAssertNotNil(try? XMLDocument(xmlString: body, options: []))
        XCTAssertFalse(body.contains("<x a="))
    }

    func test_defaultProdVersion_isACurrentChromeMilestoneNotTheRetiredOne() throws {
        let client = ChromeWebStoreClient()
        XCTAssertNotEqual(client.prodVersion, "120.0.0.0")
        let major = try XCTUnwrap(Int(client.prodVersion.split(separator: ".").first ?? ""))
        XCTAssertGreaterThanOrEqual(major, 140)
    }

    // Google answered the legacy GET with HTTP 204 for gppongmhjkpfnbhagpmjfkannfbllamg at prodversion 120,
    // which this client reported as "not found". The request Google accepts for that id is pinned here.
    func test_wappalyzerID_producesARequestGoogleAccepts() throws {
        let wappalyzerID = "gppongmhjkpfnbhagpmjfkannfbllamg"
        let client = ChromeWebStoreClient()
        let request = try client.updateCheckRequest(forExtensionID: wappalyzerID, installedVersion: nil)
        let body = try bodyString(of: request)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(body.contains(#"appid="\#(wappalyzerID)""#))
        XCTAssertTrue(body.contains(#"protocol="3.0""#))
        XCTAssertTrue(body.contains(#"prodversion="\#(client.prodVersion)""#))
        XCTAssertFalse(body.contains("120.0.0.0"))
        XCTAssertTrue(body.contains(#"platform="mac""#))
    }

    func test_updateCheckRequest_rejectsAnInvalidID() {
        let client = ChromeWebStoreClient()
        XCTAssertThrowsError(try client.updateCheckRequest(forExtensionID: "not-a-valid-id", installedVersion: nil)) { error in
            guard case ChromeWebStoreError.invalidExtensionID = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
        }
    }

    func test_download_rejectsAnInvalidIDWithoutAttemptingAnyRequest() async {
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.download(id: "not-a-valid-id")
            XCTFail("Expected invalidExtensionID to be thrown")
        } catch ChromeWebStoreError.invalidExtensionID {
        } catch {
            XCTFail("Expected .invalidExtensionID, got \(error)")
        }
    }

    // MARK: - download(id:): two-step flow (Omaha POST, then GET of the package)

    private static let blobBase = "https://clients2.googleusercontent.com/crx/blobs/AZPV/"
    private static let blobURL = URL(string: blobBase + "WAPPALYZER_6_12_7_0.crx")!

    // Answers the update-service POST with a protocol 3.0 "ok" response and routes every other request to `blob`.
    private func downloadHandler(
        blob: @escaping (URLRequest) -> StubURLProtocol.Script
    ) -> (URLRequest) -> StubURLProtocol.Script {
        { request in
            if request.url?.host == "update.googleapis.com" {
                return .respond(
                    status: 200,
                    headers: ["Content-Type": "text/xml; charset=UTF-8"],
                    body: Data(Self.omahaV3XML(appID: self.ublockOriginLiteID, codebase: Self.blobBase, packageName: "WAPPALYZER_6_12_7_0.crx", version: "6.12.7").utf8)
                )
            }
            return blob(request)
        }
    }

    func test_download_postsTheOmahaRequestThenFetchesTheCodebasePlusPackageName() async throws {
        let expectedBytes = Data("crx3".utf8)
        var seen: [(method: String?, url: URL?)] = []
        StubURLProtocol.handler = { request in
            seen.append((request.httpMethod, request.url))
            return self.downloadHandler { _ in
                .respond(status: 200, headers: ["Content-Type": "application/x-chrome-extension"], body: expectedBytes)
            }(request)
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        let data = try await client.download(id: ublockOriginLiteID)
        XCTAssertEqual(data, expectedBytes)
        XCTAssertEqual(seen.map(\.method), ["POST", "GET"])
        XCTAssertEqual(seen.first?.url, ChromeWebStoreClient.updateServiceEndpoint)
        XCTAssertEqual(seen.last?.url, Self.blobURL)
    }

    func test_download_mapsAFreshInstallNoUpdateToMalformedNotExtensionNotFound() async {
        StubURLProtocol.handler = { _ in
            .respond(status: 200, headers: ["Content-Type": "text/xml"], body: Data(Self.omahaV3NoUpdateXML(appID: self.ublockOriginLiteID).utf8))
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.download(id: ublockOriginLiteID)
            XCTFail("Expected .malformedUpdateResponse")
        } catch ChromeWebStoreError.malformedUpdateResponse {
        } catch {
            XCTFail("Expected .malformedUpdateResponse, got \(error)")
        }
    }

    func test_download_mapsHTTP404FromThePackageFetchToExtensionNotFound() async {
        StubURLProtocol.handler = downloadHandler { _ in .respond(status: 404, headers: [:], body: Data()) }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.download(id: ublockOriginLiteID)
            XCTFail("Expected .extensionNotFound")
        } catch ChromeWebStoreError.extensionNotFound(let id) {
            XCTAssertEqual(id, ublockOriginLiteID)
        } catch {
            XCTFail("Expected .extensionNotFound, got \(error)")
        }
    }

    // MARK: - download(id:): redirect following

    func test_download_followsTheRedirectAndReturnsTheFinalBytes() async throws {
        let finalURL = URL(string: "https://clients2.googleusercontent.com/crx/blobs/fake.crx")!
        let expectedBytes = Data("a fake but recognisable CRX3 payload".utf8)

        StubURLProtocol.handler = downloadHandler { request in
            if request.url == finalURL {
                return .respond(status: 200, headers: ["Content-Type": "application/x-chrome-extension"], body: expectedBytes)
            }
            return .redirect(to: finalURL)
        }

        let client = ChromeWebStoreClient(session: makeStubbedSession())
        let data = try await client.download(id: ublockOriginLiteID)
        XCTAssertEqual(data, expectedBytes)
    }

    // MARK: - download(id:): size cap

    func test_download_rejectsAResponseWhoseDeclaredContentLengthExceedsTheCap() async {
        StubURLProtocol.handler = downloadHandler { _ in
            .respond(status: 200, headers: ["Content-Length": "5000"], body: Data(repeating: 0x41, count: 5000))
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession(), maxDownloadBytes: 1024)
        do {
            _ = try await client.download(id: ublockOriginLiteID)
            XCTFail("Expected .responseTooLarge")
        } catch ChromeWebStoreError.responseTooLarge {
        } catch {
            XCTFail("Expected .responseTooLarge, got \(error)")
        }
    }

    func test_download_rejectsAnUndeclaredResponseThatExceedsTheCapAsBytesArrive() async {
        StubURLProtocol.handler = downloadHandler { _ in
            .respond(status: 200, headers: [:], body: Data(repeating: 0x42, count: 5000))
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession(), maxDownloadBytes: 1024)
        do {
            _ = try await client.download(id: ublockOriginLiteID)
            XCTFail("Expected .responseTooLarge")
        } catch ChromeWebStoreError.responseTooLarge {
        } catch {
            XCTFail("Expected .responseTooLarge, got \(error)")
        }
    }

    func test_download_acceptsAResponseAtExactlyTheCap() async throws {
        let bytes = Data(repeating: 0x43, count: 1024)
        StubURLProtocol.handler = downloadHandler { _ in .respond(status: 200, headers: [:], body: bytes) }
        let client = ChromeWebStoreClient(session: makeStubbedSession(), maxDownloadBytes: 1024)
        let data = try await client.download(id: ublockOriginLiteID)
        XCTAssertEqual(data.count, 1024)
    }

    // MARK: - download(id:): status-code mapping

    func test_download_mapsHTTP404ToExtensionNotFound() async {
        StubURLProtocol.handler = { _ in .respond(status: 404, headers: [:], body: Data()) }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.download(id: ublockOriginLiteID)
            XCTFail("Expected .extensionNotFound")
        } catch ChromeWebStoreError.extensionNotFound(let id) {
            XCTAssertEqual(id, ublockOriginLiteID)
        } catch {
            XCTFail("Expected .extensionNotFound, got \(error)")
        }
    }

    func test_download_mapsHTTP204ToExtensionNotFound() async {
        StubURLProtocol.handler = { _ in .respond(status: 204, headers: [:], body: Data()) }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.download(id: ublockOriginLiteID)
            XCTFail("Expected .extensionNotFound")
        } catch ChromeWebStoreError.extensionNotFound {
        } catch {
            XCTFail("Expected .extensionNotFound, got \(error)")
        }
    }

    func test_download_mapsAnUnexpectedHTTPStatusToHttpStatus() async {
        StubURLProtocol.handler = { _ in .respond(status: 500, headers: [:], body: Data()) }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.download(id: ublockOriginLiteID)
            XCTFail("Expected .httpStatus(500)")
        } catch ChromeWebStoreError.httpStatus(let status) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Expected .httpStatus(500), got \(error)")
        }
    }

    func test_download_mapsAnHTMLResponseToUnexpectedContentType() async {
        StubURLProtocol.handler = { _ in
            .respond(status: 200, headers: ["Content-Type": "text/html; charset=UTF-8"], body: Data("<html>not found</html>".utf8))
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.download(id: ublockOriginLiteID)
            XCTFail("Expected .unexpectedContentType")
        } catch ChromeWebStoreError.unexpectedContentType(let contentType) {
            XCTAssertTrue(contentType.contains("text/html"))
        } catch {
            XCTFail("Expected .unexpectedContentType, got \(error)")
        }
    }

    // MARK: - checkForUpdate(id:installedVersion:): update available

    func test_checkForUpdate_parsesAnUpdateAvailableResponse() async throws {
        let codebase = "https://clients2.googleusercontent.com/crx/blobs/example.crx"
        StubURLProtocol.handler = { _ in
            .respond(
                status: 200,
                headers: ["Content-Type": "text/xml"],
                body: Data(Self.omahaXML(appID: self.ublockOriginLiteID, updateCheck: #"status="ok" codebase="\#(codebase)" version="1.2.3""#).utf8)
            )
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        let result = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: "1.0.0")

        guard case .updateAvailable(let info) = result else {
            return XCTFail("Expected .updateAvailable, got \(result)")
        }
        XCTAssertEqual(info.version, "1.2.3")
        XCTAssertEqual(info.downloadURL.absoluteString, codebase)
    }

    // MARK: - checkForUpdate(id:installedVersion:): no update

    func test_checkForUpdate_parsesANoUpdateResponse() async throws {
        StubURLProtocol.handler = { _ in
            .respond(
                status: 200,
                headers: ["Content-Type": "text/xml"],
                body: Data(Self.omahaXML(appID: self.ublockOriginLiteID, updateCheck: #"status="noupdate""#).utf8)
            )
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        let result = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: "1.2.3")
        XCTAssertEqual(result, .upToDate)
    }

    // MARK: - checkForUpdate(id:installedVersion:): malformed XML

    func test_checkForUpdate_reportsMalformedXMLRatherThanCrashing() async {
        StubURLProtocol.handler = { _ in
            .respond(status: 200, headers: ["Content-Type": "text/xml"], body: Data("<gupdate><app not closed".utf8))
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: nil)
            XCTFail("Expected .malformedUpdateResponse")
        } catch ChromeWebStoreError.malformedUpdateResponse {
        } catch {
            XCTFail("Expected .malformedUpdateResponse, got \(error)")
        }
    }

    func test_checkForUpdate_reportsMalformedWhenOkStatusIsMissingRequiredAttributes() async {
        StubURLProtocol.handler = { _ in
            .respond(
                status: 200,
                headers: ["Content-Type": "text/xml"],
                body: Data(Self.omahaXML(appID: self.ublockOriginLiteID, updateCheck: #"status="ok""#).utf8)
            )
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: nil)
            XCTFail("Expected .malformedUpdateResponse")
        } catch ChromeWebStoreError.malformedUpdateResponse {
        } catch {
            XCTFail("Expected .malformedUpdateResponse, got \(error)")
        }
    }

    // MARK: - checkForUpdate(id:installedVersion:): unknown extension

    func test_checkForUpdate_mapsAnUnknownApplicationUpdatecheckStatusToExtensionNotFound() async {
        StubURLProtocol.handler = { _ in
            .respond(
                status: 200,
                headers: ["Content-Type": "text/xml"],
                body: Data(Self.omahaXML(appID: self.ublockOriginLiteID, updateCheck: #"status="error-unknownApplication""#).utf8)
            )
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: nil)
            XCTFail("Expected .extensionNotFound")
        } catch ChromeWebStoreError.extensionNotFound(let id) {
            XCTAssertEqual(id, ublockOriginLiteID)
        } catch {
            XCTFail("Expected .extensionNotFound, got \(error)")
        }
    }

    func test_checkForUpdate_mapsAnUnknownApplicationAppStatusToExtensionNotFound() async {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">
        <app appid="\(ublockOriginLiteID)" status="error-unknownApplication"/>
        </gupdate>
        """
        StubURLProtocol.handler = { _ in .respond(status: 200, headers: ["Content-Type": "text/xml"], body: Data(xml.utf8)) }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: nil)
            XCTFail("Expected .extensionNotFound")
        } catch ChromeWebStoreError.extensionNotFound(let id) {
            XCTAssertEqual(id, ublockOriginLiteID)
        } catch {
            XCTFail("Expected .extensionNotFound, got \(error)")
        }
    }

    func test_checkForUpdate_mapsHTTP404ToExtensionNotFound() async {
        StubURLProtocol.handler = { _ in .respond(status: 404, headers: [:], body: Data()) }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: nil)
            XCTFail("Expected .extensionNotFound")
        } catch ChromeWebStoreError.extensionNotFound {
        } catch {
            XCTFail("Expected .extensionNotFound, got \(error)")
        }
    }

    // MARK: - checkForUpdate: protocol 3.0 responses

    func test_checkForUpdate_parsesAProtocol3UpdateAvailableResponse() async throws {
        StubURLProtocol.handler = { _ in
            .respond(status: 200, headers: ["Content-Type": "text/xml"], body: Data(Self.omahaV3XML(appID: self.ublockOriginLiteID, codebase: Self.blobBase, packageName: "P_1_0.crx", version: "1.0").utf8))
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        let result = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: nil)
        XCTAssertEqual(result, .updateAvailable(ChromeWebStoreUpdateInfo(version: "1.0", downloadURL: URL(string: Self.blobBase + "P_1_0.crx")!)))
    }

    func test_checkForUpdate_rejectsANonHTTPSCodebase() async {
        StubURLProtocol.handler = { _ in
            .respond(status: 200, headers: ["Content-Type": "text/xml"], body: Data(Self.omahaV3XML(appID: self.ublockOriginLiteID, codebase: "http://example.com/", packageName: "P.crx", version: "1.0").utf8))
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: nil)
            XCTFail("Expected .malformedUpdateResponse")
        } catch ChromeWebStoreError.malformedUpdateResponse {
        } catch {
            XCTFail("Expected .malformedUpdateResponse, got \(error)")
        }
    }

    func test_checkForUpdate_mapsAProtocol3UnknownApplicationToExtensionNotFound() async {
        StubURLProtocol.handler = { _ in
            .respond(status: 200, headers: ["Content-Type": "text/xml"], body: Data(Self.omahaV3UnknownApplicationXML(appID: self.ublockOriginLiteID).utf8))
        }
        let client = ChromeWebStoreClient(session: makeStubbedSession())
        do {
            _ = try await client.checkForUpdate(id: ublockOriginLiteID, installedVersion: nil)
            XCTFail("Expected .extensionNotFound")
        } catch ChromeWebStoreError.extensionNotFound(let id) {
            XCTAssertEqual(id, ublockOriginLiteID)
        } catch {
            XCTFail("Expected .extensionNotFound, got \(error)")
        }
    }

    // MARK: - Fixtures

    // Shapes captured from update.googleapis.com/service/update2 for gppongmhjkpfnbhagpmjfkannfbllamg.
    private static func omahaV3XML(appID: String, codebase: String, packageName: String, version: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <response protocol="3.0" server="prod"><daystart elapsed_days="7228" elapsed_seconds="57903"/>\
        <app appid="\(appID)" cohort="1::" cohortname="" status="ok"><updatecheck status="ok"><urls><url codebase="\(codebase)"/></urls>\
        <manifest version="\(version)"><packages><package hash_sha256="00" name="\(packageName)" required="true" size="3"/></packages></manifest>\
        </updatecheck></app></response>
        """
    }

    private static func omahaV3NoUpdateXML(appID: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <response protocol="3.0" server="prod"><app appid="\(appID)" status="ok"><updatecheck status="noupdate"/></app></response>
        """
    }

    private static func omahaV3UnknownApplicationXML(appID: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <response protocol="3.0" server="prod"><app appid="\(appID)" status="error-unknownApplication"/></response>
        """
    }

    private static func omahaXML(appID: String, updateCheck attributes: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">
        <app appid="\(appID)">
        <updatecheck \(attributes)/>
        </app>
        </gupdate>
        """
    }
}

// MARK: - StubURLProtocol

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Script {
        case respond(status: Int, headers: [String: String], body: Data)
        case redirect(to: URL)
    }

    // nonisolated(unsafe): global test-harness state, cleared in tearDown(); XCTest runs one class's methods sequentially.
    nonisolated(unsafe) static var handler: ((URLRequest) -> Script)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch handler(request) {
        case .redirect(let redirectURL):
            let redirectRequest = URLRequest(url: redirectURL)
            let redirectResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectURL.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: redirectResponse)
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
