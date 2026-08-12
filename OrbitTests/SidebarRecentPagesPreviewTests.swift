import Foundation
import SwiftUI
import XCTest

// MARK: - Recorded source

private final class RecordedSidebarSource: @unchecked Sendable {
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

// MARK: - The gate

@MainActor
final class SidebarRecentPagesPreviewGateTests: XCTestCase {

    private let space = SpaceID()

    private func tab(_ urlString: String, section: TabSection) -> Tab {
        Tab(spaceID: space, section: section, url: URL(string: urlString)!)
    }

    func test_service_isOfferedOnPinnedAndFavoritedRowsOnly() {
        let notion = "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"
        XCTAssertEqual(SidebarRecentPagesPreviewController.service(for: tab(notion, section: .pinned)), .notion)
        XCTAssertEqual(SidebarRecentPagesPreviewController.service(for: tab(notion, section: .favorite)), .notion)
        XCTAssertNil(
            SidebarRecentPagesPreviewController.service(for: tab(notion, section: .today)),
            "Arc's Previews copy names Folder, Pinned and Favorited rows — not Today rows"
        )
        XCTAssertNil(SidebarRecentPagesPreviewController.service(for: tab(notion, section: .archived)))
    }

    func test_service_recognisesEachOfTheFourServicesOnAPinnedRow() {
        let cases: [(String, RecentPagesService)] = [
            ("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", .notion),
            ("https://www.figma.com/design/AbC123/Site", .figma),
            ("https://linear.app/orbit/issue/ENG-42/fix", .linear),
            ("https://orbit.atlassian.net/wiki/spaces/ENG/pages/12345/Runbook", .confluence),
        ]
        for (urlString, expected) in cases {
            XCTAssertEqual(
                SidebarRecentPagesPreviewController.service(for: tab(urlString, section: .pinned)),
                expected,
                "\(urlString)"
            )
        }
    }

    func test_service_isNilForAnOrdinaryPinnedRow() {
        XCTAssertNil(SidebarRecentPagesPreviewController.service(for: tab("https://example.com/docs", section: .pinned)))
        XCTAssertNil(
            SidebarRecentPagesPreviewController.service(for: tab("https://example.com/?ref=notion.so", section: .pinned)),
            "A URL that merely mentions a service is not that service — see RecentPagesService.matches(_:)"
        )
    }
}

// MARK: - The controller

@MainActor
final class SidebarRecentPagesPreviewControllerTests: XCTestCase {

    private let space = SpaceID()
    private let profile = ProfileID()

    private var notionTab: Tab {
        Tab(
            spaceID: space,
            section: .pinned,
            url: URL(string: "https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")!
        )
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

    private func controller() -> SidebarRecentPagesPreviewController {
        let controller = SidebarRecentPagesPreviewController()
        controller.hoverDelayNanoseconds = 0
        controller.dismissGraceNanoseconds = 30_000_000
        return controller
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func test_hoveringAPinnedNotionRow_buildsTheCardFromLocalHistory() async {
        let controller = controller()
        let recorded = RecordedSidebarSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]

        controller.hoverChanged(hovering: true, tab: notionTab, isSpacePersistent: true, source: recorded.source)
        await waitUntil { controller.data != nil }

        XCTAssertEqual(controller.data?.service, .notion)
        XCTAssertEqual(controller.data?.items.map(\.displayTitle), ["Weekly Plan"])
        XCTAssertEqual(recorded.requestedServices, [.notion])
    }

    func test_hoveringAPinnedNotionRowInAnIncognitoSpace_neverReadsHistoryAtAll() async {
        let controller = controller()
        let recorded = RecordedSidebarSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]

        controller.hoverChanged(hovering: true, tab: notionTab, isSpacePersistent: false, source: recorded.source)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(controller.data)
        XCTAssertEqual(recorded.callCount, 0, "An Incognito Space must not read the user's browsing history for a card")
    }

    func test_hoveringATodayRow_neverReadsHistoryAtAll() async {
        let controller = controller()
        let recorded = RecordedSidebarSource()
        let today = Tab(spaceID: space, section: .today, url: notionTab.url)

        controller.hoverChanged(hovering: true, tab: today, isSpacePersistent: true, source: recorded.source)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(controller.data)
        XCTAssertEqual(recorded.callCount, 0)
    }

