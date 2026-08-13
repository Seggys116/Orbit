import Foundation
import XCTest

// MARK: - Recorded provider

private final class TidyTabsProvider: @unchecked Sendable {
    private(set) var requests: [AssistRequest] = []
    var reply = ""
    var failure: AssistError?

    var sink: AssistSink {
        AssistSink(
            generate: { [self] request in
                requests.append(request)
                if let failure { throw failure }
                return reply
            },
            pageText: {
                XCTFail("Tidy Tabs must never read page text — Arc's policy row lists tab titles and URLs only.")
                return nil
            }
        )
    }
}

@MainActor
// Whole suite excluded on GitHub-hosted runners: needs a real running app, not a headless VM.
final class TidyTabsRuntimeTests: XCTestCase {

    private var suite: UserDefaults!
    private var runtime: AssistRuntime!
    private var provider: TidyTabsProvider!

    private var candidates: [AssistRuntime.TidyTabCandidate] = []

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "TidyTabsRuntimeTests-\(UUID().uuidString)")
        AssistSettings.defaults = suite
        AssistSettings.isEnabled = true
        AssistSettings.isTidyTabsEnabled = true
        runtime = AssistRuntime()
        provider = TidyTabsProvider()
        candidates = [
            .init(id: UUID(), title: "Best time to visit Oaxaca", url: URL(string: "https://www.lonelyplanet.com/mexico/oaxaca")!),
            .init(id: UUID(), title: "Oaxaca flights in April", url: URL(string: "https://www.google.com/flights?q=oaxaca")!),
            .init(id: UUID(), title: "Mezcal tasting tour", url: URL(string: "https://www.airbnb.com/experiences/9021")!),
            .init(id: UUID(), title: "Swift concurrency roadmap", url: URL(string: "https://forums.swift.org/t/concurrency")!),
            .init(id: UUID(), title: "Sendable and actor isolation", url: URL(string: "https://www.google.com/search?q=sendable")!),
            .init(id: UUID(), title: "WWDC session on Observation", url: URL(string: "https://developer.apple.com/videos/1234")!),
            .init(id: UUID(), title: "Kitchen extension quotes", url: URL(string: "https://www.checkatrade.com/quotes")!),
            .init(id: UUID(), title: "Council planning portal", url: URL(string: "https://planning.example.gov.uk/app")!),
        ]
    }

    override func tearDown() {
        AssistSettings.defaults = .standard
        suite = nil
        runtime = nil
        provider = nil
        candidates = []
        super.tearDown()
    }

    private func id(_ index: Int) -> TabID { candidates[index].id }

    // MARK: - What leaves the machine

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_thePromptCarriesEveryTabsTitleAndAddressAndNothingElse

    func test_thePromptCarriesEveryTabsTitleAndAddressAndNothingElse() async throws {
        provider.reply = "GROUP: Oaxaca Trip | 1, 2, 3"
        _ = try await runtime.tidiedTabGroups(candidates: candidates, sink: provider.sink)

        let request = try XCTUnwrap(provider.requests.first)
        for candidate in candidates {
            XCTAssertTrue(
                request.user.contains(candidate.title),
                "Every tab's title has to be in the request — it is half of what the grouping is for."
            )
            XCTAssertTrue(
                request.user.contains(candidate.url.absoluteString),
                "Every tab's address has to be in the request."
            )
        }
        XCTAssertEqual(provider.requests.count, 1, "One press of the broom is one request, not one per tab.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_thePromptIsBuiltOnlyFromTitlesAndAddresses

    func test_thePromptIsBuiltOnlyFromTitlesAndAddresses() async throws {
        provider.reply = "GROUP: Oaxaca Trip | 1, 2, 3"
        _ = try await runtime.tidiedTabGroups(candidates: candidates, sink: provider.sink)
        let request = try XCTUnwrap(provider.requests.first)

        var permitted = "Tabs:\n"
        permitted += candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element.title) — \($0.element.url.absoluteString)" }
            .joined(separator: "\n")
        XCTAssertEqual(
            request.user, permitted,
            """
            The user message must be exactly the numbered title+address list. Arc's own \
            privacy policy row for Tidy Tabs lists "Name of tab title, tab URL" and nothing \
            else, so a third field appearing here is a disclosure that has stopped being true.
            """
        )
    }

    // MARK: - Refusals

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_refusesWhenTheFeatureIsOff

    func test_refusesWhenTheFeatureIsOff() async {
        AssistSettings.isTidyTabsEnabled = false
        provider.reply = "GROUP: Anything | 1, 2"
        do {
            _ = try await runtime.tidiedTabGroups(candidates: candidates, sink: provider.sink)
            XCTFail("A switched-off feature must refuse.")
        } catch {
            XCTAssertEqual(error as? AssistError, .featureDisabled("Tidy Tabs"))
        }
        XCTAssertTrue(provider.requests.isEmpty, "A switched-off feature must not reach the provider at all.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_refusesAtSixTabsAndRunsAtSeven

    func test_refusesAtSixTabsAndRunsAtSeven() async throws {
        provider.reply = "GROUP: Oaxaca Trip | 1, 2, 3"

        do {
            _ = try await runtime.tidiedTabGroups(candidates: Array(candidates.prefix(6)), sink: provider.sink)
            XCTFail("Six tabs is not more than six.")
        } catch {
            XCTAssertEqual(error as? AssistError, .featureDisabled("Tidy Tabs"))
        }
        XCTAssertTrue(provider.requests.isEmpty, "Below the threshold nothing may be sent.")

        let groups = try await runtime.tidiedTabGroups(candidates: Array(candidates.prefix(7)), sink: provider.sink)
        XCTAssertEqual(groups.count, 1, "Seven tabs is more than six.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aProviderErrorThrowsAndProducesNoGroups

    func test_aProviderErrorThrowsAndProducesNoGroups() async {
        provider.failure = .http(status: 503, body: "overloaded")
        do {
            let groups = try await runtime.tidiedTabGroups(candidates: candidates, sink: provider.sink)
            XCTFail("A failed request must throw, not return \(groups).")
        } catch {
            XCTAssertEqual(error as? AssistError, .http(status: 503, body: "overloaded"))
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aReplyWithNoUsableGroupThrowsRatherThanReturningNothing

    func test_aReplyWithNoUsableGroupThrowsRatherThanReturningNothing() async {
        provider.reply = "I'm sorry, I can't help with that."
        do {
            _ = try await runtime.tidiedTabGroups(candidates: candidates, sink: provider.sink)
            XCTFail("An unusable reply must throw.")
        } catch {
            XCTAssertEqual(error as? AssistError, .emptyCompletion)
        }
    }

    // MARK: - Grounding: a group may contain only tabs that were sent

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aGroupNamingATabThatWasNeverSentDropsThatTab

    func test_aGroupNamingATabThatWasNeverSentDropsThatTab() {
        let stranger = UUID()
        let parsed = [AssistRuntime.TidyTabGroup(name: "Oaxaca Trip", tabIDs: [id(0), stranger, id(1)])]

        let grounded = AssistRuntime.groundedTidyGroups(parsed, in: candidates)

        XCTAssertEqual(grounded.count, 1)
        XCTAssertEqual(
            grounded[0].tabIDs, [id(0), id(1)],
            """
            A group must contain only tabs that were actually sent. This is Tidy Tabs' \
            equivalent of `verifiedQuote(_:in:)` — a header standing over a tab the request \
            never mentioned is a fabricated result.
            """
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aTabClaimedByTwoGroupsIsKeptOnlyByTheFirst

    func test_aTabClaimedByTwoGroupsIsKeptOnlyByTheFirst() {
        let parsed = [
            AssistRuntime.TidyTabGroup(name: "Oaxaca Trip", tabIDs: [id(0), id(1), id(2)]),
            AssistRuntime.TidyTabGroup(name: "Swift", tabIDs: [id(2), id(3), id(4)]),
        ]

        let grounded = AssistRuntime.groundedTidyGroups(parsed, in: candidates)

        XCTAssertEqual(grounded.map(\.tabIDs), [[id(0), id(1), id(2)], [id(3), id(4)]])
        XCTAssertEqual(
            grounded.flatMap(\.tabIDs).count, Set(grounded.flatMap(\.tabIDs)).count,
            "The rendered runs are a partition of the list; a tab cannot sit under two headers."
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aGroupOfOneIsDroppedAndItsTabIsGivenBackToALaterGroup

    func test_aGroupOfOneIsDroppedAndItsTabIsGivenBackToALaterGroup() {
        let parsed = [
            AssistRuntime.TidyTabGroup(name: "Lonely", tabIDs: [id(0)]),
            AssistRuntime.TidyTabGroup(name: "Oaxaca Trip", tabIDs: [id(0), id(1), id(2)]),
        ]

        let grounded = AssistRuntime.groundedTidyGroups(parsed, in: candidates)

        XCTAssertEqual(grounded.count, 1, "A header over a single row is a second title, not a group.")
        XCTAssertEqual(
            grounded[0].tabIDs, [id(0), id(1), id(2)],
            """
            The dropped group must release its member. If it did not, tab 1 would be \
            silently missing from the only real group that named it.
            """
        )
    }

    // MARK: - Parsing a real-shaped reply

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_parsesGroupLinesAndIgnoresEverythingElse

    func test_parsesGroupLinesAndIgnoresEverythingElse() {
        let reply = """
            Sure! Here's how I'd organise them:
            GROUP: Oaxaca Trip | 1, 2, 3
            GROUP: "Swift Concurrency" | 4,5,6
            GROUP: Other | 7 and 8
            Let me know if you'd like different groupings.
            """

        let parsed = AssistRuntime.parseTidyTabsReply(reply, candidates: candidates)

        XCTAssertEqual(parsed.map(\.name), ["Oaxaca Trip", "Swift Concurrency", "Other"])
        XCTAssertEqual(parsed[0].tabIDs, [id(0), id(1), id(2)])
        XCTAssertEqual(parsed[1].tabIDs, [id(3), id(4), id(5)], "Quotes around a name and no spaces between numbers are both normal model output.")
        XCTAssertEqual(parsed[2].tabIDs, [id(6), id(7)], "`7 and 8` must yield two tabs, not a tab numbered 78.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aNumberOutsideTheListIsDropped

    func test_aNumberOutsideTheListIsDropped() {
        let parsed = AssistRuntime.parseTidyTabsReply("GROUP: Oaxaca Trip | 1, 99, 0, 2", candidates: candidates)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].tabIDs, [id(0), id(1)], "There is no tab 99 and no tab 0.")
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aNameThatIsASentenceIsRejectedRatherThanTruncated

    func test_aNameThatIsASentenceIsRejectedRatherThanTruncated() {
        XCTAssertNil(
            AssistRuntime.acceptTidyGroupName("These all seem to be about planning a trip to Oaxaca"),
            "A truncated sentence looks like a name and is not one, so it is refused outright."
        )
        XCTAssertEqual(AssistRuntime.acceptTidyGroupName("  1. \"Oaxaca Trip\":  "), "Oaxaca Trip")
        XCTAssertNil(AssistRuntime.acceptTidyGroupName("   "))
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aScriptedReplyBecomesGroupsOverTheTabsThatWereSent

    func test_aScriptedReplyBecomesGroupsOverTheTabsThatWereSent() async throws {
        provider.reply = """
            GROUP: Oaxaca Trip | 1, 2, 3
            GROUP: Swift Concurrency | 4, 5, 6
            GROUP: Building Work | 7, 8
            """

        let groups = try await runtime.tidiedTabGroups(candidates: candidates, sink: provider.sink)

        XCTAssertEqual(groups.map(\.name), ["Oaxaca Trip", "Swift Concurrency", "Building Work"])
        XCTAssertEqual(groups.flatMap(\.tabIDs).count, 8)
        XCTAssertTrue(
            Set(groups.flatMap(\.tabIDs)).isSubset(of: Set(candidates.map(\.id))),
            "Every grouped tab was one of the tabs sent."
        )
        XCTAssertFalse(groups.map(\.name).contains("Google"))
    }

    // MARK: - Where a header goes in the rendered list

    private func tab(_ index: Int, group: String?) -> Tab {
        Tab(
            id: candidates[index].id,
            spaceID: UUID(),
            url: candidates[index].url,
            title: candidates[index].title,
            tidyGroup: group
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aHeaderIsEmittedOnceAtTheStartOfEachRun

    func test_aHeaderIsEmittedOnceAtTheStartOfEachRun() {
        let tabs = [
            tab(0, group: nil),
            tab(1, group: "Oaxaca Trip"),
            tab(2, group: "Oaxaca Trip"),
            tab(3, group: "Swift Concurrency"),
            tab(4, group: "Swift Concurrency"),
        ]

        let items = tidyGroupedTodayItems(tabs) { _ in nil }

        let shape: [String] = items.map {
            if case .header(let name) = $0 { return "header:\(name)" }
            return "row"
        }
        XCTAssertEqual(
            shape,
            ["row", "header:Oaxaca Trip", "row", "row", "header:Swift Concurrency", "row", "row"],
            """
            Arc draws one grey label at the top of each run, and an ungrouped tab sits above \
            the first one — which is exactly where a tab opened after a tidy lands, since it \
            carries no group. `refs/reference/web/arc-max-tidy-tabs-grouped-sidebar.png`.
            """
        )
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_aTabWithNoGroupAfterAGroupEndsTheRunWithoutDrawingAnything

    func test_aTabWithNoGroupAfterAGroupEndsTheRunWithoutDrawingAnything() {
        let tabs = [tab(0, group: "Oaxaca Trip"), tab(1, group: "Oaxaca Trip"), tab(2, group: nil)]

        let items = tidyGroupedTodayItems(tabs) { _ in nil }

        XCTAssertEqual(items.count, 4, "One header and three rows.")
        guard case .header = items[0] else { return XCTFail("Expected the header first.") }
        for index in 1...3 {
            if case .header = items[index] { XCTFail("Nothing marks the end of a run — the next row simply has no header.") }
        }
    }

    // ORBIT-HOSTED-RUNNER: CANNOT-RUN test_anEmptyOrWhitespaceGroupNameDrawsNoHeader

    func test_anEmptyOrWhitespaceGroupNameDrawsNoHeader() {
        let items = tidyGroupedTodayItems([tab(0, group: "   "), tab(1, group: "")]) { _ in nil }
        for item in items {
            if case .header = item { XCTFail("A blank name is not a group and must not draw an empty grey line.") }
        }
        XCTAssertEqual(items.count, 2)
    }
}
