import Foundation
import XCTest

final class AssistProviderConfigTests: XCTestCase {

    func test_isConfigured_falseWithAnUnusableBaseURL_evenWithAModelAndKey() {
        for base in ["not a url", "ftp://example.com", "api.openai.com/v1"] {
            let config = AssistProviderConfig(kind: .openAICompatible, baseURLString: base, model: "gpt-4o-mini", apiKey: "sk-live")
            XCTAssertFalse(config.isConfigured, "\(base) is not a usable http(s) base URL")
        }
    }

    func test_anEmptyBaseURLFallsBackToTheProvidersOwnDefault() {
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .anthropic, baseURLString: "")?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .openAICompatible, baseURLString: "  ")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }

    func test_requestURL_appendsTheProvidersPathToACustomBaseURL() {
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .openAICompatible, baseURLString: "https://openrouter.ai/api/v1")?.absoluteString,
            "https://openrouter.ai/api/v1/chat/completions"
        )
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .openAICompatible, baseURLString: "http://localhost:11434/v1/")?.absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .anthropic, baseURLString: "https://gateway.example.com/anthropic")?.absoluteString,
            "https://gateway.example.com/anthropic/v1/messages"
        )
    }

    func test_requestURL_leavesABaseThatAlreadyNamesThePathAlone() {
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .anthropic, baseURLString: "https://api.anthropic.com/v1/messages")?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .openAICompatible, baseURLString: "https://api.openai.com/v1/chat/completions")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }

    func test_requestURL_doesNotDoubleTheVersionSegmentForAnthropic() {
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .anthropic, baseURLString: "https://api.anthropic.com/v1")?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
    }

    func test_requestURL_dropsAQueryOrFragmentRatherThanSigningItIntoThePath() {
        XCTAssertEqual(
            AssistProviderKind.requestURL(kind: .anthropic, baseURLString: "https://api.anthropic.com?key=leak#frag")?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
    }

    func test_isConfigured_falseWithABaseURLAndKeyButNoModel() {
        let config = AssistProviderConfig(kind: .anthropic, baseURLString: "https://api.anthropic.com", model: "   ", apiKey: "sk-ant-live")
        XCTAssertFalse(config.isConfigured, "A blank model cannot be sent; the provider is not usable.")
    }

    func test_isConfigured_falseForARemoteProviderWithNoKey() {
        let config = AssistProviderConfig(kind: .anthropic, baseURLString: "https://api.anthropic.com", model: "claude-opus-5", apiKey: "")
        XCTAssertFalse(config.isConfigured)
    }

    func test_isConfigured_trueForALoopbackProviderWithNoKey() {
        for host in ["localhost", "127.0.0.1"] {
            let config = AssistProviderConfig(
                kind: .openAICompatible,
                baseURLString: "http://\(host):11434/v1",
                model: "llama3",
                apiKey: ""
            )
            XCTAssertTrue(config.isConfigured, "\(host) should not require a key")
        }
    }

    func test_destinationDescription_namesTheRealHost_notAVendor() {
        let config = AssistProviderConfig(kind: .openAICompatible, baseURLString: "https://openrouter.ai/api/v1", model: "x", apiKey: "k")
        XCTAssertEqual(config.destinationDescription, "openrouter.ai")
    }

    func test_destinationDescription_withNoProvider_saysSo() {
        XCTAssertEqual(AssistProviderConfig(baseURLString: "nonsense").destinationDescription, "no provider")
    }
}

final class AssistProviderWireFormatTests: XCTestCase {

    // MARK: Anthropic

    func test_anthropicBody_putsTheSystemPromptAtTopLevelAndSendsOnlyAUserMessage() throws {
        let request = AssistRequest(system: "SYSTEM-TEXT", user: "USER-TEXT", maxOutputTokens: 77, temperature: 0.25)
        let data = try AssistProviderClient.encodeBody(request, kind: .anthropic, model: "claude-opus-5")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["model"] as? String, "claude-opus-5")
        XCTAssertEqual(root["max_tokens"] as? Int, 77)
        XCTAssertEqual(root["stream"] as? Bool, false)
        XCTAssertEqual(root["system"] as? String, "SYSTEM-TEXT")

