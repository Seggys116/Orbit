//  The pure halves of the page-facing surface: how an input's accept list becomes a panel filter and how a
//  navigation maps onto a lock state. No engine involved.

import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Orbit

@MainActor
final class WebKitPageSurfaceUnitTests: XCTestCase {

    // MARK: - File chooser accept list

    func testWildcardMIMETypesBecomeTheirContentTypeFamilies() {
        XCTAssertEqual(AppEnvironment.openPanelContentTypes(from: ["image/*"]), [.image])
        XCTAssertEqual(AppEnvironment.openPanelContentTypes(from: ["video/*", "audio/*"]), [.movie, .audio])
    }

    func testExtensionsAndExactMIMETypesResolveCaseInsensitively() {
        XCTAssertEqual(AppEnvironment.openPanelContentTypes(from: [".PNG", " image/jpeg "]), [.png, .jpeg])
    }

    func testAnAcceptListThatCannotBeFullyResolvedFiltersNothing() {
        XCTAssertNil(
            AppEnvironment.openPanelContentTypes(from: ["image/png", "application/x-orbit-no-such-type"]),
            "a partial filter would hide files the page asked for"
        )
        XCTAssertNil(AppEnvironment.openPanelContentTypes(from: []))
        XCTAssertNil(AppEnvironment.openPanelContentTypes(from: ["", "  "]))
    }

    // MARK: - Lock state

    func testSecureContentOverHTTPSIsSecureAndMixedContentIsNot() {
        let https = URL(string: "https://example.com/")!
        XCTAssertEqual(WebKitWebContents.security(for: https), .secure)
        XCTAssertEqual(WebKitWebContents.security(for: https, mixedContent: true), .mixedContent)
    }

    func testMixedContentFlagNeverTurnsAnotherSchemeIntoMixedContent() {
        XCTAssertEqual(WebKitWebContents.security(for: URL(string: "http://example.com/")!, mixedContent: true), .insecure)
        XCTAssertEqual(WebKitWebContents.security(for: URL(string: "file:///tmp/x.html")!, mixedContent: true), .local)
        XCTAssertEqual(WebKitWebContents.security(for: URL(string: "orbit://settings")!, mixedContent: true), .local)
        XCTAssertEqual(WebKitWebContents.security(for: URL(string: "ftp://example.com/")!, mixedContent: true), .unknown)
    }

    // MARK: - Server trust challenges

    private func space(_ host: String, port: Int = 443) -> URLProtectionSpace {
        URLProtectionSpace(host: host, port: port, `protocol`: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }

    func testAServerTrustChallengeTheSystemAcceptsIsNeverCancelled() {
        // A trusted certificate is accepted with the evaluated trust. Cancelling, or leaving the
        // disposition at the default, dropped redirected main documents and CDN subresources.
        XCTAssertEqual(WebKitWebContents.untroubledServerTrustDisposition, .useCredential)
    }

    func testARedirectedMainDocumentIsMatchedThroughTheInFlightURL() {
        let typed = URL(string: "https://google.com/")!
        let redirected = URL(string: "https://www.google.com/")!
        XCTAssertFalse(WebKitWebContents.challengeIsForMainDocument(space("www.google.com"), documentURLs: [typed]))
        XCTAssertTrue(WebKitWebContents.challengeIsForMainDocument(space("www.google.com"), documentURLs: [typed, redirected]))
    }

    func testAnotherHostOrPortIsNotTheMainDocument() {
        let page = URL(string: "https://www.apple.com/")!
        XCTAssertFalse(WebKitWebContents.challengeIsForMainDocument(space("store.storeimages.cdn-apple.com"), documentURLs: [page]))
        XCTAssertFalse(WebKitWebContents.challengeIsForMainDocument(space("www.apple.com", port: 8443), documentURLs: [page]))
        XCTAssertFalse(WebKitWebContents.challengeIsForMainDocument(space("www.apple.com"), documentURLs: [nil, URL(string: "http://www.apple.com/")]))
    }
}
