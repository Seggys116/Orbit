import XCTest

final class OnboardingCommitTests: XCTestCase {

    private func documentWithOneProfile() -> (OrbitState, Profile) {
        let profile = Profile(name: "Personal")
        var state = OrbitState()
        state.profiles = [profile]
        state.spaces = [Space(name: "Personal", profileID: profile.id)]
        return (state, profile)
    }

    // MARK: - Search engine

    func test_choosingAnEngine_writesItOntoTheNamedProfile() {
        var (state, profile) = documentWithOneProfile()
        XCTAssertEqual(state.profiles[0].searchEngine, .google, "precondition: a fresh Profile starts on the fallback")

        let written = OnboardingCommit.applySearchEngine(.duckDuckGo, toProfile: profile.id, in: &state)

        XCTAssertEqual(written, profile.id)
        XCTAssertEqual(
            state.profiles[0].searchEngine, .duckDuckGo,
            "the onboarding choice must land on the Profile; this is the exact assertion the old @State-only picker could never satisfy"
        )
    }

    func test_theWrittenEngineIsWhatResolvesASearch() throws {
        var (state, profile) = documentWithOneProfile()
        let googleURL = try XCTUnwrap(state.profiles[0].searchEngine.searchURL(for: "orbit browser"))

        OnboardingCommit.applySearchEngine(.duckDuckGo, toProfile: profile.id, in: &state)
        let duckURL = try XCTUnwrap(state.profiles[0].searchEngine.searchURL(for: "orbit browser"))

        XCTAssertNotEqual(googleURL, duckURL)
        XCTAssertEqual(duckURL.host, "duckduckgo.com")
        XCTAssertTrue(googleURL.absoluteString.contains("google.com"))
    }

    func test_withNoRememberedProfile_theChoiceLandsOnTheFirstProfile() {
        var (state, _) = documentWithOneProfile()

        let written = OnboardingCommit.applySearchEngine(.bing, toProfile: nil, in: &state)

        XCTAssertEqual(written, state.profiles[0].id)
        XCTAssertEqual(state.profiles[0].searchEngine, .bing)
    }

    func test_withNoProfilesAtAll_reportsThatNothingWasWritten() {
        var state = OrbitState()

        let written = OnboardingCommit.applySearchEngine(.ecosia, toProfile: nil, in: &state)

        XCTAssertNil(written)
        XCTAssertTrue(state.profiles.isEmpty)
    }

    func test_onlyTheTargetProfileChanges() {
        let personal = Profile(name: "Personal")
        var work = Profile(name: "Work")
        work.searchEngine = .ecosia
        var state = OrbitState()
        state.profiles = [personal, work]

        OnboardingCommit.applySearchEngine(.bing, toProfile: personal.id, in: &state)

        XCTAssertEqual(state.profiles[0].searchEngine, .bing)
        XCTAssertEqual(state.profiles[1].searchEngine, .ecosia, "a sibling Profile's engine must not be overwritten")
    }

    func test_reCommittingOverwrites_soGoingBackAndChangingTheChoiceWins() {
        var (state, profile) = documentWithOneProfile()

        OnboardingCommit.applySearchEngine(.bing, toProfile: profile.id, in: &state)
        OnboardingCommit.applySearchEngine(.ecosia, toProfile: profile.id, in: &state)

        XCTAssertEqual(state.profiles[0].searchEngine, .ecosia, "the last visible choice must be the one that sticks")
    }

    // MARK: - Profile name

    func test_profileNameIsWrittenAndTrimmed() {
        var (state, profile) = documentWithOneProfile()

        OnboardingCommit.applyProfileName("  Work  ", toProfile: profile.id, in: &state)

        XCTAssertEqual(state.profiles[0].name, "Work")
    }

    func test_blankProfileName_isRefusedRatherThanApplied() {
        var (state, profile) = documentWithOneProfile()

        let written = OnboardingCommit.applyProfileName("   ", toProfile: profile.id, in: &state)

        XCTAssertNil(written)
        XCTAssertEqual(state.profiles[0].name, "Personal", "an empty Profile name is not a name")
    }

    // Regression guard: OnboardingView.commitProfile() used to also call env.renameSpace(...)
    // with the same string, so the Space title row read exactly like a profile switcher.
    func test_applyingAProfileName_neverTouchesAnySpace() {
        var (state, profile) = documentWithOneProfile()
        let spacesBefore = state.spaces

        OnboardingCommit.applyProfileName("Work", toProfile: profile.id, in: &state)

        XCTAssertEqual(
            state.spaces, spacesBefore,
            "naming a Profile must be invisible to every Space — a Profile is a credentials/identity boundary and a Space is a browsing context; conflating their names is what produced a Space that looked like a profile switcher in the sidebar"
        )
    }

