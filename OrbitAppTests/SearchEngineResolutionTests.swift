import Foundation
import XCTest
@testable import Orbit

@MainActor
final class SearchEngineResolutionTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    @discardableResult
    private func seedTwoProfiles() -> (personal: Profile, work: Profile, personalSpace: Space, workSpace: Space) {
        var personal = Profile(name: "Personal")
        personal.searchEngine = .google
        var work = Profile(name: "Work")
        work.searchEngine = .duckDuckGo

        let personalSpace = Space(name: "Personal", profileID: personal.id)
        let workSpace = Space(name: "Work", profileID: work.id)

        var document = OrbitState()
        document.profiles = [personal, work]
        document.spaces = [personalSpace, workSpace]
        document.activeSpaceID = personalSpace.id
        env.state = document

        return (personal, work, personalSpace, workSpace)
    }

    private func setEngine(_ engine: SearchEngine, on profileID: ProfileID) {
        guard let index = env.state.profiles.firstIndex(where: { $0.id == profileID }) else {
            return XCTFail("no Profile \(profileID) in the seeded document")
        }
        env.state.profiles[index].searchEngine = engine
    }

    // MARK: - The active Profile decides

    func test_activeEngineFollowsTheActiveSpacesProfile() {
        let seeded = seedTwoProfiles()

        env.state.activeSpaceID = seeded.personalSpace.id
        XCTAssertEqual(env.searchEngine, .google)

        env.state.activeSpaceID = seeded.workSpace.id
        XCTAssertEqual(
            env.searchEngine, .duckDuckGo,
            "the engine must be scoped per Profile — switching to a Space on another Profile must change it"
        )
    }

    func test_engineForAnExplicitSpaceIgnoresWhichSpaceIsActive() {
        let seeded = seedTwoProfiles()
        env.state.activeSpaceID = seeded.personalSpace.id

        XCTAssertEqual(env.searchEngine(forSpace: seeded.workSpace.id), .duckDuckGo)
        XCTAssertEqual(env.searchEngine(forSpace: seeded.personalSpace.id), .google)
    }

    func test_withNoActiveSpace_fallsBackInsteadOfFailing() {
        env.state = OrbitState()

        XCTAssertEqual(env.searchEngine, .fallback)
        XCTAssertNotNil(env.resolveTypedInput("hello world"))
    }

    // MARK: - Changing the setting changes the resolved URL

    func test_changingTheProfilesEngineChangesWhereATypedQueryGoes() throws {
        let seeded = seedTwoProfiles()
        env.state.activeSpaceID = seeded.personalSpace.id

        let before = try XCTUnwrap(env.resolveTypedInput("swift concurrency"))
        XCTAssertEqual(before.host, "www.google.com", "precondition: Personal starts on Google")

        setEngine(.ecosia, on: seeded.personal.id)

        let after = try XCTUnwrap(env.resolveTypedInput("swift concurrency"))
        XCTAssertEqual(
            after.host, "www.ecosia.org",
            "changing the Profile's engine must change the URL a typed query resolves to"
        )
        XCTAssertNotEqual(before, after)
    }

    func test_everyEngineIsReachableThroughTheProfile() throws {
        let seeded = seedTwoProfiles()
        env.state.activeSpaceID = seeded.personalSpace.id

        var hosts: Set<String> = []
        for engine in SearchEngine.allCases {
            setEngine(engine, on: seeded.personal.id)
            let url = try XCTUnwrap(env.resolveTypedInput("orbit"))
            let host = try XCTUnwrap(url.host)
            XCTAssertTrue(
                hosts.insert(host).inserted,
                "\(engine) resolved to a host another engine already used — the popup would be decorative"
            )
        }
        XCTAssertEqual(hosts.count, SearchEngine.allCases.count)
    }

    // MARK: - Addresses must still be addresses

    func test_realAddressesAreNotHandedToTheSearchEngine() throws {
        let seeded = seedTwoProfiles()
        env.state.activeSpaceID = seeded.workSpace.id  // DuckDuckGo

        let explicit = try XCTUnwrap(env.resolveTypedInput("https://example.com/path"))
        XCTAssertEqual(explicit.absoluteString, "https://example.com/path")

        let bareDomain = try XCTUnwrap(env.resolveTypedInput("example.com"))
        XCTAssertEqual(bareDomain.host, "example.com", "a bare domain is an address, not a search")
        XCTAssertNotEqual(bareDomain.host, "duckduckgo.com")

        let prose = try XCTUnwrap(env.resolveTypedInput("how do i make pasta"))
        XCTAssertEqual(prose.host, "duckduckgo.com", "prose is a search, on the Profile's engine")
    }

    func test_emptyInputResolvesToNothing() {
        seedTwoProfiles()
        XCTAssertNil(env.resolveTypedInput(""))
        XCTAssertNil(env.resolveTypedInput("   "))
    }

    // MARK: - Suggestions toggle

    func test_suggestionsPreferenceFollowsTheActiveProfile() {
        let seeded = seedTwoProfiles()
        env.state.activeSpaceID = seeded.personalSpace.id
        XCTAssertTrue(env.includesSearchSuggestions, "precondition: on by default")

        guard let index = env.state.profiles.firstIndex(where: { $0.id == seeded.personal.id }) else {
            return XCTFail("seeded Profile vanished")
        }
        env.state.profiles[index].includesSearchSuggestions = false

        XCTAssertFalse(env.includesSearchSuggestions)

        env.state.activeSpaceID = seeded.workSpace.id
        XCTAssertTrue(env.includesSearchSuggestions, "the other Profile keeps its own answer")
    }

    // MARK: - The Command Bar's own copy must not lie

    func test_commandBarLiteralSearchRowNamesTheConfiguredEngine() throws {
        let seeded = seedTwoProfiles()
        env.state.activeSpaceID = seeded.workSpace.id

        let results = CommandBarEngine.results(
            query: "how do i make pasta",
            mode: .newTab,
            env: env,
            suggestions: [],
            searchEngine: env.searchEngine
        )
        let searchRow = try XCTUnwrap(
            results.first { if case .searchSuggestion = $0.kind { return true } else { return false } },
            "a prose query must offer a literal search row"
        )
        XCTAssertEqual(searchRow.subtitle, "Search DuckDuckGo")

        setEngine(.bing, on: seeded.work.id)
        let rerun = CommandBarEngine.results(
            query: "how do i make pasta",
            mode: .newTab,
            env: env,
            suggestions: [],
            searchEngine: env.searchEngine
        )
        let rerunRow = try XCTUnwrap(
            rerun.first { if case .searchSuggestion = $0.kind { return true } else { return false } }
        )
        XCTAssertEqual(rerunRow.subtitle, "Search Bing")
    }
}
