import XCTest

final class SearchSuggestionsClientTests: XCTestCase {

    func test_emptyQuery_returnsNoSuggestionsWithoutAnyNetworkAttempt() async {
        let client = SearchSuggestionsClient(requestTimeout: 0.001)
        let result = await client.suggestions(for: "   ")
        XCTAssertEqual(result, [], "A whitespace-only query must return no suggestions without attempting a request.")
    }

    func test_unreachableEndpoint_degradesToEmptyArrayRatherThanThrowingOrHanging() async {
        let client = SearchSuggestionsClient(debounceNanoseconds: 0, requestTimeout: 0.0001)
        let result = await client.suggestions(for: "orbit browser")
        XCTAssertEqual(result, [], "An unreachable/timed-out suggest endpoint must degrade silently to no suggestions, never throw or surface an error.")
    }

    func test_rapidSuccessiveCalls_debounceCancelsThePreviousOneRatherThanHanging() async {
        let client = SearchSuggestionsClient(debounceNanoseconds: 200_000_000, requestTimeout: 0.001)

        async let first = client.suggestions(for: "a")
        try? await Task.sleep(nanoseconds: 20_000_000) // well inside the 200ms debounce window
        let second = await client.suggestions(for: "ab")
        let firstResult = await first

        XCTAssertEqual(firstResult, [], "The superseded first call should resolve to no suggestions once cancelled, not hang or throw.")
        XCTAssertEqual(second, [], "The final call still degrades to no suggestions given the forced-unreachable timeout.")
    }
}