    // MARK: - Spaces setup

    func test_defaultDrafts_isOneGenericUnemojiedSpace() {
        let defaults = OnboardingSpaceDraft.defaults

        XCTAssertEqual(defaults.count, 1, "the user asked for a single generic Space by default, not three imposed ones — see OnboardingSpaceDraft.defaults' doc comment")
        XCTAssertEqual(defaults.first?.name, "General", "the one default should read as generic, not job- or theme-specific — nothing here should presume what kind of user is setting up the browser")
        XCTAssertEqual(defaults.first?.emoji, "", "no emoji preselected — this default resolves through the real SpaceIcon.none dot fallback (see applySpacesSetup's 'Icon' note), the same 'no icon chosen' Orbit already draws everywhere else")
    }

    func test_applyingSpacesSetup_writesEachDraftAsASpaceOnTheTargetProfile() {
        var (state, profile) = documentWithOneProfile()
        let drafts = [
            OnboardingSpaceDraft(name: "Reading", emoji: "📚"),
            OnboardingSpaceDraft(name: "Travel", emoji: "✈️"),
        ]

        let created = OnboardingCommit.applySpacesSetup(drafts, profileID: profile.id, in: &state)

        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(state.spaces.count, 2)
        XCTAssertEqual(state.spaces.map(\.name), ["Reading", "Travel"])
        XCTAssertTrue(state.spaces.allSatisfy { $0.profileID == profile.id }, "every created Space must belong to the resolved Profile")
        XCTAssertEqual(state.spaces.map(\.order), [0, 1], "order must match the drafts' display order")
    }

    func test_applyingSpacesSetup_activatesTheFirstCreatedSpace() {
        var (state, profile) = documentWithOneProfile()
        let drafts = [OnboardingSpaceDraft(name: "First", emoji: "1️⃣"), OnboardingSpaceDraft(name: "Second", emoji: "2️⃣")]

        let created = OnboardingCommit.applySpacesSetup(drafts, profileID: profile.id, in: &state)

        XCTAssertEqual(state.activeSpaceID, created.first)
        XCTAssertEqual(state.activeSpaceID, state.spaces.first?.id)
    }

    func test_applyingSpacesSetup_dropsBlankNamedRowsButKeepsTheRest() {
        var (state, profile) = documentWithOneProfile()
        let drafts = [
            OnboardingSpaceDraft(name: "  ", emoji: "🚫"),
            OnboardingSpaceDraft(name: "Kept", emoji: "✅"),
        ]

        OnboardingCommit.applySpacesSetup(drafts, profileID: profile.id, in: &state)

        XCTAssertEqual(state.spaces.map(\.name), ["Kept"], "a blank name is not a name, matching applyProfileName's own rule")
    }

    func test_applyingSpacesSetup_fallsBackToDefaultsWhenEveryRowIsBlank() {
        var (state, profile) = documentWithOneProfile()

        let created = OnboardingCommit.applySpacesSetup([], profileID: profile.id, in: &state)

        XCTAssertEqual(
            created.count, OnboardingSpaceDraft.defaults.count,
            "Orbit has no 'zero Spaces' state anywhere else in the app; onboarding must not invent one just because the user emptied the editor"
        )
        XCTAssertEqual(state.spaces.map(\.name), OnboardingSpaceDraft.defaults.map(\.name))
    }

