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

    func test_downloadRequestURL_hasTheExpectedHostAndFixedParameters() throws {
        let client = ChromeWebStoreClient(prodVersion: "151")
        let url = try client.downloadRequestURL(forExtensionID: ublockOriginLiteID)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "clients2.google.com")
        XCTAssertEqual(components.path, "/service/update2/crx")

        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["response"], "redirect")
        XCTAssertEqual(items["acceptformat"], "crx3", "CRX2 must never be requested — see the file header for why.")
        XCTAssertEqual(items["prodversion"], "151")
    }

    func test_downloadRequestURL_percentEncodesTheXParameterExactly() throws {
        let client = ChromeWebStoreClient(prodVersion: "151")
        let url = try client.downloadRequestURL(forExtensionID: ublockOriginLiteID)

        XCTAssertEqual(
            url.absoluteString,
            "https://clients2.google.com/service/update2/crx?response=redirect&acceptformat=crx3&prodversion=151&x=id%3Dddkjiahejlhfcafbddmgiahcphecmpfh%26uc"
        )
    }

    func test_updateCheckRequestURL_omitsResponseRedirect() throws {
        let client = ChromeWebStoreClient(prodVersion: "151")
        let url = try client.updateCheckRequestURL(forExtensionID: ublockOriginLiteID, installedVersion: nil)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = Set((components.queryItems ?? []).map(\.name))
        XCTAssertFalse(names.contains("response"), "response=redirect is what makes the service answer with a 302 instead of the Omaha XML this endpoint needs to return.")
    }

    func test_updateCheckRequestURL_withNoInstalledVersion_encodesJustIDAndUC() throws {
        let client = ChromeWebStoreClient(prodVersion: "151")
        let url = try client.updateCheckRequestURL(forExtensionID: ublockOriginLiteID, installedVersion: nil)
        XCTAssertEqual(
            url.absoluteString,
            "https://clients2.google.com/service/update2/crx?acceptformat=crx3&prodversion=151&x=id%3Dddkjiahejlhfcafbddmgiahcphecmpfh%26uc"
        )
    }

    func test_updateCheckRequestURL_withAnInstalledVersion_embedsItInTheXValue() throws {
        let client = ChromeWebStoreClient(prodVersion: "151")
        let url = try client.updateCheckRequestURL(forExtensionID: ublockOriginLiteID, installedVersion: "1.2.3")
        XCTAssertEqual(
            url.absoluteString,
            "https://clients2.google.com/service/update2/crx?acceptformat=crx3&prodversion=151&x=id%3Dddkjiahejlhfcafbddmgiahcphecmpfh%26v%3D1.2.3%26uc"
        )
    }

    func test_downloadRequestURL_rejectsAnInvalidID() {
        let client = ChromeWebStoreClient()
        XCTAssertThrowsError(try client.downloadRequestURL(forExtensionID: "not-a-valid-id")) { error in
            guard case ChromeWebStoreError.invalidExtensionID = error else {
                return XCTFail("Expected .invalidExtensionID, got \(error)")
            }
        }
    }

    func test_updateCheckRequestURL_rejectsAnInvalidID() {
        let client = ChromeWebStoreClient()
        XCTAssertThrowsError(try client.updateCheckRequestURL(forExtensionID: "not-a-valid-id", installedVersion: nil)) { error in
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

    // MARK: - download(id:): redirect following

    func test_download_followsTheRedirectAndReturnsTheFinalBytes() async throws {
        let finalURL = URL(string: "https://clients2.googleusercontent.com/crx/blobs/fake.crx")!
        let expectedBytes = Data("a fake but recognisable CRX3 payload".utf8)

        StubURLProtocol.handler = { request in
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
        StubURLProtocol.handler = { _ in
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
        StubURLProtocol.handler = { _ in
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
        StubURLProtocol.handler = { _ in .respond(status: 200, headers: [:], body: bytes) }
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

    // MARK: - Fixtures

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
