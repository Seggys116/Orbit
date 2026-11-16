import XCTest
@testable import Orbit

final class PublicSuffixListTests: XCTestCase {

    private func site(_ host: String) -> String { PublicSuffixList.registrableDomain(ofHost: host) }

    func testOrdinaryDomainsKeepTheLabelBeforeTheSuffix() {
        XCTAssertEqual(site("example.com"), "example.com")
        XCTAssertEqual(site("www.example.com"), "example.com")
        XCTAssertEqual(site("a.b.c.example.org"), "example.org")
    }

    func testMultiLabelPublicSuffixesAreRespected() {
        XCTAssertEqual(site("www.example.co.uk"), "example.co.uk")
        XCTAssertEqual(site("example.com.au"), "example.com.au")
        XCTAssertEqual(site("shop.example.co.jp"), "example.co.jp")
    }

    func testTenantsOfASharedHostingSuffixAreSeparateSites() {
        XCTAssertEqual(site("alice.github.io"), "alice.github.io")
        XCTAssertEqual(site("evil.github.io"), "evil.github.io")
        XCTAssertNotEqual(site("alice.github.io"), site("evil.github.io"))
        XCTAssertEqual(site("www.alice.github.io"), "alice.github.io")
        XCTAssertNotEqual(site("one.herokuapp.com"), site("two.herokuapp.com"))
        XCTAssertNotEqual(site("one.vercel.app"), site("two.vercel.app"))
        XCTAssertNotEqual(site("one.netlify.app"), site("two.netlify.app"))
        XCTAssertNotEqual(site("one.pages.dev"), site("two.pages.dev"))
    }

    func testAPublicSuffixAloneIsItsOwnSite() {
        XCTAssertEqual(site("github.io"), "github.io")
        XCTAssertEqual(site("co.uk"), "co.uk")
        XCTAssertEqual(site("com"), "com")
    }

    func testWildcardAndExceptionRules() {
        // "*.ck" makes every second-level label a public suffix, except "www.ck".
        XCTAssertEqual(site("foo.bar.ck"), "foo.bar.ck")
        XCTAssertEqual(site("bar.ck"), "bar.ck")
        XCTAssertEqual(site("www.ck"), "www.ck")
        XCTAssertEqual(site("sub.www.ck"), "www.ck")
    }

    func testAnUnlistedTopLevelDomainIsAOneLabelSuffix() {
        XCTAssertEqual(site("host.example.invalidtld"), "example.invalidtld")
        XCTAssertEqual(site("localhost"), "localhost")
        XCTAssertEqual(site("intranet"), "intranet")
    }

    func testIPAddressesAndCaseAndTrailingDotAreHandled() {
        XCTAssertEqual(site("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(site("192.168.1.20"), "192.168.1.20")
        XCTAssertEqual(site("::1"), "::1")
        XCTAssertEqual(site("WWW.Example.COM"), "example.com")
        XCTAssertEqual(site("www.example.com."), "example.com")
    }

    func testMalformedHostsAreReturnedUnchanged() {
        XCTAssertEqual(site(""), "")
        XCTAssertEqual(site("a..b.com"), "a..b.com")
    }
}
