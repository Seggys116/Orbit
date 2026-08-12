//  Covers privacy (Incognito must never reach a card, asserted on both SQL and the pure transform),
//  "no card rather than a wrong card", and that the card is actually wired in. HistoryStore cases use a real SQLite file.

import Foundation
import XCTest

// MARK: - Recorded source

private final class RecordedRecentPagesSource: @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var requestedServices: [RecentPagesService] = []
    private(set) var requestedQueries: [RecentPagesQuery] = []
    var entries: [HistoryEntry] = []

    var source: RecentPagesSource {
        RecentPagesSource { [self] service, query in
            callCount += 1
            requestedServices.append(service)
            requestedQueries.append(query)
            return entries
        }
    }
}

// MARK: - Pure model + transform

final class RecentPagesModelTests: XCTestCase {

    private let profile = ProfileID()

    private func entry(
        _ urlString: String,
        title: String,
        age: TimeInterval,
        spaceID: SpaceID? = nil,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> HistoryEntry {
        HistoryEntry(
            url: URL(string: urlString)!,
            title: title,
            visitedAt: now.addingTimeInterval(-age),
            visitCount: 1,
            profileID: profile,
            spaceID: spaceID,
            wasTyped: false
        )
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Service recognition

    func test_matching_recognisesEachServiceFromARealURL() {
        XCTAssertEqual(RecentPagesService.matching(URL(string: "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!), .notion)
        XCTAssertEqual(RecentPagesService.matching(URL(string: "https://www.figma.com/design/AbC123/Marketing-Site")!), .figma)
        XCTAssertEqual(RecentPagesService.matching(URL(string: "https://linear.app/orbit/issue/ENG-42/fix-the-thing")!), .linear)
        XCTAssertEqual(RecentPagesService.matching(URL(string: "https://acme.atlassian.net/wiki/spaces/ENG/pages/98765/Runbook")!), .confluence)
    }

    func test_matching_rejectsAURLThatMerelyMentionsTheService() {
        XCTAssertNil(RecentPagesService.matching(URL(string: "https://www.google.com/search?q=notion.so+pricing")!))
        XCTAssertNil(RecentPagesService.matching(URL(string: "https://blog.example.com/why-i-left-figma.com/post")!))
        XCTAssertNil(RecentPagesService.matching(URL(string: "https://evil.example.com/?next=https://linear.app/")!))
    }

    func test_matching_requiresTheWikiPathForConfluence() {
        XCTAssertEqual(RecentPagesService.matching(URL(string: "https://acme.atlassian.net/wiki/spaces/ENG/pages/1/X")!), .confluence)
        XCTAssertNil(RecentPagesService.matching(URL(string: "https://acme.atlassian.net/browse/ENG-42")!))
    }

    func test_matching_acceptsSubdomainsButNotSuffixLookalikes() {
        XCTAssertEqual(RecentPagesService.matching(URL(string: "https://team.notion.site/Page-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!), .notion)
        XCTAssertNil(RecentPagesService.matching(URL(string: "https://notmyfigma.com/design/AbC123/X")!))
    }

    func test_urlFragments_areTheOnesArcMatchesOn() {
        XCTAssertEqual(RecentPagesService.notion.urlFragment, "notion.")
        XCTAssertEqual(RecentPagesService.figma.urlFragment, "figma.com/")
        XCTAssertEqual(RecentPagesService.linear.urlFragment, "linear.app/")
        XCTAssertEqual(RecentPagesService.confluence.urlFragment, "atlassian.net/wiki/")
    }

    func test_lookback_isArcsThirtyDays() {
        XCTAssertEqual(RecentPagesQuery.arcLookback, 30 * 24 * 60 * 60)
    }

    // MARK: Title tidying

    func test_tidy_stripsTheServicesOwnBrandingSuffix() {
        XCTAssertEqual(RecentPagesTidyTitle.tidy("Q3 Roadmap – Figma", for: .figma), "Q3 Roadmap")
        XCTAssertEqual(RecentPagesTidyTitle.tidy("ENG-42 Fix the thing · Linear", for: .linear), "ENG-42 Fix the thing")
        XCTAssertEqual(RecentPagesTidyTitle.tidy("Runbook - Confluence", for: .confluence), "Runbook")
    }

    func test_tidy_stripsNotionCalendarsOwnBranding() {
        XCTAssertEqual(RecentPagesTidyTitle.tidy("Standup | Notion Calendar", for: .notion), "Standup")
    }

    func test_tidy_leavesATitleThatCarriesNoBrandingAlone() {
        XCTAssertEqual(RecentPagesTidyTitle.tidy("Weekly Plan", for: .notion), "Weekly Plan")
    }

    func test_tidy_yieldsNothingForATitleThatIsOnlyTheServiceName() {
        XCTAssertEqual(RecentPagesTidyTitle.tidy("Notion", for: .notion), "")
    }

    // MARK: Document identity

    func test_documentID_parsesNotionsTrailingPageID() {
        let url = URL(string: "https://www.notion.so/team/Weekly-Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!
        XCTAssertEqual(RecentPagesDocumentID.parse(url, service: .notion), "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")
    }

    func test_documentID_refusesToGuess() {
        XCTAssertNil(RecentPagesDocumentID.parse(URL(string: "https://www.notion.so/team/Notes")!, service: .notion))
        XCTAssertNil(RecentPagesDocumentID.parse(URL(string: "https://www.notion.so/x-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6")!, service: .notion))
        XCTAssertNil(RecentPagesDocumentID.parse(URL(string: "https://www.figma.com/files/recent")!, service: .figma))
        XCTAssertNil(RecentPagesDocumentID.parse(URL(string: "https://acme.atlassian.net/wiki/spaces/ENG/overview")!, service: .confluence))
    }

    func test_documentID_parsesFigmaLinearAndConfluence() {
        XCTAssertEqual(
            RecentPagesDocumentID.parse(URL(string: "https://www.figma.com/design/AbC123/Marketing-Site")!, service: .figma),
            "AbC123"
        )
        XCTAssertEqual(
            RecentPagesDocumentID.parse(URL(string: "https://linear.app/orbit/issue/eng-42/fix-the-thing")!, service: .linear),
            "ENG-42"
        )
        XCTAssertEqual(
            RecentPagesDocumentID.parse(URL(string: "https://acme.atlassian.net/wiki/spaces/ENG/pages/98765/Runbook")!, service: .confluence),
            "98765"
        )
    }

    // MARK: The transform

    func test_build_ordersByMostRecentVisitAndHonoursTheLimit() {
        let entries = [
            entry("https://www.notion.so/a-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c61", title: "Oldest", age: 3_000),
            entry("https://www.notion.so/b-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c62", title: "Newest", age: 10),
            entry("https://www.notion.so/c-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c63", title: "Middle", age: 1_000),
        ]
        let data = RecentPagesCard.build(
            service: .notion, entries: entries,
            query: RecentPagesQuery(limit: 2), now: now
        )
        XCTAssertEqual(data?.items.map(\.displayTitle), ["Newest", "Middle"])
    }

    func test_build_collapsesOnePageReachedUnderTwoTitleSlugs() {
        let identifier = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"
        let entries = [
            entry("https://www.notion.so/team/Old-Name-\(identifier)", title: "Old Name", age: 5_000),
            entry("https://www.notion.so/team/New-Name-\(identifier)", title: "New Name", age: 60),
        ]
        let data = RecentPagesCard.build(service: .notion, entries: entries, query: RecentPagesQuery(), now: now)
        XCTAssertEqual(data?.items.count, 1, "One page addressed twice is one row")
        XCTAssertEqual(data?.items.first?.displayTitle, "New Name", "The surviving row must be the most recent visit")
    }

    // Privacy, on the transform: these rows were never filtered by SQL, exactly the
    // case the SQL-level test cannot cover.
    func test_build_neverShowsARowFromAnExcludedIncognitoSpace() {
        let incognito = SpaceID()
        let normal = SpaceID()
        let entries = [
            entry("https://www.notion.so/secret-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c61", title: "Incognito Page", age: 10, spaceID: incognito),
            entry("https://www.notion.so/open-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c62", title: "Normal Page", age: 500, spaceID: normal),
        ]
        let data = RecentPagesCard.build(
            service: .notion, entries: entries,
            query: RecentPagesQuery(excludedSpaceIDs: [incognito]), now: now
        )
        XCTAssertEqual(data?.items.map(\.displayTitle), ["Normal Page"])
        XCTAssertFalse(
            data?.items.contains { $0.title == "Incognito Page" } ?? false,
            "An Incognito Space's browsing must never surface in a normal Space's card"
        )
    }

    func test_build_returnsNoCardWhenEveryRowIsExcluded() {
        let incognito = SpaceID()
        let entries = [entry("https://www.notion.so/x-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c61", title: "Secret", age: 10, spaceID: incognito)]
        XCTAssertNil(RecentPagesCard.build(
            service: .notion, entries: entries,
            query: RecentPagesQuery(excludedSpaceIDs: [incognito]), now: now
        ))
    }

    func test_build_dropsRowsOlderThanTheWindow() {
        let entries = [
            entry("https://www.notion.so/old-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c61", title: "Ancient", age: RecentPagesQuery.arcLookback + 60),
            entry("https://www.notion.so/new-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c62", title: "Recent", age: 60),
        ]
        let data = RecentPagesCard.build(service: .notion, entries: entries, query: RecentPagesQuery(), now: now)
        XCTAssertEqual(data?.items.map(\.displayTitle), ["Recent"])
    }

    func test_build_returnsNoCardWhenEveryRowIsOutsideTheWindow() {
        let entries = [entry("https://www.notion.so/old-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c61", title: "Ancient", age: RecentPagesQuery.arcLookback + 60)]
        XCTAssertNil(RecentPagesCard.build(service: .notion, entries: entries, query: RecentPagesQuery(), now: now))
    }

    func test_build_dropsRowsBelongingToAnotherService() {
        let entries = [
            entry("https://www.figma.com/design/AbC123/Site", title: "A Figma File", age: 10),
            entry("https://www.notion.so/p-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c61", title: "A Notion Doc", age: 20),
        ]
        let data = RecentPagesCard.build(service: .notion, entries: entries, query: RecentPagesQuery(), now: now)
        XCTAssertEqual(data?.items.map(\.displayTitle), ["A Notion Doc"])
    }

    func test_build_returnsNoCardForNoEntriesAtAll() {
        XCTAssertNil(RecentPagesCard.build(service: .linear, entries: [], query: RecentPagesQuery(), now: now))
    }

    func test_recentPagesData_cannotBeConstructedEmpty() {
        XCTAssertNil(RecentPagesData(service: .notion, items: []))
    }

    func test_iconHost_comesFromABrowsedHostNotAConstant() {
        let entries = [entry("https://acme.atlassian.net/wiki/spaces/ENG/pages/1/Runbook", title: "Runbook", age: 10)]
        let data = RecentPagesCard.build(service: .confluence, entries: entries, query: RecentPagesQuery(), now: now)
        XCTAssertEqual(data?.iconHost, "acme.atlassian.net")
    }

    func test_build_fallsBackToTheURLSlugWhenTheTitleIsOnlyBranding() {
        let entries = [entry("https://www.notion.so/Weekly-Plan", title: "Notion", age: 10)]
        let data = RecentPagesCard.build(service: .notion, entries: entries, query: RecentPagesQuery(), now: now)
        XCTAssertEqual(
            data?.items.first?.displayTitle, "Weekly-Plan",
            "Tidying stripped the title to nothing, so the URL's own slug names the row — not the branding that was just removed"
        )
    }

    func test_build_dropsARowThatCanOnlyNameItselfWithTheServiceName() {
        let entries = [entry("https://www.notion.so/", title: "Notion", age: 10)]
        XCTAssertNil(RecentPagesCard.build(service: .notion, entries: entries, query: RecentPagesQuery(), now: now))
    }
}

// MARK: - The SQLite query

final class RecentPagesHistoryQueryTests: XCTestCase {

    private var directory: URL!
    private let profile = ProfileID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentPagesHistoryQueryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3", isDirectory: false))
    }

    private func record(
        _ store: HistoryStore,
        _ urlString: String,
        title: String,
        ago: TimeInterval,
        spaceID: SpaceID? = nil
    ) async throws {
        _ = try await store.record(visit: HistoryVisit(
            url: URL(string: urlString)!,
            title: title,
            profileID: profile,
            spaceID: spaceID,
            visitedAt: Date().addingTimeInterval(-ago)
        ))
    }

    func test_entriesMatchingURLFragment_returnsOnlyMatchingRowsMostRecentFirst() async throws {
        let store = try makeStore()
        try await record(store, "https://www.notion.so/a", title: "A", ago: 3_000)
        try await record(store, "https://www.notion.so/b", title: "B", ago: 30)
        try await record(store, "https://example.com/unrelated", title: "Unrelated", ago: 5)

        let rows = try await store.entries(
            matchingURLFragment: "notion.",
            since: Date().addingTimeInterval(-RecentPagesQuery.arcLookback)
        )
        XCTAssertEqual(rows.map(\.title), ["B", "A"])
    }

    func test_entriesMatchingURLFragment_excludesRowsOlderThanTheSinceDate() async throws {
        let store = try makeStore()
        try await record(store, "https://www.notion.so/ancient", title: "Ancient", ago: RecentPagesQuery.arcLookback + 3_600)
        try await record(store, "https://www.notion.so/fresh", title: "Fresh", ago: 60)

        let rows = try await store.entries(
            matchingURLFragment: "notion.",
            since: Date().addingTimeInterval(-RecentPagesQuery.arcLookback)
        )
        XCTAssertEqual(rows.map(\.title), ["Fresh"], "A row outside the 30-day window must not come back from SQL at all")
    }

    // Privacy, on the SQL: the exclusion happens before the rows exist in memory.
    func test_entriesMatchingURLFragment_excludesIncognitoSpaceRowsInSQL() async throws {
        let store = try makeStore()
        let incognito = SpaceID()
        let normal = SpaceID()
        try await record(store, "https://www.notion.so/secret", title: "Incognito Page", ago: 10, spaceID: incognito)
        try await record(store, "https://www.notion.so/open", title: "Normal Page", ago: 20, spaceID: normal)

        let rows = try await store.entries(
            matchingURLFragment: "notion.",
            since: Date().addingTimeInterval(-RecentPagesQuery.arcLookback),
            excludingSpaceIDs: [incognito]
        )
        XCTAssertEqual(rows.map(\.title), ["Normal Page"])
    }

    func test_entriesMatchingURLFragment_keepsRowsWithNoSpaceAtAll() async throws {
        let store = try makeStore()
        try await record(store, "https://www.notion.so/imported", title: "Imported", ago: 10, spaceID: nil)

        let rows = try await store.entries(
            matchingURLFragment: "notion.",
            since: Date().addingTimeInterval(-RecentPagesQuery.arcLookback),
            excludingSpaceIDs: [SpaceID()]
        )
        XCTAssertEqual(rows.map(\.title), ["Imported"])
    }

    func test_entriesMatchingURLFragment_honoursTheLimit() async throws {
        let store = try makeStore()
        for index in 0..<6 {
            try await record(store, "https://www.notion.so/p\(index)", title: "P\(index)", ago: TimeInterval(index * 10))
        }
        let rows = try await store.entries(
            matchingURLFragment: "notion.",
            since: Date().addingTimeInterval(-RecentPagesQuery.arcLookback),
            limit: 3
        )
        XCTAssertEqual(rows.map(\.title), ["P0", "P1", "P2"])
    }

    func test_entriesMatchingURLFragment_treatsWildcardCharactersLiterally() async throws {
        let store = try makeStore()
        try await record(store, "https://example.com/a_b", title: "Literal", ago: 10)
        try await record(store, "https://example.com/axb", title: "Wildcard Bait", ago: 5)

        let rows = try await store.entries(
            matchingURLFragment: "a_b",
            since: Date().addingTimeInterval(-RecentPagesQuery.arcLookback)
        )
        XCTAssertEqual(rows.map(\.title), ["Literal"], "`_` must match an underscore, not any character")
    }

    func test_entriesMatchingURLFragment_returnsNothingForAnEmptyFragment() async throws {
        let store = try makeStore()
        try await record(store, "https://www.notion.so/a", title: "A", ago: 10)
        let rows = try await store.entries(matchingURLFragment: "   ", since: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(rows.isEmpty, "An empty fragment must not degenerate into `LIKE '%%'` and return the whole history")
    }

    func test_liveSource_readsTheRealStoreAndHonoursTheQuery() async throws {
        let store = try makeStore()
        let incognito = SpaceID()
        try await record(store, "https://www.notion.so/open", title: "Normal", ago: 30)
        try await record(store, "https://www.notion.so/secret", title: "Secret", ago: 10, spaceID: incognito)

        let source = RecentPagesSource.live(historyStore: store)
        let rows = await source.historyEntries(.notion, RecentPagesQuery(excludedSpaceIDs: [incognito]))
        XCTAssertEqual(rows.map(\.title), ["Normal"])
    }

    @MainActor
    func test_theHistoryConnectionSeamReadsWhicheverStoreItIsGiven() async throws {
        let store = try makeStore()
        try await record(store, "https://www.notion.so/injected", title: "Injected", ago: 30)

        RecentPagesHistoryConnection.override(store)
        defer { RecentPagesHistoryConnection.override(nil) }

        let rows = await RecentPagesHistoryConnection.source().historyEntries(.notion, RecentPagesQuery())
        XCTAssertEqual(rows.map(\.title), ["Injected"])

        RecentPagesHistoryConnection.override(nil)
        let none = await RecentPagesHistoryConnection.source().historyEntries(.notion, RecentPagesQuery())
        XCTAssertTrue(none.isEmpty, "Overriding with nil must yield `.unavailable`, not fall back to opening the real database")
    }

    func test_unavailableSource_yieldsNoRowsAndThereforeNoCard() async {
        let rows = await RecentPagesSource.unavailable.historyEntries(.notion, RecentPagesQuery())
        XCTAssertTrue(rows.isEmpty)
        XCTAssertNil(RecentPagesCard.build(service: .notion, entries: rows, query: RecentPagesQuery()))
    }
}

// MARK: - Controller integration

@MainActor
final class RecentPagesLinkPreviewTests: XCTestCase {

    private var suite: UserDefaults!
    private let profile = ProfileID()

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "RecentPagesLinkPreviewTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
        AssistSettings.isFiveSecondPreviewsEnabled = true
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        super.tearDown()
    }

    private func entry(_ urlString: String, title: String, ago: TimeInterval = 60, spaceID: SpaceID? = nil) -> HistoryEntry {
        HistoryEntry(
            url: URL(string: urlString)!,
            title: title,
            visitedAt: Date().addingTimeInterval(-ago),
            visitCount: 1,
            profileID: profile,
            spaceID: spaceID,
            wasTyped: false
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func failingFetch() -> @Sendable (URL) async throws -> LinkPreviewFetcher.LinkPreviewPageData {
        { _ in
            XCTFail("The recent-pages card must never fetch the hovered page")
            throw LinkPreviewFetchError.decodingFailed
        }
    }

    func test_hoveringANotionLink_buildsTheCardWithNoProviderConfigured() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let recorded = RecordedRecentPagesSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]

        controller.hoverChanged(
            url: URL(string: "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!,
            shiftDown: true, at: .zero,
            isSessionPersistent: true,
            fetch: failingFetch(),
            sink: nil,
            recentPages: recorded.source
        )
        await waitUntil { if case .recentPages = controller.phase { return true } else { return false } }

        guard case .recentPages(let data) = controller.phase else {
            return XCTFail("Expected a recent-pages card, got \(controller.phase)")
        }
        XCTAssertEqual(data.service, .notion)
        XCTAssertEqual(data.items.map(\.displayTitle), ["Weekly Plan"])
        XCTAssertEqual(recorded.requestedServices, [.notion])
    }

    func test_hoveringAnOrdinaryLink_stillTakesTheGenericPathAndNeverAsksHistory() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let recorded = RecordedRecentPagesSource()

        controller.hoverChanged(
            url: URL(string: "https://example.com/an-article")!,
            shiftDown: true, at: .zero,
            isSessionPersistent: true,
            fetch: { _ in throw LinkPreviewFetchError.decodingFailed },
            sink: nil,
            recentPages: recorded.source
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recorded.callCount, 0, "A non-service link must not read browsing history at all")
        if case .recentPages = controller.phase {
            XCTFail("An ordinary link must not produce a recent-pages card")
        }
    }

    // Privacy: .idle is also what "hasn't run yet" looks like; the assertion below is
    // that history was never read.
    func test_hoveringANotionLinkInIncognito_neverReadsHistoryAtAll() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let recorded = RecordedRecentPagesSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]

        controller.hoverChanged(
            url: URL(string: "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!,
            shiftDown: true, at: .zero,
            isSessionPersistent: false,
            fetch: failingFetch(),
            sink: nil,
            recentPages: recorded.source
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(recorded.callCount, 0, "An Incognito session must not read the user's browsing history for a card")
    }

    func test_withTheFeatureDisabled_theCardNeverReadsHistory() async {
        AssistSettings.isFiveSecondPreviewsEnabled = false
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let recorded = RecordedRecentPagesSource()

        controller.hoverChanged(
            url: URL(string: "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!,
            shiftDown: true, at: .zero,
            isSessionPersistent: true,
            fetch: failingFetch(), sink: nil,
            recentPages: recorded.source
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(recorded.callCount, 0)
    }

    func test_withNoMatchingHistory_showsNoCardRatherThanAnEmptyOne() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let recorded = RecordedRecentPagesSource()
        recorded.entries = []

        controller.hoverChanged(
            url: URL(string: "https://www.figma.com/design/AbC123/Site")!,
            shiftDown: true, at: .zero,
            isSessionPersistent: true,
            fetch: failingFetch(), sink: nil,
            recentPages: recorded.source
        )
        await waitUntil { controller.phase == .idle && controller.previewedURL == nil }

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.previewedURL, "`previewedURL` is nil exactly when the phase is idle")
        XCTAssertEqual(recorded.callCount, 1, "It must actually have looked before concluding there was nothing")
    }

    func test_movingToAnotherServiceDiscardsTheAbandonedCard() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let recorded = RecordedRecentPagesSource()
        recorded.entries = [entry("https://linear.app/orbit/issue/ENG-42/fix", title: "ENG-42 Fix")]

        controller.hoverChanged(
            url: URL(string: "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!,
            shiftDown: true, at: .zero, isSessionPersistent: true,
            fetch: failingFetch(), sink: nil, recentPages: recorded.source
        )
        controller.hoverChanged(
            url: URL(string: "https://linear.app/orbit/issue/ENG-42/fix")!,
            shiftDown: true, at: .zero, isSessionPersistent: true,
            fetch: failingFetch(), sink: nil, recentPages: recorded.source
        )
        await waitUntil { if case .recentPages = controller.phase { return true } else { return false } }

        guard case .recentPages(let data) = controller.phase else {
            return XCTFail("Expected the Linear card, got \(controller.phase)")
        }
        XCTAssertEqual(data.service, .linear, "The abandoned Notion card must never replace the Linear one")
    }

    func test_releasingShiftClearsTheCard() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let recorded = RecordedRecentPagesSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]
        let url = URL(string: "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!

        controller.hoverChanged(
            url: url, shiftDown: true, at: .zero, isSessionPersistent: true,
            fetch: failingFetch(), sink: nil, recentPages: recorded.source
        )
        await waitUntil { if case .recentPages = controller.phase { return true } else { return false } }

        controller.hoverChanged(
            url: url, shiftDown: false, at: .zero, isSessionPersistent: true,
            fetch: failingFetch(), sink: nil, recentPages: recorded.source
        )
        XCTAssertEqual(controller.phase, .idle)
    }

    func test_theExclusionSetIsHandedToTheSource() async {
        let controller = LinkPreviewController()
        controller.debounceNanoseconds = 0
        let recorded = RecordedRecentPagesSource()
        let incognito = SpaceID()

        controller.hoverChanged(
            url: URL(string: "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!,
            shiftDown: true, at: .zero, isSessionPersistent: true,
            fetch: failingFetch(), sink: nil,
            recentPages: recorded.source,
            recentPagesQuery: RecentPagesQuery(excludedSpaceIDs: [incognito])
        )
        await waitUntil { recorded.callCount > 0 }

        XCTAssertEqual(recorded.requestedQueries.first?.excludedSpaceIDs, [incognito])
    }
}

// MARK: - The card is actually reached

final class RecentPagesWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_theOverlayActuallyWiresTheCardIn() throws {
        let overlay = try source("Orbit/Features/Assist/LinkPreviewOverlayView.swift")

        XCTAssertTrue(
            overlay.contains("recentPages:"),
            "LinkPreviewOverlayView must pass a recent-pages source to hoverChanged, or the card can never appear"
        )
        XCTAssertTrue(
            overlay.contains("RecentPagesHistoryConnection.source()"),
            "The overlay must resolve a live source; without it every hover would see `.unavailable` and no card could ever be built"
        )
        XCTAssertTrue(
            overlay.contains("recentPagesQuery:"),
            "The overlay must pass a query, or the Incognito exclusion set never reaches the source"
        )
        XCTAssertTrue(
            overlay.contains("incognitoSpaceIDs()"),
            "The overlay must compute the Incognito exclusion set rather than passing an empty one"
        )
    }

    func test_theCardViewActuallyRendersTheNewPhase() throws {
        let card = try source("Orbit/Features/Assist/LinkPreviewCardView.swift")
        XCTAssertTrue(
            card.contains("case .recentPages(let data):"),
            "LinkPreviewCardView must bind the card's data, not merely match the case"
        )
        XCTAssertTrue(
            card.contains("recentPages(data)"),
            "LinkPreviewCardView must hand the bound data to its renderer, or a built card would draw as nothing"
        )
    }
}
