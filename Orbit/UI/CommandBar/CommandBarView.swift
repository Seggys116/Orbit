//  The Command Bar (spec §3): a floating, frosted panel presented/dismissed
//  with a spring, with a single unified, ranked, fuzzy-matched result list.

import AppKit
import SwiftUI

struct CommandBarView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var query: String = ""
    @State private var results: [CommandResult] = []
    @State private var selectedIndex: Int = 0
    @State private var suggestions: [String] = []
    @State private var suggestionsTask: Task<Void, Never>?
    @State private var historySearchTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    @State private var focusClaim: Task<Void, Never>?

    @State private var lastPointerLocation: CGPoint?

    // serial makes this a request, not a value: two arrow presses landing on the same row (wrap-around) must still scroll, which an .onChange keyed on the id alone would drop.
    @State private var scrollRequest = RowScrollRequest(id: nil, serial: 0)

    struct RowScrollRequest: Equatable {
        var id: String?
        var serial: Int
    }

    // A monotonic token, not `text == query`: that comparison can't tell two live refreshes of the same text apart (type "a", delete it, type "a" again) and reads @State from inside an escaping closure.
    @State private var generation = QueryGeneration()

    #if DEBUG
    nonisolated(unsafe) static var testResultsObserver: ((String, [CommandResult]) -> Void)?
    #endif

    private func publish(_ newResults: [CommandResult], for text: String) {
        results = newResults
        #if DEBUG
        Self.testResultsObserver?(text, newResults)
        #endif
    }

    final class QueryGeneration {
        private var current = 0

        func begin() -> Int {
            current += 1
            return current
        }

        func isCurrent(_ token: Int) -> Bool { token == current }
    }

    @State private var activeSiteEngine: SiteSearchEngine?

    struct InitialSiteSearchScope {
        var engine: SiteSearchEngine
        var query: String
    }

    var initialSiteSearchScope: InitialSiteSearchScope?

    var width: CGFloat = OrbitMetrics.commandBarWidth

    // seededFrom resolves opening state before first layout so the panel never lays out once at 52pt and then springs to full height once the first result set lands.
    init(
        width: CGFloat = OrbitMetrics.commandBarWidth,
        initialSiteSearchScope: InitialSiteSearchScope? = nil,
        seededFrom env: AppEnvironment? = nil
    ) {
        self.width = width
        self.initialSiteSearchScope = initialSiteSearchScope
        guard let env else { return }
        let opening = Self.openingState(env: env, scope: initialSiteSearchScope)
        _activeSiteEngine = State(initialValue: opening.engine)
        _query = State(initialValue: opening.query)
        _results = State(initialValue: opening.results)
    }

    private static func openingState(
        env: AppEnvironment,
        scope: InitialSiteSearchScope?
    ) -> (engine: SiteSearchEngine?, query: String, results: [CommandResult]) {
        let chatGPTAvailable = isChatGPTCommandBarAvailable(env)
        let engine = scope?.engine
            ?? (env.commandBarMode == .chatGPT && chatGPTAvailable ? ChatGPTCommandBar.virtualEngine() : nil)
        let query = scope?.query ?? env.commandBarMode.initialQuery
        let results = CommandBarEngine.results(
            query: query, mode: env.commandBarMode, env: env, suggestions: [],
            searchEngine: env.searchEngine,
            siteSearch: env.siteSearchStore.state(active: engine),
            isChatGPTCommandBarAvailable: chatGPTAvailable,
            isInstantLinksEnabled: AssistSettings.isInstantLinksEnabled
        )
        return (engine, query, results)
    }

    #if DEBUG
    // ImageRenderer cannot render a live NSTextView-backed editing session off-screen, so claimFocus() is skipped in screenshot mode.
    @Environment(\.orbitScreenshotModeDragDisabled) private var screenshotModeDragDisabled
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15))
                if let engine = activeSiteEngine {
                    siteChip(for: engine)
                }
                TextField(inputPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(OrbitFont.commandBarInput)
                    .focused($isFocused)
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.tab) {
                        if let engine = armedSiteEngine {
                            enterSiteSearch(engine)
                        } else {
                            autocomplete()
                        }
                        return .handled
                    }
                    .onKeyPress(.space) {
                        guard siteSearchState.triggerKey.acceptsSpace, let engine = armedSiteEngine else { return .ignored }
                        enterSiteSearch(engine)
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        guard let engine = activeSiteEngine, query.isEmpty else { return .ignored }
                        leaveSiteSearch(restoringShortcutOf: engine)
                        return .handled
                    }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    // Cmd/Ctrl-A: AppKit's own moveToBeginningOfParagraph: binding for Ctrl-A would park the caret and select nothing, so this field diverges deliberately.
                    .onKeyPress(keys: ["a"]) { keyPress in
                        guard keyPress.modifiers.contains(.control) || keyPress.modifiers.contains(.command) else { return .ignored }
                        selectAllQueryText()
                        return .handled
                    }
                    // General onKeyPress form, not .onKeyPress(.return): onSubmit exposes no .modifiers, and Shift+Enter (Instant Links) needs it.
                    .onKeyPress { keyPress in
                        guard keyPress.key == .return else { return .ignored }
                        commit(instant: keyPress.modifiers.contains(.shift))
                        return .handled
                    }
                if let engine = armedSiteEngine {
                    siteShortcutHint(for: engine)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            if !results.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(OrbitMetrics.commandBarSeparatorOpacity))
                    .frame(height: OrbitMetrics.commandBarSeparatorHeight)
                    .padding(.horizontal, OrbitMetrics.commandBarSeparatorInset)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                CommandResultRow(
                                    result: result,
                                    isSelected: index == selectedIndex,
                                    siteTint: activeSiteEngine.map(siteTint(for:))
                                )
                                    // Not .id(index): position is not a stable identity in a list rebuilt every keystroke, and SwiftUI could reuse a stale view.
                                    .id(result.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { activate(result) }
                                    .onContinuousHover(coordinateSpace: .global) { pointerHover($0, over: index) }
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: OrbitMetrics.commandBarMaxHeight)
                    // Keyed off scrollRequest, not selectedIndex: watching selectedIndex made hovering also scroll, which fed back into the hover handler in a loop.
                    .onChange(of: scrollRequest) { _, request in
                        guard let id = request.id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OrbitMetrics.commandBarCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: OrbitMetrics.commandBarCornerRadius).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 14)
        .onAppear(perform: setupInitialState)
        // Re-presenting over an already-open bar (e.g. Cmd+L while a Cmd+T bar is up) never fires .onAppear again, so the serial forces a re-seed.
        .onChange(of: env.commandBarPresentationSerial) { _, _ in setupInitialState() }
        .onChange(of: query) { _, newValue in refreshResults(for: newValue) }
        .onDisappear {
            focusClaim?.cancel()
            focusClaim = nil
        }
    }

    // MARK: - Site Search

    private var siteSearchState: SiteSearchState {
        env.siteSearchStore.state(active: activeSiteEngine)
    }

    // A user's own configured shortcut is checked first: armedChatGPTEngine only runs when no real engine claimed the typed text, so a user shortcut spelled "gpt" keeps working.
    private var armedSiteEngine: SiteSearchEngine? {
        siteSearchState.armedEngine(forTypedQuery: query) ?? armedChatGPTEngine
    }

    private var armedChatGPTEngine: SiteSearchEngine? {
        guard activeSiteEngine == nil, isChatGPTCommandBarAvailable, ChatGPTCommandBar.isShortcut(query) else { return nil }
        return ChatGPTCommandBar.virtualEngine()
    }

    private var isChatGPTCommandBarAvailable: Bool {
        Self.isChatGPTCommandBarAvailable(env)
    }

    private static func isChatGPTCommandBarAvailable(_ env: AppEnvironment) -> Bool {
        guard let space = env.activeSpace else { return false }
        return ChatGPTCommandBar.isAvailable(featureEnabled: AssistSettings.isChatGPTCommandBarEnabled, isIncognito: env.isIncognito(space))
    }

    private var inputPlaceholder: String {
        guard let activeSiteEngine else { return "Search or enter address" }
        return activeSiteEngine.id == ChatGPTCommandBar.virtualEngineID ? "Send a Message..." : "Search..."
    }

    private func siteTint(for engine: SiteSearchEngine) -> CommandRowTint {
        if engine.id == ChatGPTCommandBar.virtualEngineID {
            return ChatGPTChrome.chipTint
        }
        return SiteSearchTintResolver.tint(forHost: engine.host ?? engine.name.lowercased())
    }

    private func siteChip(for engine: SiteSearchEngine) -> some View {
        let tint = siteTint(for: engine)
        return Text(engine.name)
            .font(.system(size: SiteSearchChrome.chipFontSize, weight: .semibold))
            .foregroundStyle(tint.foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, SiteSearchChrome.chipHorizontalPadding)
            .frame(height: SiteSearchChrome.chipHeight)
            .background(tint.fill, in: Capsule())
    }

    private func siteShortcutHint(for engine: SiteSearchEngine) -> some View {
        let verb = engine.id == ChatGPTCommandBar.virtualEngineID ? "Ask" : "Search"
        return HStack(spacing: 6) {
            Text("\(verb) \(engine.name)")
                .font(.system(size: SiteSearchChrome.hintFontSize))
                .foregroundStyle(.secondary)
            Text(siteSearchState.triggerKey.hintKeyCapLabel)
                .font(.system(size: SiteSearchChrome.hintKeyCapFontSize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, SiteSearchChrome.hintKeyCapHorizontalPadding)
                .padding(.vertical, SiteSearchChrome.hintKeyCapVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: SiteSearchChrome.hintKeyCapCornerRadius)
                        .fill(Color.secondary.opacity(SiteSearchChrome.hintKeyCapFillOpacity))
                )
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func enterSiteSearch(_ engine: SiteSearchEngine) {
        activeSiteEngine = engine
        query = ""
        suggestions = []
        refreshResults(for: "", fetchSuggestions: false)
    }

    private func leaveSiteSearch(restoringShortcutOf engine: SiteSearchEngine) {
        activeSiteEngine = nil
        suggestions = []
        query = engine.shortcut
        refreshResults(for: engine.shortcut, fetchSuggestions: false)
    }

    private func setupInitialState() {
        SiteSearchSettingsPresenter.present = { SiteSearchSettingsWindowController.show() }
        activeSiteEngine = initialSiteSearchScope?.engine
            ?? (env.commandBarMode == .chatGPT && isChatGPTCommandBarAvailable ? ChatGPTCommandBar.virtualEngine() : nil)
        query = initialSiteSearchScope?.query ?? env.commandBarMode.initialQuery
        #if DEBUG
        if !screenshotModeDragDisabled {
            claimFocus()
        }
        #else
        claimFocus()
        #endif
        // Disables animation only for this seeding call, so the panel never lays out once at 52pt and springs to full height under BrowserWindowView's ambient animation.
        var seeding = Transaction()
        seeding.disablesAnimations = true
        withTransaction(seeding) {
            refreshResults(for: query, fetchSuggestions: false)
        }
    }

    private func refreshResults(for text: String, fetchSuggestions: Bool = true) {
        let token = generation.begin()
        let siteSearch = siteSearchState
        let chatGPTAvailable = isChatGPTCommandBarAvailable
        let instantLinksEnabled = AssistSettings.isInstantLinksEnabled
        publish(CommandBarEngine.results(
            query: text, mode: env.commandBarMode, env: env, suggestions: suggestions,
            searchEngine: env.searchEngine, siteSearch: siteSearch,
            isChatGPTCommandBarAvailable: chatGPTAvailable, isInstantLinksEnabled: instantLinksEnabled
        ), for: text)
        selectedIndex = 0
        // The two async passes below deliberately do not raise a scroll request: they only widen a list the user may already be arrowing through.
        requestScroll(to: 0)

        historySearchTask?.cancel()
        historySearchTask = Task {
            await env.prepareHistorySearch(for: text)
            guard !Task.isCancelled, generation.isCurrent(token) else { return }
            publish(CommandBarEngine.results(
                query: text, mode: env.commandBarMode, env: env, suggestions: suggestions,
                searchEngine: env.searchEngine, siteSearch: siteSearch,
                isChatGPTCommandBarAvailable: chatGPTAvailable, isInstantLinksEnabled: instantLinksEnabled
            ), for: text)
        }

        guard fetchSuggestions, env.includesSearchSuggestions else { return }
        suggestionsTask?.cancel()
        let engine = env.searchEngine
        suggestionsTask = Task {
            let fetched = await SearchSuggestionsClient.shared.suggestions(for: text, engine: engine)
            guard !Task.isCancelled, generation.isCurrent(token) else { return }
            suggestions = fetched
            publish(CommandBarEngine.results(
                query: text, mode: env.commandBarMode, env: env, suggestions: fetched,
                searchEngine: engine, siteSearch: siteSearch,
                isChatGPTCommandBarAvailable: chatGPTAvailable, isInstantLinksEnabled: instantLinksEnabled
            ), for: text)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = ((selectedIndex + delta) % results.count + results.count) % results.count
        requestScroll(to: selectedIndex)
    }

    private func requestScroll(to index: Int) {
        let id = results.indices.contains(index) ? results[index].id : nil
        scrollRequest = RowScrollRequest(id: id, serial: scrollRequest.serial &+ 1)
    }

    // .onContinuousHover, not .onHover: a plain .onHover reports every row that passes beneath a stationary pointer during wheel scroll as hovered, racing the highlight down the list.
    private func pointerHover(_ phase: HoverPhase, over index: Int) {
        guard case .active(let location) = phase else { return }
        defer { lastPointerLocation = location }
        guard Self.pointerDidMove(from: lastPointerLocation, to: location) else { return }
        selectedIndex = index
    }

    static func pointerDidMove(from previous: CGPoint?, to location: CGPoint) -> Bool {
        guard let previous else { return false }
        return location != previous
    }

    private func selectAllQueryText() {
        CommandBarFieldFocus.selectAll()
    }

    private func claimFocus() {
        focusClaim?.cancel()
        focusClaim = Task { @MainActor in
            await CommandBarFieldFocus.claim(
                showing: { query },
                isFocused: { isFocused },
                requestFocus: { isFocused = true }
            )
        }
    }

    private func autocomplete() {
        guard let first = results.first else { return }
        switch first.kind {
        case .typedURL(let url): query = url.absoluteString
        case .searchSuggestion(let text): query = text
        case .history(let entry): query = entry.url.absoluteString
        case .favorite(let favorite): query = favorite.url.absoluteString
        case .openTab(let tabID), .pinnedTab(let tabID):
            if let url = env.tab(tabID)?.url { query = url.absoluteString }
        case .action:
            break
        case .siteSearch:
            break
        case .chatGPTAsk:
            break
        }
    }

    private func commit(instant: Bool) {
        if selectedIndex < results.count {
            activate(results[selectedIndex], instant: instant)
            return
        }
        commitTypedTextDirectly()
    }

    // Same three rules, same order, as CommandBarEngine.results' row 1, so this backstop can never disagree with the list about where a query goes.
    private func commitTypedTextDirectly() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let spaceID = env.activeSpace?.id else { return }
        let destination: URL?
        if let engine = activeSiteEngine {
            destination = SiteSearchMatcher.searchURL(for: trimmed, using: engine)
        } else {
            destination = CommandBarEngine.detectTypedURL(trimmed) ?? env.searchEngine.searchURL(for: trimmed)
        }
        guard let destination else { return }
        navigate(to: destination, spaceID: spaceID)
        dismiss()
    }

    private func activate(_ result: CommandResult, instant: Bool = false) {
        guard let spaceID = env.activeSpace?.id else { return }
        if instant, let instantURL = result.instantOpenURL {
            navigate(to: instantURL, spaceID: spaceID)
            dismiss()
            return
        }
        switch result.kind.activationIntent {
        case .navigate(let url):
            navigate(to: url, spaceID: spaceID)
        case .searchGoogle(let text):
            guard let url = env.searchEngine.searchURL(for: text) else { break }
            navigate(to: url, spaceID: spaceID)
        case .switchToTab(let tabID):
            env.activateTab(tabID)
        case .activateFavoriteResult(let favorite):
            env.activateFavorite(favorite, in: spaceID)
        case .runAction:
            if case .action(let action) = result.kind {
                action.perform(env)
            }
        }
        dismiss()
    }

    private func navigate(to url: URL, spaceID: SpaceID) {
        switch env.commandBarMode {
        case .newTab, .chatGPT:
            env.openTab(url: url, in: spaceID)
        case .blankPane(let tabID):
            // Falls back to a new tab only if the pane went away underneath the bar while it was open.
            if env.tab(tabID) != nil {
                env.loadInTab(tabID, url: url)
                env.activateTab(tabID)
            } else {
                env.openTab(url: url, in: spaceID)
            }
        case .editURL:
            if let tabID = env.activeTabID {
                // loadInTab, not the tab's live WebContents directly: a tab still waiting on content blocking's readiness gate has a deferred load queued, and only loadInTab's bookkeeping lets it notice this one superseded it.
                env.loadInTab(tabID, url: url)
                env.activateTab(tabID)
            } else {
                env.openTab(url: url, in: spaceID)
            }
        }
    }

    private func dismiss() {
        suggestionsTask?.cancel()
        historySearchTask?.cancel()
        env.dismissCommandBar()
    }
}

private enum SiteSearchChrome {
    static let chipHeight: CGFloat = 22
    static let chipHorizontalPadding: CGFloat = 10
    static let chipFontSize: CGFloat = OrbitMetrics.commandBarInputFontSize * 0.75

    static let hintFontSize: CGFloat = 11.5
    static let hintKeyCapFontSize: CGFloat = 10.5
    static let hintKeyCapHorizontalPadding: CGFloat = 5
    static let hintKeyCapVerticalPadding: CGFloat = 2
    static let hintKeyCapCornerRadius: CGFloat = 4
    static let hintKeyCapFillOpacity: Double = 0.15
}

private enum ChatGPTChrome {
    static let chipTint = CommandRowTint(
        fill: Color(red: 0.14, green: 0.47, blue: 0.38),
        foreground: .white
    )
}
