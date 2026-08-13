// PageTextExtract's "I read the first N%" notice must come from a real measurement.
// Every Assist feature must ship off and survive a real write-then-reload.

import Foundation
import XCTest

final class PageTextExtractorTests: XCTestCase {

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parse_readsTheBridgeDictionaryTheScriptReturns

    func test_parse_readsTheBridgeDictionaryTheScriptReturns() throws {
        let value: [String: Any] = [
            "title": "What Makes Oaxacan Food Oaxacan?",
            "url": "https://www.eater.com/oaxaca",
            "total": 5000,
            "text": "Chapulines are toasted grasshoppers.",
        ]
        let extract = try XCTUnwrap(PageTextExtractor.parse(value))
        XCTAssertEqual(extract.title, "What Makes Oaxacan Food Oaxacan?")
        XCTAssertEqual(extract.url, "https://www.eater.com/oaxaca")
        XCTAssertEqual(extract.text, "Chapulines are toasted grasshoppers.")
        XCTAssertEqual(extract.totalCharacters, 5000)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parse_returnsNilForAPageWithNoVisibleText

    func test_parse_returnsNilForAPageWithNoVisibleText() {
        XCTAssertNil(PageTextExtractor.parse(["title": "x", "url": "y", "total": 0, "text": "   \n "]))
        XCTAssertNil(PageTextExtractor.parse(nil))
        XCTAssertNil(PageTextExtractor.parse("a bare string"))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parse_neverReportsATotalSmallerThanWhatItActuallyHas

    func test_parse_neverReportsATotalSmallerThanWhatItActuallyHas() {
        let extract = PageTextExtractor.parse(["title": "", "url": "", "total": 2, "text": "much longer text"])
        XCTAssertEqual(extract?.totalCharacters, 16)
        XCTAssertEqual(extract?.includedFraction, 1.0)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_truncationNotice_matchesTheSentenceArcsOwnCaptureShows

    func test_truncationNotice_matchesTheSentenceArcsOwnCaptureShows() {
        let extract = PageTextExtract(title: "", url: "", text: String(repeating: "a", count: 800), totalCharacters: 1000)
        XCTAssertEqual(extract.truncationNotice, "This page was long, so I read the first 80%.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_truncationNotice_isNilWhenNothingWasCut

    func test_truncationNotice_isNilWhenNothingWasCut() {
        let extract = PageTextExtract(title: "", url: "", text: "all of it", totalCharacters: 9)
        XCTAssertFalse(extract.wasTruncated)
        XCTAssertNil(extract.truncationNotice)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_truncationNotice_roundsDownSoItNeverOverclaims

    func test_truncationNotice_roundsDownSoItNeverOverclaims() {
        let extract = PageTextExtract(title: "", url: "", text: String(repeating: "a", count: 899), totalCharacters: 1000)
        XCTAssertEqual(extract.truncationNotice, "This page was long, so I read the first 89%.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_script_asksForInnerTextRatherThanTextContent

    func test_script_asksForInnerTextRatherThanTextContent() {
        let script = PageTextExtractor.script()
        XCTAssertTrue(script.contains("innerText"))
        XCTAssertFalse(script.contains("textContent"))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_script_carriesTheCharacterBudgetItWasGiven

    func test_script_carriesTheCharacterBudgetItWasGiven() {
        XCTAssertTrue(PageTextExtractor.script(characterBudget: 1234).contains("slice(0, 1234)"))
    }
}

final class AssistSettingsDefaultsTests: XCTestCase {

    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AssistSettingsDefaultsTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        AssistSettings.defaults = suite
        AssistKeychain.inMemoryOverride = [:]
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        AssistKeychain.inMemoryOverride = nil
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    private func configureProvider() {
        AssistSettings.baseURLString = "https://api.openai.com/v1"
        AssistSettings.model = "gpt-4o-mini"
        AssistSettings.apiKey = "sk-test"
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_assistItselfShipsOff

    func test_assistItselfShipsOff() {
        XCTAssertFalse(AssistSettings.isEnabled)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_everyAssistFeatureShipsOff

    func test_everyAssistFeatureShipsOff() {
        XCTAssertFalse(AssistSettings.isAskOnPageEnabled)
        XCTAssertFalse(AssistSettings.isTidyTabTitlesEnabled)
        XCTAssertFalse(AssistSettings.isTidyDownloadsEnabled)
        XCTAssertFalse(AssistSettings.isTidyTabsEnabled)
        XCTAssertFalse(AssistSettings.isFiveSecondPreviewsEnabled)
        XCTAssertFalse(AssistSettings.isChatGPTCommandBarEnabled)
        XCTAssertFalse(AssistSettings.isInstantLinksEnabled)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theProviderDefaultsToAnthropicOutOfTheBox

    func test_theProviderDefaultsToAnthropicOutOfTheBox() {
        XCTAssertEqual(AssistSettings.providerKind, .anthropic)
        XCTAssertEqual(AssistSettings.baseURLString, "", "The base URL is only stored once the user types one")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_noProviderIsConfiguredOutOfTheBox

    func test_noProviderIsConfiguredOutOfTheBox() {
        XCTAssertFalse(AssistSettings.isProviderConfigured)
        XCTAssertFalse(AssistSettings.isAnyFeatureLive)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_everyFeatureStaysDeadWhileAssistItselfIsOff

    func test_everyFeatureStaysDeadWhileAssistItselfIsOff() {
        configureProvider()
        AssistSettings.isAskOnPageEnabled = true
        AssistSettings.isTidyTabsEnabled = true
        AssistSettings.isTidyTabTitlesEnabled = true
        AssistSettings.isTidyDownloadsEnabled = true
        AssistSettings.isFiveSecondPreviewsEnabled = true
        AssistSettings.isChatGPTCommandBarEnabled = true
        AssistSettings.isInstantLinksEnabled = true

        XCTAssertFalse(AssistSettings.isAskOnPageEnabled)
        XCTAssertFalse(AssistSettings.isTidyTabsEnabled)
        XCTAssertFalse(AssistSettings.isTidyTabTitlesEnabled)
        XCTAssertFalse(AssistSettings.isTidyDownloadsEnabled)
        XCTAssertFalse(AssistSettings.isFiveSecondPreviewsEnabled)
        XCTAssertFalse(AssistSettings.isChatGPTCommandBarEnabled)
        XCTAssertFalse(AssistSettings.isInstantLinksEnabled)
        XCTAssertFalse(AssistSettings.isAnyFeatureLive)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_turningAssistOffAndOnAgainRestoresTheSwitchesTheUserChose

    func test_turningAssistOffAndOnAgainRestoresTheSwitchesTheUserChose() {
        AssistSettings.isEnabled = true
        AssistSettings.isAskOnPageEnabled = true
        AssistSettings.isTidyDownloadsEnabled = false

        AssistSettings.isEnabled = false
        XCTAssertFalse(AssistSettings.isAskOnPageEnabled)
        XCTAssertTrue(AssistSettings.storedFlag(AssistSettings.askOnPageEnabledKey))

        AssistSettings.isEnabled = true
        XCTAssertTrue(AssistSettings.isAskOnPageEnabled)
        XCTAssertFalse(AssistSettings.isTidyDownloadsEnabled)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_configuringAProviderAloneDoesNotMakeAnyFeatureLive

    func test_configuringAProviderAloneDoesNotMakeAnyFeatureLive() {
        AssistSettings.isEnabled = true
        configureProvider()

        XCTAssertTrue(AssistSettings.isProviderConfigured)
        XCTAssertFalse(
            AssistSettings.isAnyFeatureLive,
            "Configuring a provider is consent to use Assist, not consent for Assist to start reading pages"
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aFeatureIsOnlyLiveWithAssistOnAProviderAndItsOwnSwitch

    func test_aFeatureIsOnlyLiveWithAssistOnAProviderAndItsOwnSwitch() {
        AssistSettings.isAskOnPageEnabled = true
        configureProvider()
        XCTAssertFalse(AssistSettings.isAnyFeatureLive, "A switch behind a switched-off Assist is not live")

        AssistSettings.isEnabled = true
        XCTAssertTrue(AssistSettings.isAnyFeatureLive)
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_switchingProviderKeepsEachProvidersOwnKey

    func test_switchingProviderKeepsEachProvidersOwnKey() {
        AssistSettings.providerKind = .anthropic
        AssistSettings.apiKey = "sk-ant-secret"
        AssistSettings.providerKind = .openAICompatible
        XCTAssertEqual(AssistSettings.apiKey, "", "The Anthropic key must not be offered to a different provider")

        AssistSettings.apiKey = "sk-openai-secret"
        AssistSettings.providerKind = .anthropic
        XCTAssertEqual(AssistSettings.apiKey, "sk-ant-secret")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_providerConfigCarriesTheKindTheBaseURLAndTheModel

    func test_providerConfigCarriesTheKindTheBaseURLAndTheModel() {
        AssistSettings.isEnabled = true
        AssistSettings.providerKind = .openAICompatible
        AssistSettings.baseURLString = "http://localhost:1234/v1"
        AssistSettings.model = "local-model"

        let config = AssistSettings.providerConfig
        XCTAssertEqual(config.kind, .openAICompatible)
        XCTAssertEqual(config.requestURL?.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertTrue(config.isConfigured, "A loopback provider needs no key")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aPreviouslySavedFullEndpointIsStillUsedUntilANewBaseURLIsTyped

    func test_aPreviouslySavedFullEndpointIsStillUsedUntilANewBaseURLIsTyped() {
        suite.set("https://api.openai.com/v1/chat/completions", forKey: AssistSettings.providerEndpointKey)
        XCTAssertEqual(AssistSettings.baseURLString, "https://api.openai.com/v1/chat/completions")

        AssistSettings.baseURLString = "https://openrouter.ai/api/v1"
        XCTAssertEqual(AssistSettings.baseURLString, "https://openrouter.ai/api/v1")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_settingsSurviveAWriteThenReloadThroughASecondUserDefaults

    func test_settingsSurviveAWriteThenReloadThroughASecondUserDefaults() throws {
        AssistSettings.isEnabled = true
        AssistSettings.providerKind = .openAICompatible
        AssistSettings.baseURLString = "http://localhost:11434/v1"
        AssistSettings.model = "llama3"
        AssistSettings.isTidyDownloadsEnabled = true

        let reader = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertTrue(reader.bool(forKey: AssistSettings.enabledKey))
        XCTAssertEqual(reader.string(forKey: AssistSettings.providerKindKey), AssistProviderKind.openAICompatible.rawValue)
        XCTAssertEqual(reader.string(forKey: AssistSettings.providerBaseURLKey), "http://localhost:11434/v1")
        XCTAssertEqual(reader.string(forKey: AssistSettings.providerModelKey), "llama3")
        XCTAssertTrue(reader.bool(forKey: AssistSettings.tidyDownloadsEnabledKey))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_theAPIKeyIsNeverWrittenIntoUserDefaults

    func test_theAPIKeyIsNeverWrittenIntoUserDefaults() throws {
        AssistSettings.apiKey = "sk-super-secret"
        let reader = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let dump = reader.dictionaryRepresentation()
        for (key, value) in dump {
            if let string = value as? String {
                XCTAssertFalse(string.contains("sk-super-secret"), "The key leaked into UserDefaults under \(key)")
            }
        }
        XCTAssertEqual(AssistSettings.apiKey, "sk-super-secret")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_clearingTheAPIKeyRemovesIt

    func test_clearingTheAPIKeyRemovesIt() {
        AssistSettings.apiKey = "sk-test"
        AssistSettings.apiKey = ""
        XCTAssertEqual(AssistSettings.apiKey, "")
    }
}
