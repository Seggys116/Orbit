import SwiftUI

struct AssistSettingsPane: View {
    @Environment(AppEnvironment.self) private var env

    @State private var assistEnabled = AssistSettings.isEnabled

    @State private var providerKind = AssistSettings.providerKind
    @State private var baseURL = AssistSettings.baseURLString
    @State private var model = AssistSettings.model
    @State private var apiKey = AssistSettings.apiKey

    @State private var askOnPage = AssistSettings.storedFlag(AssistSettings.askOnPageEnabledKey)
    @State private var tidyTabs = AssistSettings.storedFlag(AssistSettings.tidyTabsEnabledKey)
    @State private var tidyTabTitles = AssistSettings.storedFlag(AssistSettings.tidyTabTitlesEnabledKey)
    @State private var tidyDownloads = AssistSettings.storedFlag(AssistSettings.tidyDownloadsEnabledKey)

    @State private var fiveSecondPreviews = AssistSettings.storedFlag(AssistSettings.fiveSecondPreviewsEnabledKey)
    @State private var chatGPTCommandBar = AssistSettings.storedFlag(AssistSettings.chatGPTCommandBarEnabledKey)
    @State private var instantLinks = AssistSettings.storedFlag(AssistSettings.instantLinksEnabledKey)

    @State private var connectionResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionStackSpacing) {
            Text("Assist").font(.system(size: 20, weight: .bold))

            OrbitSettingsSection(title: nil) {
                OrbitSettingsRow(
                    title: "Assist",
                    description: "Orbit's AI-assisted features, off until you turn them on. With this switch off nothing below runs and Orbit makes no AI request of any kind, whatever the individual switches say."
                ) {
                    OrbitToggle(accessibilityLabel: "Assist", isOn: $assistEnabled, accentColor: SettingsPalette.accent)
                }
                .onChange(of: assistEnabled) { _, newValue in
                    AssistSettings.isEnabled = newValue
                    if !newValue { stopEverything() }
                    syncProviderFlag()
                }

                OrbitSettingsActionRow {
                    OrbitButton(title: "Turn On All", kind: .primary, accentColor: SettingsPalette.accent) { turnOnAll() }
                }
                .disabled(!assistEnabled)
                .opacity(assistEnabled ? 1 : Self.disabledOpacity)
            }

            Text("Orbit ships no model and has no server, so every switch that calls one stays inert until you point it at a provider you control — Anthropic, any OpenAI-compatible service, or something running on your own machine. Nothing here ever invents a result: when a request cannot be made, Orbit says so rather than showing something plausible.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            OrbitSettingsSection(title: "Provider") {
                OrbitSettingsRow(
                    title: "Provider",
                    description: "Anthropic speaks the Messages API. Everything else — OpenAI, OpenRouter, Groq, together.ai, Ollama, LM Studio — speaks the OpenAI chat-completions API. Each provider keeps its own key."
                ) {
                    OrbitPopupButton(
                        options: AssistProviderKind.allCases,
                        label: { $0.displayName },
                        selection: $providerKind,
                        accessibilityLabel: "Provider",
                        accentColor: SettingsPalette.accent
                    )
                }
                .onChange(of: providerKind) { _, newValue in
                    AssistSettings.providerKind = newValue
                    apiKey = AssistSettings.apiKey
                    connectionResult = nil
                    syncProviderFlag()
                }

                OrbitSettingsRow(
                    title: "Base URL",
                    description: providerKind.baseURLDescription
                ) {
                    OrbitTextField(
                        placeholder: providerKind.baseURLPlaceholder,
                        text: $baseURL,
                        accentColor: SettingsPalette.accent,
                        accessibilityLabel: "Provider base URL"
                    )
                    .frame(width: SettingsMetrics.fieldColumnWidth, alignment: .leading)
                }
                .onChange(of: baseURL) { _, newValue in
                    AssistSettings.baseURLString = newValue
                    syncProviderFlag()
                }

                OrbitSettingsValueRow(title: "Requests go to") {
                    Text(resolvedEndpointDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(width: SettingsMetrics.fieldColumnWidth, alignment: .leading)
                }

                OrbitSettingsRow(title: "Model") {
                    OrbitTextField(
                        placeholder: providerKind.modelPlaceholder,
                        text: $model,
                        accentColor: SettingsPalette.accent,
                        accessibilityLabel: "Model identifier"
                    )
                    .frame(width: SettingsMetrics.fieldColumnWidth, alignment: .leading)
                }
                .onChange(of: model) { _, newValue in
                    AssistSettings.model = newValue
                    syncProviderFlag()
                }

                OrbitSettingsRow(
                    title: "API key",
                    description: "Stored in your login Keychain, never in Orbit's preferences or its saved state. Not needed for a local server."
                ) {
                    OrbitSecureField(
                        placeholder: providerKind.apiKeyPlaceholder,
                        text: $apiKey,
                        accentColor: SettingsPalette.accent,
                        accessibilityLabel: "Provider API key"
                    )
                    .frame(width: SettingsMetrics.fieldColumnWidth, alignment: .leading)
                }
                .onChange(of: apiKey) { _, newValue in
                    AssistSettings.apiKey = newValue
                    syncProviderFlag()
                }

                OrbitSettingsActionRow {
                    HStack(spacing: 10) {
                        if let connectionResult {
                            Text(connectionResult)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        OrbitButton(title: isTesting ? "Testing…" : "Test Provider", kind: .secondary, accentColor: SettingsPalette.accent) {
                            testProvider()
                        }
                        // A test is a real request, so it stays unavailable while Assist is off.
                        .disabled(!assistEnabled)
                        .opacity(assistEnabled ? 1 : Self.disabledOpacity)
                    }
                }
            }

            OrbitSettingsSection(title: "Features") {
                OrbitSettingsRow(
                    title: "Tidy Tabs",
                    description: "Press the broom icon to let your Sidebar organize itself whenever you have more than six Today Tabs. With this off the broom still works, grouping those tabs by site instead — nothing is sent anywhere."
                ) {
                    OrbitToggle(accessibilityLabel: "Tidy Tabs", isOn: $tidyTabs, accentColor: SettingsPalette.accent)
                }
                .onChange(of: tidyTabs) { _, newValue in
                    AssistSettings.isTidyTabsEnabled = newValue
                    if !newValue {
                        TidyTabsCoordinator.shared.reset()
                    }
                    syncProviderFlag()
                }

                OrbitSettingsRow(
                    title: "Instant Links",
                    description: "Press Shift + Enter for any web search to instantly open the top result. Only offered on search engines that publish a way to do this — today that is DuckDuckGo."
                ) {
                    OrbitToggle(accessibilityLabel: "Instant Links", isOn: $instantLinks, accentColor: SettingsPalette.accent)
                }
                .onChange(of: instantLinks) { _, newValue in
                    AssistSettings.isInstantLinksEnabled = newValue
                }

                OrbitSettingsRow(
                    title: "Ask on Page",
                    description: "Press Command + F on any page to ask a question and get an answer in seconds."
                ) {
                    OrbitToggle(accessibilityLabel: "Ask on Page", isOn: $askOnPage, accentColor: SettingsPalette.accent)
                }
                .onChange(of: askOnPage) { _, newValue in
                    AssistSettings.isAskOnPageEnabled = newValue
                    syncProviderFlag()
                }

                OrbitSettingsRow(
                    title: "5-Second Previews",
                    description: "Press Shift and hover over any link to generate a summary of the webpage, without a single click. Orbit fetches the linked page itself to do this, so that site sees a visit."
                ) {
                    OrbitToggle(accessibilityLabel: "5-Second Previews", isOn: $fiveSecondPreviews, accentColor: SettingsPalette.accent)
                }
                .onChange(of: fiveSecondPreviews) { _, newValue in
                    AssistSettings.isFiveSecondPreviewsEnabled = newValue
                    syncProviderFlag()
                }

                OrbitSettingsRow(
                    title: "Tidy Tab Titles",
                    description: "Have your tabs automatically renamed with tidier, shorter titles when you Pin them. Renaming a tab yourself always wins, and switching this off restores the real titles."
                ) {
                    OrbitToggle(accessibilityLabel: "Tidy Tab Titles", isOn: $tidyTabTitles, accentColor: SettingsPalette.accent)
                }
                .onChange(of: tidyTabTitles) { _, newValue in
                    AssistSettings.isTidyTabTitlesEnabled = newValue
                    if !newValue {
                        env.store.clearAllTidiedTitles()
                        TidyTabTitlesCoordinator.shared.reset()
                    }
                    syncProviderFlag()
                }

                OrbitSettingsRow(
                    title: "Tidy Downloads",
                    description: "Keep your many files more organized with smartly renamed downloads — and make them a little easier to find later."
                ) {
                    OrbitToggle(accessibilityLabel: "Tidy Downloads", isOn: $tidyDownloads, accentColor: SettingsPalette.accent)
                }
                .onChange(of: tidyDownloads) { _, newValue in
                    AssistSettings.isTidyDownloadsEnabled = newValue
                    if !newValue { TidyDownloadsCoordinator.shared.reset() }
                    syncProviderFlag()
                }

                OrbitSettingsRow(
                    title: "ChatGPT in the Command Bar",
                    description: "Press ⌥⌘G, start typing, and get answers in fewer clicks. Orbit opens your question in ChatGPT rather than answering it here, so this one needs no provider above."
                ) {
                    OrbitToggle(accessibilityLabel: "ChatGPT in the Command Bar", isOn: $chatGPTCommandBar, accentColor: SettingsPalette.accent)
                }
                .onChange(of: chatGPTCommandBar) { _, newValue in
                    AssistSettings.isChatGPTCommandBarEnabled = newValue
                }
            }
            .disabled(!assistEnabled)
            .opacity(assistEnabled ? 1 : Self.disabledOpacity)

            OrbitSettingsSection(title: "What Leaves This Machine") {
                Text(privacyCopy)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { reload() }
    }

    static let disabledOpacity: Double = 0.45

    private func reload() {
        assistEnabled = AssistSettings.isEnabled
        providerKind = AssistSettings.providerKind
        baseURL = AssistSettings.baseURLString
        model = AssistSettings.model
        apiKey = AssistSettings.apiKey
        askOnPage = AssistSettings.storedFlag(AssistSettings.askOnPageEnabledKey)
        tidyTabs = AssistSettings.storedFlag(AssistSettings.tidyTabsEnabledKey)
        tidyTabTitles = AssistSettings.storedFlag(AssistSettings.tidyTabTitlesEnabledKey)
        tidyDownloads = AssistSettings.storedFlag(AssistSettings.tidyDownloadsEnabledKey)
        fiveSecondPreviews = AssistSettings.storedFlag(AssistSettings.fiveSecondPreviewsEnabledKey)
        chatGPTCommandBar = AssistSettings.storedFlag(AssistSettings.chatGPTCommandBarEnabledKey)
        instantLinks = AssistSettings.storedFlag(AssistSettings.instantLinksEnabledKey)
    }

    private var resolvedEndpointDescription: String {
        AssistProviderKind.requestURL(kind: providerKind, baseURLString: baseURL)?.absoluteString
            ?? "Not a usable http or https address."
    }

    private func turnOnAll() {
        askOnPage = true
        tidyTabs = true
        tidyTabTitles = true
        tidyDownloads = true
        fiveSecondPreviews = true
        chatGPTCommandBar = true
        instantLinks = true
        AssistSettings.isAskOnPageEnabled = true
        AssistSettings.isTidyTabsEnabled = true
        AssistSettings.isTidyTabTitlesEnabled = true
        AssistSettings.isTidyDownloadsEnabled = true
        AssistSettings.isFiveSecondPreviewsEnabled = true
        AssistSettings.isChatGPTCommandBarEnabled = true
        AssistSettings.isInstantLinksEnabled = true
        syncProviderFlag()
    }

    /// Switching Assist off has to stand down the running coordinators too, not just stop the next request.
    private func stopEverything() {
        TidyTabsCoordinator.shared.reset()
        TidyTabTitlesCoordinator.shared.reset()
        TidyDownloadsCoordinator.shared.reset()
        env.store.clearAllTidiedTitles()
        connectionResult = nil
    }

    private var privacyCopy: String {
        AssistPrivacyDisclosure.copy(
            for: AssistPrivacyDisclosure.Switches(
                askOnPage: assistEnabled && askOnPage,
                fiveSecondPreviews: assistEnabled && fiveSecondPreviews,
                tidyTabs: assistEnabled && tidyTabs,
                tidyTabTitles: assistEnabled && tidyTabTitles,
                tidyDownloads: assistEnabled && tidyDownloads,
                chatGPTCommandBar: assistEnabled && chatGPTCommandBar,
                instantLinks: assistEnabled && instantLinks
            ),
            providerHost: AssistSettings.providerConfig.destinationDescription,
            pageCharacterBudget: PageTextExtractor.characterBudget
        )
    }

    private func syncProviderFlag() {
        env.hasConfiguredAIProvider = AssistSettings.isAnyFeatureLive
    }

    private func testProvider() {
        guard AssistSettings.isEnabled else {
            connectionResult = AssistError.assistDisabled.localizedDescription
            return
        }
        guard let sink = AssistRuntime.providerOnlySink() else {
            connectionResult = AssistError.notConfigured.localizedDescription
            return
        }
        isTesting = true
        connectionResult = nil
        Task {
            do {
                let reply = try await sink.generate(
                    AssistRequest(system: "Reply with the single word: ready.", user: "ready?", maxOutputTokens: 8)
                )
                connectionResult = "Answered: \(reply.prefix(60))"
            } catch {
                connectionResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}
