import XCTest

@MainActor
final class TornOffEphemeralStateTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture {
        var state: OrbitState
        var profileID: ProfileID
        var ordinarySpaceID: SpaceID
        var tornOffSpaceID: SpaceID
        var ordinaryTabID: TabID
        var tornOffTabID: TabID
        var tornOffSplitGroupID: UUID
    }

    private func makeFixture() -> Fixture {
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        state.profiles = [profile]

        let ordinarySpace = Space(name: "Work", profileID: profile.id, order: 0)
        let tornOffSpace = Space(
            name: "GitHub pull request",
            icon: "shippingbox",
            profileID: profile.id,
            order: 1,
            isEphemeral: true
        )
        state.spaces = [ordinarySpace, tornOffSpace]
        state.activeSpaceID = ordinarySpace.id

        let ordinaryTab = Tab(spaceID: ordinarySpace.id, url: URL(string: "https://ordinary.example.com/keep-me")!)
        let tornOffTab = Tab(
            spaceID: tornOffSpace.id,
            url: URL(string: "https://torn-off.example.com/must-not-persist")!,
            splitGroupID: nil
        )
        state.tabs[ordinaryTab.id] = ordinaryTab
        state.tabs[tornOffTab.id] = tornOffTab

        let splitGroup = SplitGroup(tabIDs: [tornOffTab.id], axis: .horizontal)
        state.splitGroups[splitGroup.id] = splitGroup
        state.tabs[tornOffTab.id]?.splitGroupID = splitGroup.id
        state.activeTabBySpace[tornOffSpace.id] = tornOffTab.id
        state.activeTabBySpace[ordinarySpace.id] = ordinaryTab.id

        return Fixture(
            state: state,
            profileID: profile.id,
            ordinarySpaceID: ordinarySpace.id,
            tornOffSpaceID: tornOffSpace.id,
            ordinaryTabID: ordinaryTab.id,
            tornOffTabID: tornOffTab.id,
            tornOffSplitGroupID: splitGroup.id
        )
    }

    // MARK: - The load-bearing test: a torn-off Space on a persistent Profile is dropped, the Profile survives

    func test_ephemeralSpaceOnAPersistentProfile_isRemovedWithItsTabsAndSplitGroups_profileSurvives() throws {
        let fixture = makeFixture()
        XCTAssertTrue(
            fixture.state.profiles.first { $0.id == fixture.profileID }?.isPersistent == true,
            "test precondition: the torn-off Space's own Profile must be persistent — that is the entire point of a tear-off, unlike Incognito"
        )

        let stripped = fixture.state.strippingEphemeralEntities()

        XCTAssertFalse(
            stripped.spaces.contains { $0.id == fixture.tornOffSpaceID },
            "a Space marked ephemeral must be dropped by strippingEphemeralEntities() even though its Profile is persistent"
        )
        XCTAssertNil(
            stripped.tabs[fixture.tornOffTabID],
            "the torn-off Space's own tab (its URL included) must not survive into the persisted document"
        )
        XCTAssertNil(
            stripped.splitGroups[fixture.tornOffSplitGroupID],
            "the torn-off Space's split group must be dropped along with its Space"
        )
        XCTAssertNil(
            stripped.activeTabBySpace[fixture.tornOffSpaceID],
            "a dangling activeTabBySpace entry for the dropped Space must not survive"
        )
        XCTAssertTrue(
            stripped.profiles.contains { $0.id == fixture.profileID },
            "the origin tab's own persistent Profile must survive a torn-off window closing — this is the whole reason tearing off does not sign the user out of anything"
        )
        XCTAssertEqual(
            stripped.profiles.count, 1,
            "no Profile beyond the one persistent Profile in this fixture may be removed or added"
        )
    }

    // MARK: - The regression guard: an ordinary Space on the same Profile is untouched

    func test_anOrdinarySpaceOnTheSameProfile_isUntouchedByTheSameCall() throws {
        let fixture = makeFixture()

        let stripped = fixture.state.strippingEphemeralEntities()

        let survivingOrdinarySpace = try XCTUnwrap(
            stripped.spaces.first { $0.id == fixture.ordinarySpaceID },
            "an ordinary Space on the same Profile as a torn-off one was removed — the main window's own tabs must survive closing a torn-off window"
        )
        XCTAssertEqual(survivingOrdinarySpace.profileID, fixture.profileID, "the surviving Space must keep its original Profile, not be reassigned")
        XCTAssertFalse(survivingOrdinarySpace.isEphemeral, "an ordinary Space must never be reported as ephemeral")
        XCTAssertNotNil(
            stripped.tabs[fixture.ordinaryTabID],
            "the ordinary Space's own tab must survive — this is the exact regression this test guards against"
        )
        XCTAssertEqual(
            stripped.activeTabBySpace[fixture.ordinarySpaceID], fixture.ordinaryTabID,
            "the ordinary Space's activeTabBySpace entry must be untouched"
        )
        XCTAssertEqual(
            stripped.activeSpaceID, fixture.ordinarySpaceID,
            "activeSpaceID already pointed at the surviving ordinary Space and must be left alone"
        )
    }

    func test_documentWithNoEphemeralSpaceAtAll_isReturnedUntouched() {
        var state = OrbitState()
        let profile = Profile(name: "Personal")
        state.profiles = [profile]
        let space = Space(name: "Work", profileID: profile.id, order: 0)
        state.spaces = [space]
        state.activeSpaceID = space.id

        let stripped = state.strippingEphemeralEntities()

        XCTAssertEqual(stripped.profiles.map(\.id), state.profiles.map(\.id))
        XCTAssertEqual(stripped.spaces.map(\.id), state.spaces.map(\.id))
        XCTAssertEqual(stripped.activeSpaceID, state.activeSpaceID)
    }

    // MARK: - activeSpaceID falls back correctly when the torn-off Space was active

    func test_activeSpaceID_fallsBackToARealSpaceWhenTheTornOffSpaceWasSomehowActive() {
        var fixture = makeFixture()
        fixture.state.activeSpaceID = fixture.tornOffSpaceID

        let stripped = fixture.state.strippingEphemeralEntities()

        XCTAssertEqual(
            stripped.activeSpaceID, fixture.ordinarySpaceID,
            "a dangling activeSpaceID pointing at the removed torn-off Space must fall back to a real, surviving Space"
        )
    }

    // MARK: - Incognito stripping still works (do not regress it)

    private static var incognitoTheme: SpaceTheme {
        SpaceTheme(
            style: .solid,
            colors: [ThemeColor(red: 0.1, green: 0.1, blue: 0.13)],
            grain: 0.4,
            prefersDarkContent: true
        )
    }

    func test_incognitoShapedSpaceAndProfile_areBothRemoved() {
        var state = OrbitState()
        let realProfile = Profile(name: "Personal")
        let incognitoProfile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
        state.profiles = [realProfile, incognitoProfile]

        let realSpace = Space(name: "Personal", profileID: realProfile.id, order: 0)
        let incognitoSpace = Space(
            name: "Incognito",
            icon: "eyeglasses",
            theme: Self.incognitoTheme,
            profileID: incognitoProfile.id,
            order: 1,
            isEphemeral: true
        )
        state.spaces = [realSpace, incognitoSpace]
        state.activeSpaceID = incognitoSpace.id

        let incognitoTab = Tab(spaceID: incognitoSpace.id, url: URL(string: "https://private.example.com/secret")!)
        state.tabs[incognitoTab.id] = incognitoTab

        let stripped = state.strippingEphemeralEntities()

        XCTAssertFalse(stripped.profiles.contains { $0.id == incognitoProfile.id }, "the Incognito Profile must still be dropped")
        XCTAssertFalse(stripped.spaces.contains { $0.id == incognitoSpace.id }, "the Incognito Space must still be dropped")
        XCTAssertNil(stripped.tabs[incognitoTab.id], "the Incognito tab must still be dropped")
        XCTAssertTrue(stripped.profiles.contains { $0.id == realProfile.id }, "the real Profile must still survive")
        XCTAssertTrue(stripped.spaces.contains { $0.id == realSpace.id }, "the real Space must still survive")
        XCTAssertEqual(
            stripped.activeSpaceID, realSpace.id,
            "activeSpaceID must still fall back off a removed Incognito Space onto the surviving real one"
        )
    }

    func test_aTornOffSpaceAndAnIncognitoSpaceOpenTogether_areBothStrippedIndependently() {
        var fixture = makeFixture()
        let incognitoProfile = Profile(name: "Incognito", symbolName: "eyeglasses", isPersistent: false)
        fixture.state.profiles.append(incognitoProfile)
        let incognitoSpace = Space(
            name: "Incognito",
            icon: "eyeglasses",
            theme: Self.incognitoTheme,
            profileID: incognitoProfile.id,
            order: 2,
            isEphemeral: true
        )
        fixture.state.spaces.append(incognitoSpace)

        let stripped = fixture.state.strippingEphemeralEntities()

        XCTAssertFalse(stripped.spaces.contains { $0.id == fixture.tornOffSpaceID })
        XCTAssertFalse(stripped.spaces.contains { $0.id == incognitoSpace.id })
        XCTAssertFalse(stripped.profiles.contains { $0.id == incognitoProfile.id })
        XCTAssertTrue(stripped.profiles.contains { $0.id == fixture.profileID }, "the torn-off tab's persistent Profile must survive both strips happening together")
        XCTAssertTrue(stripped.spaces.contains { $0.id == fixture.ordinarySpaceID }, "the ordinary Space must survive both strips happening together")
    }
}