    func test_applyingSpacesSetup_replacesRatherThanAppendsToExistingSpaces() {
        var (state, profile) = documentWithOneProfile()
        XCTAssertEqual(state.spaces.count, 1, "precondition: documentWithOneProfile seeds one Space")

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "Only", emoji: "1️⃣")], profileID: profile.id, in: &state)

        XCTAssertEqual(state.spaces.map(\.name), ["Only"], "this step runs on a fresh install only; the placeholder BrowserStore.bootstrapIfNeeded() seeded must not survive alongside the user's real choice")
    }

    func test_applyingSpacesSetup_landsTheFirstSpaceOnOrbitsOwnSite() throws {
        var (state, profile) = documentWithOneProfile()

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "Only", emoji: "")], profileID: profile.id, in: &state)

        let space = try XCTUnwrap(state.spaces.first)
        let firstTabID = try XCTUnwrap(space.today.first, "the first Space must open on a tab, not empty")
        let firstTab = try XCTUnwrap(state.tabs[firstTabID], "the Today entry must resolve to a real Tab record in state.tabs")
        XCTAssertEqual(firstTab.url, BrowserStore.firstRunTabURL)
        XCTAssertEqual(firstTab.spaceID, space.id, "the seeded tab must belong to the Space that lists it")
    }

    func test_applyingSpacesSetup_seedsTheWelcomeTabOnlyInTheFirstSpace() {
        var (state, profile) = documentWithOneProfile()

        OnboardingCommit.applySpacesSetup(
            [
                OnboardingSpaceDraft(name: "First", emoji: ""),
                OnboardingSpaceDraft(name: "Second", emoji: ""),
                OnboardingSpaceDraft(name: "Third", emoji: ""),
            ],
            profileID: profile.id,
            in: &state
        )

        XCTAssertEqual(state.spaces.map(\.today.count), [1, 0, 0])
        XCTAssertEqual(state.tabs.count, 1, "exactly one tab total across the whole document")
    }

    func test_applyingSpacesSetup_leavesNoTabsOrphanedByTheReplacedSpaces() {
        var (state, profile) = documentWithOneProfile()
        let seededSpaceID = state.spaces[0].id
        let seedTab = Tab(spaceID: seededSpaceID, section: .today, url: BrowserStore.firstRunTabURL)
        state.spaces[0].today = [seedTab.id]
        state.tabs[seedTab.id] = seedTab

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "Only", emoji: "")], profileID: profile.id, in: &state)

        XCTAssertNil(state.tabs[seedTab.id], "the placeholder tab record belonging to a replaced Space must not survive as an orphan")
        let liveSpaceIDs = Set(state.spaces.map(\.id))
        for tab in state.tabs.values {
            XCTAssertTrue(liveSpaceIDs.contains(tab.spaceID), "every surviving tab must belong to a Space that still exists")
        }
    }

    // MARK: - Spaces setup must never destroy a document
    // Regression guard: applySpacesSetup used to replace state.spaces and delete their tabs unconditionally, on the unasserted premise that the step only runs on a fresh install — false on every DEBUG boot.

    func test_applyingSpacesSetup_neverDeletesATabTheUserOpened() throws {
        var (state, profile) = documentWithOneProfile()
        let existingSpaceID = state.spaces[0].id
        let userTab = Tab(spaceID: existingSpaceID, section: .today, url: URL(string: "https://example.com")!)
        state.spaces[0].today = [userTab.id]
        state.tabs[userTab.id] = userTab

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "New", emoji: "")], profileID: profile.id, in: &state)

        let survivor = try XCTUnwrap(state.tabs[userTab.id], "onboarding must not delete a page the user navigated to")
        XCTAssertEqual(survivor.url, userTab.url)
        XCTAssertTrue(
            state.spaces.contains(where: { $0.id == existingSpaceID }),
            "the Space that tab belongs to must survive too — deleting it would strand the tab even if the record itself were kept"
        )
        XCTAssertEqual(state.spaces.map(\.name), ["Personal", "New"], "the drafted Space is added alongside, not instead of")
    }

    func test_applyingSpacesSetup_neverDeletesSpacesOnADocumentWithMoreThanOne() {
        var (state, profile) = documentWithOneProfile()
        state.spaces.append(Space(name: "Work", profileID: profile.id, order: 1))

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "New", emoji: "")], profileID: profile.id, in: &state)

        XCTAssertEqual(state.spaces.map(\.name), ["Personal", "Work", "New"])
    }

    func test_applyingSpacesSetup_neverReplacesADocumentWithAnythingPinned() {
        var (state, profile) = documentWithOneProfile()
        let pinnedTab = Tab(spaceID: state.spaces[0].id, section: .pinned, url: BrowserStore.firstRunTabURL)
        state.spaces[0].pinned = [.tab(pinnedTab.id)]
        state.tabs[pinnedTab.id] = pinnedTab

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "New", emoji: "")], profileID: profile.id, in: &state)

        XCTAssertEqual(state.spaces.map(\.name), ["Personal", "New"])
        XCTAssertNotNil(state.tabs[pinnedTab.id], "a pinned tab must survive onboarding running again")
    }

    func test_applyingSpacesSetup_isIdempotentWhenReCommittedOnAUsedDocument() {
        var (state, profile) = documentWithOneProfile()
        state.spaces.append(Space(name: "Work", profileID: profile.id, order: 1))
        let drafts = [OnboardingSpaceDraft(name: "Reading", emoji: "📚")]

        let first = OnboardingCommit.applySpacesSetup(drafts, profileID: profile.id, in: &state)
        let second = OnboardingCommit.applySpacesSetup(drafts, profileID: profile.id, in: &state)

        XCTAssertEqual(first, second, "the same draft must resolve to the same Space, not create another one")
        XCTAssertEqual(state.spaces.map(\.name), ["Personal", "Work", "Reading"])
    }

    func test_applyingSpacesSetup_matchesAnExistingSpaceIgnoringCaseAndWhitespace() throws {
        var (state, profile) = documentWithOneProfile()
        state.spaces.append(Space(name: "Work", profileID: profile.id, order: 1))
        let workID = state.spaces[1].id

        let resolved = OnboardingCommit.applySpacesSetup(
            [OnboardingSpaceDraft(name: "  work ", emoji: "💼")],
            profileID: profile.id,
            in: &state
        )

        XCTAssertEqual(resolved, [workID], "\"  work \" is the Space called \"Work\" to anyone typing it")
        XCTAssertEqual(state.spaces.count, 2, "no duplicate Space may be created")
        XCTAssertEqual(state.spaces[1].resolvedIcon, .emoji("💼"), "the emoji chosen on that very screen is a direct instruction and does apply")
    }

    func test_applyingSpacesSetup_blankEmojiDoesNotClearAnExistingSpacesIcon() {
        var (state, profile) = documentWithOneProfile()
        var work = Space(name: "Work", profileID: profile.id, order: 1)
        work.setIcon(emoji: "💼")
        state.spaces.append(work)

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "Work", emoji: "")], profileID: profile.id, in: &state)

        XCTAssertEqual(state.spaces[1].resolvedIcon, .emoji("💼"))
    }

    func test_applyingSpacesSetup_leavesAValidActiveSpaceAlone() {
        var (state, profile) = documentWithOneProfile()
        state.spaces.append(Space(name: "Work", profileID: profile.id, order: 1))
        state.activeSpaceID = state.spaces[1].id
        let wasActive = state.activeSpaceID

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "New", emoji: "")], profileID: profile.id, in: &state)

        XCTAssertEqual(state.activeSpaceID, wasActive)
    }

    func test_applyingSpacesSetup_repairsADanglingActiveSpace() {
        var (state, profile) = documentWithOneProfile()
        state.spaces.append(Space(name: "Work", profileID: profile.id, order: 1))
        state.activeSpaceID = SpaceID()

        let resolved = OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "New", emoji: "")], profileID: profile.id, in: &state)

        XCTAssertEqual(state.activeSpaceID, resolved.first)
    }

    func test_isReplaceableFirstRunDocument_classifiesTheSeedAndOnlyTheSeed() {
        var (bare, profile) = documentWithOneProfile()
        XCTAssertTrue(OnboardingCommit.isReplaceableFirstRunDocument(bare), "one Space, nothing pinned, no tabs — the bootstrap seed")

        var withSeedTab = bare
        let seed = Tab(spaceID: withSeedTab.spaces[0].id, section: .today, url: BrowserStore.firstRunTabURL)
        withSeedTab.spaces[0].today = [seed.id]
        withSeedTab.tabs[seed.id] = seed
        XCTAssertTrue(OnboardingCommit.isReplaceableFirstRunDocument(withSeedTab), "the first-run welcome tab is not something a person put there")

        var withUserTab = bare
        let opened = Tab(spaceID: withUserTab.spaces[0].id, section: .today, url: URL(string: "https://example.com")!)
        withUserTab.spaces[0].today = [opened.id]
        withUserTab.tabs[opened.id] = opened
        XCTAssertFalse(OnboardingCommit.isReplaceableFirstRunDocument(withUserTab))

        bare.spaces.append(Space(name: "Second", profileID: profile.id, order: 1))
        XCTAssertFalse(OnboardingCommit.isReplaceableFirstRunDocument(bare))

        XCTAssertTrue(OnboardingCommit.isReplaceableFirstRunDocument(OrbitState()), "an empty document has nothing to lose")
    }

    func test_applyingSpacesSetup_carriesTheSeededFavoritesOntoTheFirstSpace() {
        var (state, profile) = documentWithOneProfile()
        let favorites = [
            Favorite(url: URL(string: "https://www.google.com")!, title: "Google"),
            Favorite(url: URL(string: "https://www.apple.com")!, title: "Apple"),
        ]
        state.spaces[0].favorites = favorites

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "Only", emoji: "")], profileID: profile.id, in: &state)

        XCTAssertEqual(state.spaces.first?.favorites, favorites)
    }

    func test_applyingSpacesSetup_emojiBecomesAResolvedEmojiIcon() throws {
        var (state, profile) = documentWithOneProfile()

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "Reading", emoji: "📚")], profileID: profile.id, in: &state)

        let space = try XCTUnwrap(state.spaces.first)
        XCTAssertEqual(space.resolvedIcon, .emoji("📚"))
    }

    func test_applyingSpacesSetup_blankEmojiBecomesTheRealDotFallback() throws {
        var (state, profile) = documentWithOneProfile()

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "No Emoji", emoji: "")], profileID: profile.id, in: &state)

        let space = try XCTUnwrap(state.spaces.first)
        XCTAssertEqual(space.resolvedIcon, .none, "a Space with no chosen emoji must resolve to the dot, exactly like any other Space nobody has picked an icon for")
    }

    func test_applyingSpacesSetup_whitespaceOnlyEmojiAlsoBecomesTheDotFallback() throws {
        var (state, profile) = documentWithOneProfile()

        OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "Whitespace Emoji", emoji: "   ")], profileID: profile.id, in: &state)

        let space = try XCTUnwrap(state.spaces.first)
        XCTAssertEqual(space.resolvedIcon, .none)
    }

    func test_applyingSpacesSetup_givesEachSpaceItsOwnTheme() {
        var (state, profile) = documentWithOneProfile()
        let drafts = (0..<3).map { OnboardingSpaceDraft(name: "Space \($0)", emoji: "🔹") }

        OnboardingCommit.applySpacesSetup(drafts, profileID: profile.id, in: &state)

        let themes = Set(state.spaces.map(\.theme))
        XCTAssertEqual(themes.count, 3, "SpaceThemePalette.defaultThemes(count:) (see applySpacesSetup's 'Gradient theme' note) must hand back genuinely distinct gradients, or a fresh install's Spaces would look identical in the sidebar")
    }

    func test_applyingSpacesSetup_withNoProfileAtAll_writesNothing() {
        var state = OrbitState()

        let created = OnboardingCommit.applySpacesSetup([OnboardingSpaceDraft(name: "Orphan", emoji: "❓")], profileID: nil, in: &state)

        XCTAssertEqual(created, [])
        XCTAssertTrue(state.spaces.isEmpty)
    }

    // MARK: - Migration safety: an existing installed user must never see any of this

    @MainActor
    private func makeScratchStateStore() -> (store: StateStore, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitTests-BootstrapMigration-\(UUID().uuidString)", isDirectory: true)
        return (StateStore(rootDirectory: root), { try? FileManager.default.removeItem(at: root) })
    }

    @MainActor
    private func preExistingUserDocument() -> OrbitState {
        var document = OrbitState()
        let profile = Profile(name: "Work") // deliberately not "Personal", "default", or "Home"
        document.profiles = [profile]
        let space = Space(name: "Engineering", icon: "briefcase", profileID: profile.id, order: 0)
        document.spaces = [space]
        document.activeSpaceID = space.id
        return document
    }

    @MainActor
    func test_bootstrapNeverRunsAgainstAnExistingUsersDocument() throws {
        let (stateStore, cleanup) = makeScratchStateStore()
        defer { cleanup() }
        try stateStore.saveNow(preExistingUserDocument())

        let store = BrowserStore(stateStore: stateStore, autoArchiveInterval: nil)
        XCTAssertEqual(store.state.profiles.count, 1, "bootstrapIfNeeded() must not add a second Profile alongside the existing one")
        XCTAssertEqual(store.state.profiles.first?.name, "Work", "an existing Profile's name must survive untouched — never rewritten to \"default\"")
        XCTAssertEqual(store.state.spaces.count, 1, "bootstrapIfNeeded() must not add a second Space alongside the existing one")
        XCTAssertEqual(store.state.spaces.first?.name, "Engineering", "an existing Space's name must survive untouched — never rewritten to \"Home\"")
        XCTAssertEqual(store.state.spaces.first?.icon, "briefcase", "an existing Space's icon must survive untouched — never rewritten to \"house\"")
    }

    @MainActor
    func test_bootstrapSeedLiteralsNeverAppearInAnExistingUsersLoadedDocument() throws {
        let (stateStore, cleanup) = makeScratchStateStore()
        defer { cleanup() }
        try stateStore.saveNow(preExistingUserDocument())

        let store = BrowserStore(stateStore: stateStore, autoArchiveInterval: nil)

        XCTAssertFalse(store.state.profiles.contains { $0.name == "default" }, "no existing Profile may be renamed to the new seed's \"default\"")
        XCTAssertFalse(store.state.spaces.contains { $0.name == "Home" }, "no existing Space may be renamed to the new seed's \"Home\"")
    }
}
