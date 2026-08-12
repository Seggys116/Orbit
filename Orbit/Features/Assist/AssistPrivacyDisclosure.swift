//  Foundation only, no AppEnvironment — symlinked into OrbitTests/ReusedAssistSources/.

import Foundation

enum AssistPrivacyDisclosure {

    struct Switches: Equatable, Sendable {
        var askOnPage: Bool = false
        var fiveSecondPreviews: Bool = false
        var tidyTabs: Bool = false
        var tidyTabTitles: Bool = false
        var tidyDownloads: Bool = false
        var chatGPTCommandBar: Bool = false
        var instantLinks: Bool = false

        var isAllOff: Bool {
            !askOnPage && !fiveSecondPreviews && !tidyTabs && !tidyTabTitles
                && !tidyDownloads && !chatGPTCommandBar && !instantLinks
        }

        var callsProvider: Bool {
            askOnPage || fiveSecondPreviews || tidyTabs || tidyTabTitles || tidyDownloads
        }

        /// fiveSecondPreviews belongs in both lists: it fetches the hovered page directly, then also sends it to the provider.
        var callsThirdParty: Bool {
            fiveSecondPreviews || chatGPTCommandBar || instantLinks
        }
    }

    static func copy(for switches: Switches, providerHost: String, pageCharacterBudget: Int) -> String {
        guard !switches.isAllOff else {
            return "Nothing. Every feature above is switched off, so Orbit makes no requests."
        }

        var providerLines: [String] = []
        var thirdPartyLines: [String] = []

        if switches.askOnPage {
            providerLines.append("Ask on Page sends the page's title, its address and up to \(pageCharacterBudget) characters of its visible text, plus your question.")
        }
        if switches.fiveSecondPreviews {
            providerLines.append("5-Second Previews sends the hovered page's title, its address and up to \(pageCharacterBudget) characters of its text.")
            thirdPartyLines.append("5-Second Previews also requests the hovered page from the site itself, before any of that. That site sees a visit you did not click on.")
        }
        if switches.tidyTabs {
            providerLines.append("Tidy Tabs sends the title and address of every Today tab in the Space you are looking at, each time you press the broom. Not the pages themselves, and nothing from any other Space.")
        }
        if switches.tidyTabTitles {
            providerLines.append("Tidy Tab Titles sends a tab's page title and address each time the title changes. Not the page body.")
        }
        if switches.tidyDownloads {
            providerLines.append("Tidy Downloads sends a finished download's file name, the address it came from and the title of the page it was started on. Never the file itself.")
        }
        if switches.chatGPTCommandBar {
            thirdPartyLines.append("ChatGPT in the Command Bar opens chatgpt.com with what you typed in the address. It calls no provider, and nothing is answered inside Orbit.")
        }
        if switches.instantLinks {
            thirdPartyLines.append("Instant Links sends your query to your search engine's own first-result address — the same engine an ordinary search already uses, and no other party.")
        }

        var sections: [String] = []
        if !providerLines.isEmpty {
            sections.append(contentsOf: providerLines)
            sections.append("That goes to \(providerHost), the provider you configured above, and to no one else. Orbit has no account and no server of its own.")
        }
        sections.append(contentsOf: thirdPartyLines)
        sections.append(incognitoAssurance)
        return sections.joined(separator: "\n\n")
    }

    static let incognitoAssurance = "Nothing is ever sent from an incognito window, whatever these switches say."

    static func namesProvider(_ copy: String, host: String) -> Bool {
        copy.contains("That goes to \(host), the provider you configured above")
    }
}
