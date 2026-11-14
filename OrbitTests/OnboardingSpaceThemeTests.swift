import XCTest

// Direct source inclusion: OnboardingCommit.swift is compiled into the test bundle.

final class OnboardingSpaceThemeTests: XCTestCase {

    private func documentWithOneSpace() -> (OrbitState, Profile) {
        let profile = Profile(name: "Personal")
        var state = OrbitState()
        state.profiles = [profile]
        state.spaces = [Space(name: "Personal", profileID: profile.id)]
        return (state, profile)
    }

    // MARK: - Theme resolution

    func test_withNoPicks_resolutionEqualsTheDefaultSequence() {
        let drafts = (0..<3).map { OnboardingSpaceDraft(name: "Space \($0)", emoji: "") }

        XCTAssertEqual(
            OnboardingCommit.resolvedThemes(for: drafts),
            SpaceThemePalette.defaultThemes(count: 3)
        )
    }

    func test_aPick_isKept_andOtherDraftsAvoidIt() {
        let picked = SpaceThemePalette.presets[1]
        let drafts = [
            OnboardingSpaceDraft(name: "A", emoji: ""),
            OnboardingSpaceDraft(name: "B", emoji: "", theme: picked),
            OnboardingSpaceDraft(name: "C", emoji: ""),
        ]

        let themes = OnboardingCommit.resolvedThemes(for: drafts)

        XCTAssertEqual(themes[1], picked)
        XCTAssertNotEqual(themes[0], picked, "an unpicked draft must not take a colour another draft chose")
        XCTAssertNotEqual(themes[2], picked)
        XCTAssertNotEqual(themes[0], themes[2])
    }

    // MARK: - Persistence

    func test_chosenThemes_landOnTheCreatedSpaces() {
        var (state, profile) = documentWithOneSpace()
        let pickA = SpaceThemePalette.presets[4]
        let pickB = SpaceThemePalette.presets[7]

        OnboardingCommit.applySpacesSetup(
            [
                OnboardingSpaceDraft(name: "Work", emoji: "", theme: pickA),
                OnboardingSpaceDraft(name: "Play", emoji: "", theme: pickB),
            ],
            profileID: profile.id,
            in: &state
        )

        XCTAssertEqual(state.spaces.map(\.name), ["Work", "Play"])
        XCTAssertEqual(state.spaces.map(\.theme), [pickA, pickB])
    }

    func test_aMergedNewSpace_usesItsChosenTheme() {
        var (state, profile) = documentWithOneSpace()
        state.spaces[0].pinned = [.tab(UUID())]
        let pick = SpaceThemePalette.presets[5]

        OnboardingCommit.applySpacesSetup(
            [OnboardingSpaceDraft(name: "Reading", emoji: "", theme: pick)],
            profileID: profile.id,
            in: &state
        )

        XCTAssertEqual(state.spaces.first { $0.name == "Reading" }?.theme, pick)
    }

    // MARK: - Spaces an import already created

    func test_linkedDrafts_editExistingSpacesInPlace() throws {
        var (state, profile) = documentWithOneSpace()
        let existingID = state.spaces[0].id
        let pick = SpaceThemePalette.presets[6]
        var draft = OnboardingSpaceDraft.drafts(from: state.spaces)[0]
        draft.name = "Home"
        draft.emoji = "🏠"
        draft.theme = pick

        let resolved = OnboardingCommit.applySpacesSetup([draft], profileID: profile.id, in: &state)

        XCTAssertEqual(resolved, [existingID])
        XCTAssertEqual(state.spaces.count, 1, "editing must not add a Space")
        XCTAssertEqual(state.spaces[0].id, existingID, "a first-run-looking document must not be replaced under an import")
        XCTAssertEqual(state.spaces[0].name, "Home")
        XCTAssertEqual(state.spaces[0].theme, pick)
        XCTAssertEqual(state.spaces[0].resolvedIcon, .emoji("🏠"))
    }

    func test_linkedDrafts_keepTheImportedTabs() {
        var (state, profile) = documentWithOneSpace()
        let spaceID = state.spaces[0].id
        let tab = Tab(spaceID: spaceID, section: .pinned, url: URL(string: "https://example.com")!, title: "Example")
        state.tabs[tab.id] = tab
        state.spaces[0].pinned = [.tab(tab.id)]
        let drafts = OnboardingSpaceDraft.drafts(from: state.spaces)

        OnboardingCommit.applySpacesSetup(drafts, profileID: profile.id, in: &state)

        XCTAssertNotNil(state.tabs[tab.id])
        XCTAssertEqual(state.spaces[0].pinned.count, 1)
    }

    func test_linkedAndNewDrafts_mixInOnePass() {
        var (state, profile) = documentWithOneSpace()
        var drafts = OnboardingSpaceDraft.drafts(from: state.spaces)
        drafts.append(OnboardingSpaceDraft(name: "Side project", emoji: ""))

        OnboardingCommit.applySpacesSetup(drafts, profileID: profile.id, in: &state)

        XCTAssertEqual(state.spaces.count, 2)
        XCTAssertEqual(state.spaces.map(\.name), ["Personal", "Side project"])
    }

    func test_draftsFromSpaces_followSidebarOrderAndCarryEmoji() {
        let profile = Profile(name: "Personal")
        var first = Space(name: "First", profileID: profile.id, order: 1)
        first.setIcon(emoji: "🚀")
        let second = Space(name: "Second", profileID: profile.id, order: 0)

        let drafts = OnboardingSpaceDraft.drafts(from: [first, second])

        XCTAssertEqual(drafts.map(\.name), ["Second", "First"])
        XCTAssertEqual(drafts.map(\.emoji), ["", "🚀"])
        XCTAssertEqual(drafts.map(\.existingSpaceID), [second.id, first.id])
        XCTAssertEqual(drafts.compactMap(\.theme), [second.theme, first.theme])
    }
}
