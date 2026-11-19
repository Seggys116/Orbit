//  Regression cover: WKWebView shows no password prompt of its own on macOS, and Orbit answered every
//  non-certificate challenge with the default, so a page behind HTTP Basic or Digest login never opened.

import Foundation
import XCTest
@testable import Orbit

@MainActor
final class WebKitHTTPAuthenticationTests: XCTestCase {

    private func space(
        host: String = "intranet.example.com",
        port: Int = 80,
        protocol scheme: String = "http",
        method: String = NSURLAuthenticationMethodHTTPBasic
    ) -> URLProtectionSpace {
        URLProtectionSpace(host: host, port: port, protocol: scheme, realm: "Staff", authenticationMethod: method)
    }

    func test_asksForPassword_isTrueForBasicDigestAndNTLMOnly() {
        for method in [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
        ] {
            XCTAssertTrue(WebKitWebContents.asksForPassword(space(method: method)), method)
        }
        for method in [
            NSURLAuthenticationMethodServerTrust,
            NSURLAuthenticationMethodClientCertificate,
            NSURLAuthenticationMethodNegotiate,
        ] {
            XCTAssertFalse(WebKitWebContents.asksForPassword(space(method: method)), method)
        }
    }

    func test_challengeIsForNavigation_matchesThePageOverPlainHTTPOnItsDefaultPort() {
        let page = URL(string: "http://intranet.example.com/reports")
        XCTAssertTrue(WebKitWebContents.challengeIsForNavigation(space(), documentURLs: [nil, page]))
    }

    func test_challengeIsForNavigation_matchesAnHTTPSPageAndAnExplicitPort() {
        let secure = space(port: 443, protocol: "https")
        XCTAssertTrue(WebKitWebContents.challengeIsForNavigation(secure, documentURLs: [URL(string: "https://intranet.example.com/")]))

        let alternate = space(port: 8080)
        XCTAssertTrue(WebKitWebContents.challengeIsForNavigation(alternate, documentURLs: [URL(string: "http://intranet.example.com:8080/x")]))
    }

    func test_challengeIsForNavigation_ignoresCaseAndATrailingDot() {
        let page = URL(string: "http://INTRANET.example.com./")
        XCTAssertTrue(WebKitWebContents.challengeIsForNavigation(space(), documentURLs: [page]))
    }

    func test_challengeIsForNavigation_refusesAnotherHostPortOrScheme() {
        XCTAssertFalse(WebKitWebContents.challengeIsForNavigation(space(), documentURLs: [URL(string: "http://other.example.com/")]))
        XCTAssertFalse(WebKitWebContents.challengeIsForNavigation(space(), documentURLs: [URL(string: "http://intranet.example.com:8080/")]))
        XCTAssertFalse(WebKitWebContents.challengeIsForNavigation(space(), documentURLs: [URL(string: "https://intranet.example.com/")]),
                       "an https page does not vouch for an http challenge on the same host")
        XCTAssertFalse(WebKitWebContents.challengeIsForNavigation(space(), documentURLs: [nil, URL(string: "about:blank"), URL(string: "file:///tmp/a.html")]))
    }
}
