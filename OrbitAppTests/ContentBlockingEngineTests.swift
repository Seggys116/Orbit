import XCTest
@testable import Orbit

@MainActor
final class ContentBlockingEngineTests: XCTestCase {

    // MARK: - Capability honesty

    func testControllerReportsNilRatherThanZeroWhenTheBackendCannotCount() async {
        let defaults = UserDefaults(suiteName: "ContentBlockingEngineTests.\(UUID().uuidString)")!
        let controller = ContentBlockingController(defaults: defaults)

        let engine = BlockingWithoutCountingEngine()
        try? engine.start()
        await controller.attach(engine: engine, sessions: [engine.defaultSession])

        XCTAssertFalse(controller.engineCanCountBlockedRequests)
        XCTAssertNil(controller.blockedRequestCount,
                     "a count that cannot be substantiated must be nil, not 0")
        XCTAssertNil(controller.blockedRequestCount(forHost: "example.com"))
        XCTAssertTrue(controller.engineSupportsContentBlocking)
    }

    // MARK: - Controller behaviour

    func testControllerPersistsAndRestoresTheAllowlistAndAppliesItToTheBlocker() async {
        let suite = "ContentBlockingEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = ContentBlockingController(defaults: defaults)
        var set = ContentBlockerRuleSet()
        set.add(listText: "||adnxs.com^\n", listID: "L")
        controller.blocker.setRuleSet(set)

        let url = URL(string: "https://www.news.example/story")!
        XCTAssertFalse(controller.isAllowlisted(url))
        XCTAssertTrue(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: url.absoluteString, resourceType: .script
        ).isBlocked)

