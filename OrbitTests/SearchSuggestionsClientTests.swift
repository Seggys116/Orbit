import XCTest

final class SearchSuggestionsClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SuggestionsStubProtocol.reset(script: .respond(Data()))
    }

    override func tearDown() {
        SuggestionsStubProtocol.reset(script: .respond(Data()))
        super.tearDown()
    }

    private func makeClient(debounceNanoseconds: UInt64 = 0) -> SearchSuggestionsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuggestionsStubProtocol.self]
        return SearchSuggestionsClient(
            session: URLSession(configuration: configuration),
            debounceNanoseconds: debounceNanoseconds,
            requestTimeout: 5
        )
    }

    private func body(_ json: String) -> SuggestionsStubProtocol.Script {
        .respond(Data(json.utf8))
    }

    func test_emptyQuery_returnsNoSuggestionsWithoutAnyNetworkAttempt() async {
        SuggestionsStubProtocol.reset(script: body(#"["x",["would","be","returned"]]"#))
        let client = makeClient()

        let result = await client.suggestions(for: "   ")

        XCTAssertEqual(result, [])
        XCTAssertEqual(SuggestionsStubProtocol.requestedURLs, [], "A whitespace-only query must not attempt a request.")
    }

    func test_reachableEndpoint_returnsTheSuggestionsFromTheSecondElementOfTheResponse() async {
        SuggestionsStubProtocol.reset(script: body(#"["orbit browser",["orbit browser","orbit browser review"]]"#))
        let client = makeClient()

        let result = await client.suggestions(for: "orbit browser")

        XCTAssertEqual(result, ["orbit browser", "orbit browser review"])
        XCTAssertEqual(
            SuggestionsStubProtocol.requestedURLs.map(\.absoluteString),
            ["https://suggestqueries.google.com/complete/search?client=firefox&q=orbit%20browser"],
            "exactly one request, to the default engine's suggest endpoint with the query percent-encoded"
        )
    }

    func test_theChosenEngineDecidesWhichEndpointIsAsked() async {
        SuggestionsStubProtocol.reset(script: body(#"["swift",["swift lang"]]"#))
        let client = makeClient()

        let result = await client.suggestions(for: "swift", engine: .duckDuckGo)

        XCTAssertEqual(result, ["swift lang"])
        XCTAssertEqual(SuggestionsStubProtocol.requestedURLs.map(\.absoluteString), ["https://duckduckgo.com/ac/?q=swift&type=list"])
    }

    func test_queryIsTrimmedBeforeItIsSent() async {
        SuggestionsStubProtocol.reset(script: body(#"["a",["abc"]]"#))
        let client = makeClient()

        _ = await client.suggestions(for: "  a \n", engine: .duckDuckGo)

        XCTAssertEqual(SuggestionsStubProtocol.requestedURLs.map(\.absoluteString), ["https://duckduckgo.com/ac/?q=a&type=list"])
    }

    func test_unreachableEndpoint_degradesToEmptyArrayAfterActuallyTryingOnce() async {
        SuggestionsStubProtocol.reset(script: .fail)
        let client = makeClient()

        let result = await client.suggestions(for: "orbit browser")

        XCTAssertEqual(result, [], "A failed request must degrade silently to no suggestions, never throw or surface an error.")
        XCTAssertEqual(SuggestionsStubProtocol.requestedURLs.count, 1, "the empty result must come from a request that was made and failed, not from no request at all")
    }

    func test_malformedOrUnexpectedResponses_degradeToEmptyArray() async {
        let client = makeClient()
        for payload in ["not json", #"{"a":1}"#, #"["only one element"]"#, #"["q",[1,2,3]]"#, #"["q","not an array"]"#] {
            SuggestionsStubProtocol.reset(script: body(payload))
            let result = await client.suggestions(for: "q")
            XCTAssertEqual(result, [], "payload \(payload) is not an OpenSearch suggestions array")
            XCTAssertEqual(SuggestionsStubProtocol.requestedURLs.count, 1, "payload \(payload) must have been requested")
        }
    }

    func test_rapidSuccessiveCalls_debounceCancelsThePreviousOneSoOnlyTheLastIsRequested() async {
        SuggestionsStubProtocol.reset(script: body(#"["ab",["abacus","abbey"]]"#))
        let client = makeClient(debounceNanoseconds: 600_000_000)

        async let first = client.suggestions(for: "a", engine: .duckDuckGo)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let second = await client.suggestions(for: "ab", engine: .duckDuckGo)
        let firstResult = await first

        XCTAssertEqual(firstResult, [], "The superseded first call must resolve to no suggestions once cancelled.")
        XCTAssertEqual(second, ["abacus", "abbey"], "The surviving call must return what the endpoint answered.")
        XCTAssertEqual(
            SuggestionsStubProtocol.requestedURLs.map(\.absoluteString),
            ["https://duckduckgo.com/ac/?q=ab&type=list"],
            "Only the surviving call may reach the network: the debounced first one is cancelled before it sends."
        )
    }
}

private final class SuggestionsStubProtocol: URLProtocol, @unchecked Sendable {
    enum Script {
        case respond(Data)
        case fail
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: Script = .respond(Data())
    nonisolated(unsafe) private static var urls: [URL] = []

    static func reset(script: Script) {
        lock.lock()
        defer { lock.unlock() }
        self.script = script
        urls = []
    }

    static var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scripted: Script
        Self.lock.lock()
        if let url = request.url { Self.urls.append(url) }
        scripted = Self.script
        Self.lock.unlock()

        switch scripted {
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .respond(let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
