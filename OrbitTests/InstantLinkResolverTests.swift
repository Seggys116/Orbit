import XCTest

final class InstantLinkResolverTests: XCTestCase {

    // MARK: - 1. DuckDuckGo builds the `\`-prefixed URL; other engines get nil

    func test_instantURL_duckDuckGo_prefixesWithBackslashAndPercentEncodesIt() throws {
        let url = try XCTUnwrap(InstantLinkResolver.instantURL(for: "futurama", engine: .duckDuckGo))
        XCTAssertEqual(url.absoluteString, "https://duckduckgo.com/?q=%5Cfuturama")
    }

    func test_instantURL_duckDuckGo_percentEncodesQueryBreakingCharacters() throws {
        let url = try XCTUnwrap(InstantLinkResolver.instantURL(for: "salt & pepper", engine: .duckDuckGo))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(queryItems.count, 1, "An unescaped `&` would have produced a second query item: \(queryItems)")
        XCTAssertEqual(queryItems.first?.name, "q")
        XCTAssertEqual(queryItems.first?.value, "\\salt & pepper", "The expanded URL must round-trip back to exactly the backslash-prefixed query.")
    }

    func test_instantURL_google_returnsNil() {
        XCTAssertNil(InstantLinkResolver.instantURL(for: "recipes", engine: .google))
    }

    func test_instantURL_bing_returnsNil() {
        XCTAssertNil(InstantLinkResolver.instantURL(for: "recipes", engine: .bing))
    }

    func test_instantURL_ecosia_returnsNil() {
        XCTAssertNil(InstantLinkResolver.instantURL(for: "recipes", engine: .ecosia))
    }

    func test_instantURL_emptyQuery_returnsNilRegardlessOfEngine() {
        XCTAssertNil(InstantLinkResolver.instantURL(for: "", engine: .duckDuckGo))
        XCTAssertNil(InstantLinkResolver.instantURL(for: "   ", engine: .duckDuckGo))
    }

    // MARK: - 2. A query already starting with `\` is not double-prefixed

    func test_instantURL_duckDuckGo_queryAlreadyStartingWithBackslashIsNotDoublePrefixed() throws {
        let url = try XCTUnwrap(InstantLinkResolver.instantURL(for: "\\futurama", engine: .duckDuckGo))
        XCTAssertEqual(url.absoluteString, "https://duckduckgo.com/?q=%5Cfuturama", "A query the user already typed with a leading backslash must not become `\\\\futurama`.")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let value = try XCTUnwrap(components.queryItems?.first?.value)
        XCTAssertEqual(value.filter { $0 == "\\" }.count, 1)
        XCTAssertEqual(value, "\\futurama")
    }

    // MARK: - 9 (shared with ChatGPTCommandBarTests): no `btnI` is ever produced

    func test_instantURL_neverProducesTheOldBtnIParameter_forAnyEngine() {
        for engine in SearchEngine.allCases {
            let url = InstantLinkResolver.instantURL(for: "example query", engine: engine)
            XCTAssertFalse(url?.absoluteString.contains("btnI") ?? false, "\(engine) must never produce a URL containing the retired `btnI` parameter.")
        }
    }
}