        await controller.setAllowlisted(true, for: url)
        XCTAssertTrue(controller.isAllowlisted(url))
        XCTAssertFalse(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: url.absoluteString, resourceType: .script
        ).isBlocked, "the controller's toggle must move the matcher, not just its own state")

        let reloaded = ContentBlockingController(defaults: defaults)
        reloaded.blocker.setRuleSet(set)
        XCTAssertTrue(reloaded.isAllowlisted(url))
        XCTAssertFalse(reloaded.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: url.absoluteString, resourceType: .script
        ).isBlocked)

        await controller.setAllowlisted(false, for: url)
        XCTAssertFalse(controller.isAllowlisted(url))
        XCTAssertTrue(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: url.absoluteString, resourceType: .script
        ).isBlocked)
    }

    func testControllerStartsWithNoRulesUntilListsAreFetched() {
        let suite = "ContentBlockingEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = ContentBlockingController(defaults: defaults)
        XCTAssertEqual(controller.compiledRuleCount, 0)
        XCTAssertNil(controller.lastUpdatedAt)
        XCTAssertEqual(controller.enabledListIDs, FilterListCatalog.defaultEnabledIDs)
    }

    func testTurningTheMasterSwitchOffStopsTheMatcher() async {
        let suite = "ContentBlockingEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = ContentBlockingController(defaults: defaults)
        var set = ContentBlockerRuleSet()
        set.add(listText: "||adnxs.com^\n", listID: "L")
        controller.blocker.setRuleSet(set)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked)

        await controller.setEnabled(false)
        XCTAssertEqual(controller.blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ), .disabled)
    }

    // MARK: - Store

    func testStoreRejectsAResponseThatIsNotAFilterList() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-cb-tests-\(UUID().uuidString)", isDirectory: true)
        let store = FilterListStore(directory: directory, session: StubURLProtocol.makeSession())

        StubURLProtocol.response = (
            Data("<html><body>Sign in to the network</body></html>".utf8), 200, [:]
        )
        let descriptor = try XCTUnwrap(FilterListCatalog.descriptor(id: "EasyList"))
        let state = await store.update(descriptor, force: true)
        guard case .failed = state else {
            return XCTFail("Expected .failed for an HTML response, got \(state)")
        }
        let cached = await store.cachedText(for: "EasyList")
        XCTAssertNil(cached, "nothing may be cached from a non-filter-list response")
    }

    func testStoreCachesAndVersionsARealFilterList() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-cb-tests-\(UUID().uuidString)", isDirectory: true)
        let store = FilterListStore(directory: directory, session: StubURLProtocol.makeSession())

        let body = """
        [Adblock Plus 2.0]
        ! Version: 202606111618
        ! Title: EasyList
        ! Expires: 4 days (update frequency)
        ||adnxs.com^
        """
        StubURLProtocol.response = (Data(body.utf8), 200, ["ETag": "\"abc123\""])

        let descriptor = try XCTUnwrap(FilterListCatalog.descriptor(id: "EasyList"))
        let state = await store.update(descriptor, force: true)
        guard case .cached(let entry) = state else {
            return XCTFail("Expected .cached, got \(state)")
        }
        XCTAssertEqual(entry.declaredVersion, "202606111618")
        XCTAssertEqual(entry.expiresAfter, 4 * 86_400)
        XCTAssertEqual(entry.etag, "\"abc123\"")
        XCTAssertEqual(entry.byteCount, Data(body.utf8).count + 1)  // trailing newline
        XCTAssertFalse(entry.contentHash.isEmpty)

        let text = await store.cachedText(for: "EasyList")
        XCTAssertTrue(text?.contains("||adnxs.com^") == true)

        var set = ContentBlockerRuleSet()
        set.add(listText: try XCTUnwrap(text), listID: "EasyList")
        let blocker = ContentBlocker()
        blocker.setRuleSet(set)
        blocker.isEnabled = true
        XCTAssertTrue(blocker.decision(
            forURL: "https://ib.adnxs.com/x", documentURL: "https://a.example/", resourceType: .script
        ).isBlocked, "a list that round-tripped through the cache must still block")
    }

    func testConditionalRequestRefreshesTheCheckTimeWithoutRewritingTheCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-cb-tests-\(UUID().uuidString)", isDirectory: true)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = FilterListStore(
            directory: directory,
            session: StubURLProtocol.makeSession(),
            now: { clock }
        )

        StubURLProtocol.response = (
            Data("[Adblock Plus 2.0]\n! Version: 1\n! Expires: 1 hours\n||adnxs.com^".utf8),
            200,
            ["ETag": "\"v1\""]
        )
        let descriptor = try XCTUnwrap(FilterListCatalog.descriptor(id: "EasyList"))
        guard case .cached(let first) = await store.update(descriptor, force: true) else {
            return XCTFail("first fetch should have cached")
        }
        XCTAssertEqual(first.fetchedAt, first.lastCheckedAt)

        clock = clock.addingTimeInterval(7200)  // past the declared 1-hour expiry
        StubURLProtocol.response = (Data(), 304, [:])
        let second = await store.update(descriptor)
        guard case .stale(let refreshed) = second else {
            return XCTFail("Expected .stale after a 304 past expiry, got \(second)")
        }
        XCTAssertEqual(refreshed.fetchedAt, first.fetchedAt, "a 304 must not move the fetch time")
        XCTAssertEqual(refreshed.lastCheckedAt, clock, "a 304 must move the check time")
        XCTAssertEqual(refreshed.contentHash, first.contentHash)
    }
}

// MARK: - URL stub

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (Data, Int, [String: String]) = (Data(), 200, [:])

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (data, status, headers) = Self.response
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


// MARK: - A backend that blocks but cannot count

@MainActor
private final class BlockingWithoutCountingEngine: BrowserEngine {
    static let kind: EngineKind = .chromium
    let capabilities: EngineCapabilities = [.contentBlocking]
    let manageableContentSettings: Set<PermissionKind> = []
    let extensionActivation: ExtensionActivation = .unsupported
    let versionDescription = "Blocking-without-counting stub"

    private lazy var stubSession = MockEngineSession()

    func start() throws {}
    func shutdown() -> Bool { true }
    func tick() {}

    func session(identifier: String, persistent: Bool) throws -> EngineSession { stubSession }
    var defaultSession: EngineSession { stubSession }

    func makeWebContents(session: EngineSession, initialURL: URL?) throws -> WebContents {
        throw EngineError(code: .engineUnavailable)
    }

    func clearBrowsingData(_ scope: BrowsingDataScope, session: EngineSession, since: Date?) async {}
    func addUserScript(_ script: UserScript, session: EngineSession) {}
    func removeUserScript(id: UUID, session: EngineSession) {}
    func applyContentBlocker(_ blocker: ContentBlocker?, session: EngineSession) async {}

    func loadExtension(at directory: URL, session: EngineSession) async throws -> LoadedExtension {
        throw EngineError(code: .engineUnavailable)
    }
    func unloadExtension(id: String, session: EngineSession) {}
    func loadedExtensions(session: EngineSession) -> [LoadedExtension] { [] }
}
