import XCTest

final class SiteIdentityTests: XCTestCase {

    private func site(_ string: String) -> String? { SiteIdentity.registrableDomain(of: URL(string: string)!) }

    func testSubdomainsCollapseToTheRegistrableDomain() {
        XCTAssertEqual(site("https://www.example.com/a"), "example.com")
        XCTAssertEqual(site("https://mail.google.com/mail"), "google.com")
        XCTAssertEqual(site("https://a.b.c.example.org"), "example.org")
    }

    func testTwoPartPublicSuffixesKeepThreeLabels() {
        XCTAssertEqual(site("https://www.bbc.co.uk/news"), "bbc.co.uk")
        XCTAssertEqual(site("https://shop.example.com.au"), "example.com.au")
    }

    func testIPAddressesAndLocalhostAreKeptWhole() {
        XCTAssertEqual(site("http://192.168.1.10:8080/x"), "192.168.1.10")
        XCTAssertEqual(site("http://localhost:3000"), "localhost")
    }

    func testURLsWithoutAHostHaveNoSite() {
        XCTAssertNil(site("about:blank"))
        XCTAssertNil(site("file:///tmp/x.html"))
    }

    func testSameSiteComparison() {
        XCTAssertTrue(SiteIdentity.areSameSite(URL(string: "https://www.nytimes.com/a")!, URL(string: "https://cooking.nytimes.com/b")!))
        XCTAssertFalse(SiteIdentity.areSameSite(URL(string: "https://www.nytimes.com/a")!, URL(string: "https://example.com/b")!))
        XCTAssertFalse(SiteIdentity.areSameSite(URL(string: "about:blank")!, URL(string: "about:blank")!))
    }
}
