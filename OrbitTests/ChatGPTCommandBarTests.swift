import XCTest

@MainActor
final class ChatGPTCommandBarTests: XCTestCase {

    private func makeEnvironment() -> AppEnvironment {
        let env = AppEnvironment()
        let profile = Profile(name: "Personal")
        env.state.profiles = [profile]
        let space = Space(name: "Personal", profileID: profile.id)
        env.state.spaces = [space]
        env.state.activeSpaceID = space.id
        return env
    }

    // MARK: - 5. URL building and percent-encoding

    func test_url_percentEncodesSpacesAmpersandPlusAndHash() throws {
        let url = try XCTUnwrap(ChatGPTCommandBar.url(for: "cats & dogs + fish #1"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "chatgpt.com")
        let queryItems = try XCTUnwrap(components.queryItems)
        let q = queryItems.first { $0.name == "q" }
        XCTAssertEqual(q?.value, "cats & dogs + fish #1", "The four characters must round-trip back to exactly what was typed, proving they were escaped rather than left to be read as URL syntax.")
        XCTAssertEqual(queryItems.first { $0.name == "hints" }?.value, "search")
        XCTAssertFalse(url.absoluteString.contains(" "), "A raw space must never appear literally in the URL string.")
    }

    func test_url_hostAndHintsParameterAreExactlyAsSourced() throws {
        let url = try XCTUnwrap(ChatGPTCommandBar.url(for: "test"))
        XCTAssertEqual(url.host, "chatgpt.com")
        XCTAssertTrue(url.absoluteString.contains("hints=search"))
    }

    func test_url_emptyQuery_returnsNil() {
        XCTAssertNil(ChatGPTCommandBar.url(for: ""))
    }

    // MARK: - 9 (shared): no `btnI` is ever produced

    func test_url_neverProducesTheOldBtnIParameter() {
        XCTAssertFalse(ChatGPTCommandBar.url(for: "anything")?.absoluteString.contains("btnI") ?? false)
    }

    // MARK: - Shortcut matching (route 2)

    func test_isShortcut_matchesBothAliasesCaseInsensitively() {
        XCTAssertTrue(ChatGPTCommandBar.isShortcut("gpt"))
        XCTAssertTrue(ChatGPTCommandBar.isShortcut("GPT"))
        XCTAssertTrue(ChatGPTCommandBar.isShortcut("chatgpt"))
        XCTAssertTrue(ChatGPTCommandBar.isShortcut("ChatGPT"))
    }

    func test_isShortcut_doesNotMatchAPrefixOrUnrelatedText() {
        XCTAssertFalse(ChatGPTCommandBar.isShortcut("g"))
        XCTAssertFalse(ChatGPTCommandBar.isShortcut("chat"))
        XCTAssertFalse(ChatGPTCommandBar.isShortcut("gpt4"))
        XCTAssertFalse(ChatGPTCommandBar.isShortcut(""))
    }

    // MARK: - The incognito/feature gate (requirement 8)

    func test_isAvailable_trueOnlyWhenEnabledAndNotIncognito() {
        XCTAssertTrue(ChatGPTCommandBar.isAvailable(featureEnabled: true, isIncognito: false))
        XCTAssertFalse(ChatGPTCommandBar.isAvailable(featureEnabled: true, isIncognito: true), "Incognito must refuse even when the switch is on.")
        XCTAssertFalse(ChatGPTCommandBar.isAvailable(featureEnabled: false, isIncognito: false), "The switch being off must refuse even outside Incognito.")
        XCTAssertFalse(ChatGPTCommandBar.isAvailable(featureEnabled: false, isIncognito: true))
    }

    // MARK: - 6 & 7. Engagement and the unscoped `Ask ChatGPT` row, via the real ranking engine

    func test_engagingChatGPTScope_collapsesToASingleGreenChatGPTRow() {
        let chatGPTEngine = ChatGPTCommandBar.virtualEngine()
        let env = makeEnvironment()
        let scoped = CommandBarEngine.results(
            query: "how do you like Orbit",
            mode: .newTab,
            env: env,
            suggestions: [],
            siteSearch: SiteSearchState(engines: [], active: chatGPTEngine)
        )
        XCTAssertEqual(scoped.count, 1, "Scoped to ChatGPT with nothing else configured, only the literal query row must appear.")
        guard case .siteSearch(let engine, let query, _) = scoped[0].kind else {
            XCTFail("Expected a .siteSearch row while scoped, got \(scoped[0].kind).")
            return
        }
        XCTAssertEqual(engine.id, ChatGPTCommandBar.virtualEngineID)
        XCTAssertEqual(query, "how do you like Orbit")
        XCTAssertEqual(scoped[0].title, "how do you like Orbit")
    }

    func test_engagedChatGPTRow_activationIntentNavigatesToTheChatGPTURL() throws {
        let chatGPTEngine = ChatGPTCommandBar.virtualEngine()
        let env = makeEnvironment()
        let scoped = CommandBarEngine.results(
            query: "hello",
            mode: .newTab,
            env: env,
            suggestions: [],
            siteSearch: SiteSearchState(engines: [], active: chatGPTEngine)
        )
        let row = try XCTUnwrap(scoped.first)
        guard case .navigate(let url) = row.kind.activationIntent else {
            XCTFail("Expected .navigate, got \(row.kind.activationIntent).")
            return
        }
        XCTAssertEqual(url, ChatGPTCommandBar.url(for: "hello"))
        XCTAssertEqual(url.host, "chatgpt.com")
    }

    func test_unscopedResults_withChatGPTUnavailable_offersNoAskChatGPTRow() {
        let env = makeEnvironment()
        let results = CommandBarEngine.results(
            query: "how do you like Orbit",
            mode: .newTab,
            env: env,
            suggestions: [],
            isChatGPTCommandBarAvailable: false
        )
        XCTAssertFalse(results.contains { if case .chatGPTAsk = $0.kind { return true }; return false }, "No .chatGPTAsk row must be produced when the feature is unavailable.")
    }

    func test_unscopedResults_withChatGPTAvailable_offersAskChatGPTRowThatNavigatesCorrectly() throws {
        let env = makeEnvironment()
        let results = CommandBarEngine.results(
            query: "how do you like Orbit",
            mode: .newTab,
            env: env,
            suggestions: [],
            isChatGPTCommandBarAvailable: true
        )
        let row = try XCTUnwrap(results.first { if case .chatGPTAsk = $0.kind { return true }; return false }, "Expected a .chatGPTAsk row when the feature is available.")
        guard case .navigate(let url) = row.kind.activationIntent else {
            XCTFail("Expected .navigate, got \(row.kind.activationIntent).")
            return
        }
        XCTAssertEqual(url, ChatGPTCommandBar.url(for: "how do you like Orbit"))
    }

}