    func test_hoveringAnOrdinaryPinnedRow_neverReadsHistoryAtAll() async {
        let controller = controller()
        let recorded = RecordedSidebarSource()
        let ordinary = Tab(spaceID: space, section: .pinned, url: URL(string: "https://example.com/docs")!)

        controller.hoverChanged(hovering: true, tab: ordinary, isSpacePersistent: true, source: recorded.source)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(controller.data)
        XCTAssertEqual(recorded.callCount, 0, "An ordinary pinned tab must not open the history database")
    }

    func test_withNoMatchingHistory_showsNoCardRatherThanAnEmptyOne() async {
        let controller = controller()
        let recorded = RecordedSidebarSource()
        recorded.entries = []

        controller.hoverChanged(hovering: true, tab: notionTab, isSpacePersistent: true, source: recorded.source)
        await waitUntil { recorded.callCount > 0 }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(controller.data)
        XCTAssertEqual(recorded.callCount, 1, "It must actually have looked before concluding there was nothing")
    }

    func test_theExclusionSetIsHandedToTheSource() async {
        let controller = controller()
        let recorded = RecordedSidebarSource()
        let incognito = SpaceID()

        controller.hoverChanged(
            hovering: true,
            tab: notionTab,
            isSpacePersistent: true,
            source: recorded.source,
            query: RecentPagesQuery(excludedSpaceIDs: [incognito])
        )
        await waitUntil { recorded.callCount > 0 }

        XCTAssertEqual(recorded.requestedQueries.first?.excludedSpaceIDs, [incognito])
    }

    // MARK: The hover hand-off

    func test_thePointerReachingTheCardWithinTheGrace_keepsTheCard() async {
        let controller = controller()
        controller.dismissGraceNanoseconds = 400_000_000
        let recorded = RecordedSidebarSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]

        controller.hoverChanged(hovering: true, tab: notionTab, isSpacePersistent: true, source: recorded.source)
        await waitUntil { controller.data != nil }

        controller.hoverChanged(hovering: false, tab: notionTab, isSpacePersistent: true, source: recorded.source)
        try? await Task.sleep(nanoseconds: 40_000_000)
        controller.hoverChanged(hovering: true, tab: notionTab, isSpacePersistent: true, source: recorded.source)

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotNil(controller.data, "The card must survive the trip from the row to the card, or it is unclickable")
        XCTAssertEqual(recorded.callCount, 1, "Returning to a card that is already showing must not re-read history")
    }

    func test_thePointerLeavingAndNotComingBack_clearsTheCard() async {
        let controller = controller()
        let recorded = RecordedSidebarSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]

        controller.hoverChanged(hovering: true, tab: notionTab, isSpacePersistent: true, source: recorded.source)
        await waitUntil { controller.data != nil }

        controller.hoverChanged(hovering: false, tab: notionTab, isSpacePersistent: true, source: recorded.source)
        await waitUntil { controller.data == nil }
        XCTAssertNil(controller.data)
    }

    func test_leavingBeforeTheCardArrives_discardsTheLoadEntirely() async {
        let controller = SidebarRecentPagesPreviewController()
        controller.hoverDelayNanoseconds = 80_000_000
        let recorded = RecordedSidebarSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]

        controller.hoverChanged(hovering: true, tab: notionTab, isSpacePersistent: true, source: recorded.source)
        controller.hoverChanged(hovering: false, tab: notionTab, isSpacePersistent: true, source: recorded.source)

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(controller.data, "A card built for a row the pointer has already left must never appear")
    }

    func test_dismissClearsTheCardImmediately() async {
        let controller = controller()
        let recorded = RecordedSidebarSource()
        recorded.entries = [entry("https://www.notion.so/team/Plan-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", title: "Weekly Plan")]

        controller.hoverChanged(hovering: true, tab: notionTab, isSpacePersistent: true, source: recorded.source)
        await waitUntil { controller.data != nil }

        controller.dismiss()
        XCTAssertNil(controller.data)
    }
}

// MARK: - The "+" button's destination

final class RecentPagesNewDocumentTests: XCTestCase {

    func test_theCreateURLsAreTheOnesThatWereSourced() {
        XCTAssertEqual(RecentPagesNewDocument.url(for: .figma)?.absoluteString, "https://www.figma.com/new")
        XCTAssertEqual(RecentPagesNewDocument.url(for: .linear)?.absoluteString, "https://linear.app/new")
        XCTAssertEqual(RecentPagesNewDocument.url(for: .notion)?.absoluteString, "https://www.notion.so/new")
    }

    func test_confluenceHasNoCreateURLAndThereforeNoPlusButton() {
        XCTAssertNil(RecentPagesNewDocument.url(for: .confluence))
    }

