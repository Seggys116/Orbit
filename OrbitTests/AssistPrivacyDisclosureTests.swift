import XCTest

final class AssistPrivacyDisclosureTests: XCTestCase {

    private let host = "api.example-provider.test"
    private let budget = 24_000

    private func copy(_ switches: AssistPrivacyDisclosure.Switches) -> String {
        AssistPrivacyDisclosure.copy(for: switches, providerHost: host, pageCharacterBudget: budget)
    }

    // MARK: - Property 1: nothing on, nothing claimed

    func test_everySwitchOff_promisesNoRequestsAtAllAndNamesNoRecipient() {
        let text = copy(AssistPrivacyDisclosure.Switches())

        XCTAssertTrue(
            text.contains("Orbit makes no requests"),
            "With every switch off the disclosure must say no requests are made. Got: \(text)"
        )
        XCTAssertFalse(
            AssistPrivacyDisclosure.namesProvider(text, host: host),
            "With every switch off nothing calls the provider, so the provider must not be named."
        )
        for recipient in ["chatgpt.com", "search engine", "the site itself"] {
            XCTAssertFalse(
                text.contains(recipient),
                "The all-off disclosure named '\(recipient)'. Nothing is switched on, so no recipient exists."
            )
        }
    }

    // MARK: - Property 3: the provider is named only when it is called

    func test_onlyProviderFreeFeaturesOn_doesNotNameTheProvider() {
        let text = copy(.init(chatGPTCommandBar: true, instantLinks: true))

        XCTAssertFalse(
            AssistPrivacyDisclosure.namesProvider(text, host: host),
            """
            The disclosure named the provider '\(host)' when the only features \
            switched on were ChatGPT in the Command Bar and Instant Links, \
            neither of which ever calls it. Got: \(text)
            """
        )
        XCTAssertTrue(text.contains("chatgpt.com"), "ChatGPT in the Command Bar must name where it sends the query.")
        XCTAssertTrue(text.contains("search engine"), "Instant Links must name where it sends the query.")
    }

    func test_aProviderCallingFeatureOn_namesTheProviderHost() {
        let text = copy(.init(askOnPage: true))

        XCTAssertTrue(
            AssistPrivacyDisclosure.namesProvider(text, host: host),
            "Ask on Page calls the provider, so the disclosure must name it. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains(String(budget)),
            "Ask on Page's disclosure must state the real character budget it sends, not a vague quantity."
        )
    }

    // MARK: - Property 4: two recipients means two disclosures

    func test_fiveSecondPreviews_disclosesBothTheProviderAndTheHoveredSite() {
        let text = copy(.init(fiveSecondPreviews: true))

        XCTAssertTrue(
            AssistPrivacyDisclosure.namesProvider(text, host: host),
            "5-Second Previews sends page text to the provider and must say so. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains("the site itself"),
            """
            5-Second Previews fetches the hovered page directly from that site, \
            which is a recipient the user never clicked through to. The \
            disclosure must say so. Got: \(text)
            """
        )
    }

    // MARK: - Property 2: no feature that is off is ever described

    func test_noSwitchedOffFeatureIsEverDescribed() {
        let cases: [(name: String, switches: AssistPrivacyDisclosure.Switches, marker: String)] = [
            ("Ask on Page", .init(askOnPage: true), "Ask on Page"),
            ("5-Second Previews", .init(fiveSecondPreviews: true), "5-Second Previews"),
            ("Tidy Tabs", .init(tidyTabs: true), "Tidy Tabs"),
            ("Tidy Tab Titles", .init(tidyTabTitles: true), "Tidy Tab Titles"),
            ("Tidy Downloads", .init(tidyDownloads: true), "Tidy Downloads"),
            ("ChatGPT in the Command Bar", .init(chatGPTCommandBar: true), "ChatGPT in the Command Bar"),
            ("Instant Links", .init(instantLinks: true), "Instant Links"),
        ]

        for subject in cases {
            let text = copy(subject.switches)
            XCTAssertTrue(
                text.contains(subject.marker),
                "\(subject.name) is switched on but is not described in the disclosure."
            )
            for other in cases where other.name != subject.name {
                XCTAssertFalse(
                    text.contains(other.marker),
                    """
                    Only \(subject.name) is switched on, but the disclosure also \
                    described \(other.name). A disclosure that describes a feature \
                    that is off is telling the user data leaves the machine when it \
                    does not. Got: \(text)
                    """
                )
            }
        }
    }

    // MARK: - The incognito assurance is unconditional

    func test_incognitoAssuranceAppearsWheneverAnyFeatureIsOn() {
        for mask in 1..<128 {
            let switches = Self.switches(forMask: mask)
            XCTAssertTrue(
                copy(switches).contains(AssistPrivacyDisclosure.incognitoAssurance),
                "Combination \(mask) dropped the incognito assurance. It is unconditional in the code and must be unconditional in the copy."
            )
        }
    }

    // MARK: - The switches agree with themselves

    func test_callsProviderAndCallsThirdParty_classifyEveryFeatureConsistentlyWithTheCopy() {
        for mask in 0..<128 {
            let switches = Self.switches(forMask: mask)
            XCTAssertEqual(
                AssistPrivacyDisclosure.namesProvider(copy(switches), host: host),
                switches.callsProvider,
                "Combination \(mask): `callsProvider` and the copy disagree about whether the provider is contacted."
            )
        }
    }

    // MARK: - Every combination

    private static func switches(forMask mask: Int) -> AssistPrivacyDisclosure.Switches {
        AssistPrivacyDisclosure.Switches(
            askOnPage: mask & 1 != 0,
            fiveSecondPreviews: mask & 2 != 0,
            tidyTabs: mask & 64 != 0,
            tidyTabTitles: mask & 4 != 0,
            tidyDownloads: mask & 8 != 0,
            chatGPTCommandBar: mask & 16 != 0,
            instantLinks: mask & 32 != 0
        )
    }

    // MARK: - Tidy Tabs says exactly what Arc's own privacy policy listed

    func test_tidyTabs_disclosesTitlesAndAddressesOnlyAndNamesTheProvider() {
        let text = copy(.init(tidyTabs: true))

        XCTAssertTrue(text.contains("Tidy Tabs sends the title and address"), "Got: \(text)")
        XCTAssertTrue(
            AssistPrivacyDisclosure.namesProvider(text, host: host),
            "Tidy Tabs sends tab titles and addresses to the provider and must name it. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains("Not the pages themselves"),
            """
            Arc's policy row lists tab titles and URLs and nothing else, and \
            page content is the thing a user would most reasonably fear was \
            included. The disclosure must rule it out explicitly. Got: \(text)
            """
        )
    }
}