        let messages = try XCTUnwrap(root["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1, "Anthropic rejects a system-role message")
        XCTAssertEqual(messages[0]["role"], "user")
        XCTAssertEqual(messages[0]["content"], "USER-TEXT")
    }

    func test_anthropicBody_omitsTemperature_whichCurrentClaudeModelsReject() throws {
        let data = try AssistProviderClient.encodeBody(
            AssistRequest(system: "s", user: "u", temperature: 0.0),
            kind: .anthropic,
            model: "claude-opus-5"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["temperature"])
    }

    func test_anthropicHeaders_sendTheAPIVersionAndTheKeyAsXAPIKey() {
        let headers = AssistProviderClient.headers(kind: .anthropic, apiKey: " sk-ant-live ")
        XCTAssertEqual(headers["x-api-key"], "sk-ant-live")
        XCTAssertEqual(headers["anthropic-version"], AssistProviderClient.anthropicVersion)
        XCTAssertNil(headers["Authorization"], "A bearer header alongside x-api-key is not what Anthropic asks for")
    }

    func test_anthropicHeaders_stillCarryTheVersionWithNoKey_soALocalServerWorks() {
        let headers = AssistProviderClient.headers(kind: .anthropic, apiKey: "")
        XCTAssertEqual(headers["anthropic-version"], AssistProviderClient.anthropicVersion)
        XCTAssertNil(headers["x-api-key"])
    }

    // MARK: OpenAI-compatible

    func test_openAIBody_carriesTheSystemPromptTheUserPromptTheModelAndTheTemperature() throws {
        let request = AssistRequest(system: "SYSTEM-TEXT", user: "USER-TEXT", maxOutputTokens: 77, temperature: 0.25)
        let data = try AssistProviderClient.encodeBody(request, kind: .openAICompatible, model: "some-model")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["model"] as? String, "some-model")
        XCTAssertEqual(root["max_tokens"] as? Int, 77)
        XCTAssertEqual(root["stream"] as? Bool, false)
        XCTAssertEqual(root["temperature"] as? Double, 0.25)

        let messages = try XCTUnwrap(root["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "SYSTEM-TEXT")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "USER-TEXT")
    }

    func test_openAIHeaders_sendTheKeyAsABearerTokenAndNothingAnthropicSpecific() {
        let headers = AssistProviderClient.headers(kind: .openAICompatible, apiKey: " sk-live ")
        XCTAssertEqual(headers["Authorization"], "Bearer sk-live")
        XCTAssertNil(headers["x-api-key"])
        XCTAssertNil(headers["anthropic-version"])
    }

    func test_openAIHeaders_areEmptyWithNoKey_soALocalServerWorks() {
        XCTAssertTrue(AssistProviderClient.headers(kind: .openAICompatible, apiKey: "").isEmpty)
    }

    // MARK: Decoding

    func test_decodeCompletion_readsTheOpenAIChatShape() throws {
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"  the answer  "}}]}"#.utf8)
        XCTAssertEqual(try AssistProviderClient.decodeCompletion(body), "the answer")
    }

    func test_decodeCompletion_readsTheAnthropicMessagesShape() throws {
        let body = Data(#"{"content":[{"type":"text","text":"first "},{"type":"text","text":"second"}]}"#.utf8)
        XCTAssertEqual(try AssistProviderClient.decodeCompletion(body), "first second")
    }

    func test_decodeCompletion_readsTheLegacyCompletionsShape() throws {
        let body = Data(#"{"choices":[{"text":"legacy answer"}]}"#.utf8)
        XCTAssertEqual(try AssistProviderClient.decodeCompletion(body), "legacy answer")
    }

    func test_decodeCompletion_throwsRatherThanReturningAnEmptyAnswer() {
        let body = Data(#"{"choices":[{"message":{"content":"   \n  "}}]}"#.utf8)
        XCTAssertThrowsError(try AssistProviderClient.decodeCompletion(body)) { error in
            XCTAssertEqual(error as? AssistError, .emptyCompletion)
        }
    }

    func test_decodeCompletion_surfacesAProviderErrorBodyRatherThanSwallowingIt() {
        let body = Data(#"{"error":{"message":"model not found"}}"#.utf8)
        XCTAssertThrowsError(try AssistProviderClient.decodeCompletion(body)) { error in
            XCTAssertEqual(error as? AssistError, .malformedResponse("model not found"))
        }
    }

    func test_decodeCompletion_throwsOnANonObjectBody() {
        XCTAssertThrowsError(try AssistProviderClient.decodeCompletion(Data("not json".utf8)))
    }

    func test_generate_withNoProviderConfigured_throwsNotConfiguredWithoutTouchingTheNetwork() async {
        let client = AssistProviderClient(config: AssistProviderConfig())
        do {
            _ = try await client.generate(AssistRequest(system: "s", user: "u"))
            XCTFail("An unconfigured client must refuse rather than attempt a request")
        } catch {
            XCTAssertEqual(error as? AssistError, .notConfigured)
        }
    }
}