    func test_everyCreateURLIsAnOrdinaryHTTPSPageNotAnAPICall() {
        for service in RecentPagesService.allCases {
            guard let url = RecentPagesNewDocument.url(for: service) else { continue }
            XCTAssertEqual(url.scheme, "https", "\(service)")
            XCTAssertNil(url.query, "\(service): a create-URL with a query string is an API call in disguise")
            XCTAssertFalse(url.path.contains("/api/"), "\(service)")
        }
    }
}

// MARK: - The card actually draws

@MainActor
final class SidebarRecentPagesPreviewRenderTests: XCTestCase {

    private func item(_ title: String, _ urlString: String) -> RecentPagesItem {
        RecentPagesItem(
            url: URL(string: urlString)!,
            title: title,
            tidyTitle: title,
            lastVisitDate: Date().addingTimeInterval(-600),
            documentID: nil
        )
    }

    func test_theListDrawsARowPerItem() {
        let one = render(
            SidebarRecentPagesPreviewList(items: [item("Weekly Plan", "https://www.notion.so/a")], onOpen: { _ in }),
            size: CGSize(width: OrbitMetrics.folderPreviewWidth, height: 200)
        )
        let three = render(
            SidebarRecentPagesPreviewList(
                items: [
                    item("Weekly Plan", "https://www.notion.so/a"),
                    item("Roadmap", "https://www.notion.so/b"),
                    item("Retro Notes", "https://www.notion.so/c"),
                ],
                onOpen: { _ in }
            ),
            size: CGSize(width: OrbitMetrics.folderPreviewWidth, height: 200)
        )

        guard let oneBox = one.boundingBoxOfContent(), let threeBox = three.boundingBoxOfContent() else {
            return XCTFail("The recent-pages list drew nothing at all")
        }
        XCTAssertGreaterThan(
            threeBox.height, oneBox.height,
            "Three rows must occupy more vertical space than one — otherwise the list is not rendering its items"
        )
    }
}

// MARK: - It is actually reached

final class SidebarRecentPagesPreviewWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrbitTests/
            .deletingLastPathComponent()   // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_theSidebarRowActuallyAttachesThePreview() throws {
        let row = try source("Orbit/UI/Sidebar/TabRowView.swift")
        XCTAssertTrue(
            row.contains(".sidebarRecentPagesPreview(tab: tab)"),
            "TabRowView must attach the recent-pages preview, or hovering a Pinned Notion row does nothing"
        )
    }

    func test_theRecentPagesCardTakesPrecedenceOverTheThumbnailPreview() throws {
        let row = try source("Orbit/UI/Sidebar/TabRowView.swift")
        XCTAssertTrue(
            row.contains("SidebarRecentPagesPreviewController.service(for: tab) == nil"),
            "TabRowView's thumbnail preview must stand down on a row that has a recent-pages card"
        )
    }

    func test_theModifierResolvesALiveSourceAndExcludesIncognito() throws {
        let view = try source("Orbit/Features/RecentPages/SidebarRecentPagesPreviewView.swift")
        XCTAssertTrue(
            view.contains("RecentPagesHistoryConnection.source()"),
            "Without a live source every hover would see `.unavailable` and no card could ever be built"
        )
        XCTAssertTrue(
            view.contains("incognitoSpaceIDs()"),
            "The modifier must compute the Incognito exclusion set rather than passing an empty one"
        )
        XCTAssertTrue(
            view.contains("isSpacePersistent: isSpacePersistent"),
            "The hovered row's own Space must be checked, or an Incognito row would read history"
        )
    }

    func test_theCardIsInteractive() throws {
        let view = try source("Orbit/Features/RecentPages/SidebarRecentPagesPreviewView.swift")
        XCTAssertTrue(
            view.contains("onTapGesture { onOpen(item.url) }"),
            "Each row must open its page, or the list is decorative"
        )
        XCTAssertTrue(
            view.contains("RecentPagesNewDocument.url(for: data.service)"),
            "The `+` must resolve its destination from the sourced table, not from an invented endpoint"
        )
        XCTAssertTrue(
            view.contains("env.openTab(url: url, in: tab.spaceID)"),
            "Opening a row must actually open a tab"
        )
    }

    func test_theContentAreaOverlayIsStillNotHitTestable() throws {
        let overlay = try source("Orbit/Features/Assist/LinkPreviewOverlayView.swift")
        XCTAssertTrue(
            overlay.contains(".allowsHitTesting(false)"),
            "The in-page preview overlay must never steal a click or a hover from the page underneath it"
        )
    }
}
