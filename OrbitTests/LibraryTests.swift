import XCTest
import SwiftUI

// MARK: - Tests

final class LibraryTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    // MARK: Date-group titles

    func test_dateGroupTitle_sameDayIsToday() {
        let now = Date()
        XCTAssertEqual(LibraryDateGrouping.title(for: now, calendar: calendar, now: now), "Today")
    }

    func test_dateGroupTitle_oneDayBackIsYesterday() {
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(LibraryDateGrouping.title(for: yesterday, calendar: calendar, now: now), "Yesterday")
    }

    func test_dateGroupTitle_withinPastWeekIsAWeekdayName() {
        let now = Date()
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        let title = LibraryDateGrouping.title(for: threeDaysAgo, calendar: calendar, now: now)
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        XCTAssertEqual(title, weekdayFormatter.string(from: threeDaysAgo))
        XCTAssertNotEqual(title, "Today")
        XCTAssertNotEqual(title, "Yesterday")
    }

    func test_dateGroupTitle_overAWeekAgoIsAFullDate() {
        let now = Date()
        let threeWeeksAgo = calendar.date(byAdding: .day, value: -21, to: now)!
        let title = LibraryDateGrouping.title(for: threeWeeksAgo, calendar: calendar, now: now)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d"
        XCTAssertEqual(title, dateFormatter.string(from: threeWeeksAgo))
    }

    func test_dateGroupTitle_previousYearIncludesTheYear() {
        let now = Date()
        let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
        let title = LibraryDateGrouping.title(for: lastYear, calendar: calendar, now: now)
        XCTAssertTrue(title.contains(String(calendar.component(.year, from: lastYear))))
    }

    // MARK: Grouping order, against the real `DownloadItem` model

    func test_group_ordersNewestGroupFirstAndNewestItemFirstWithinAGroup() {
        // A fixed noon anchor, not Date(): anchoring on the real clock made
        // this test fail deterministically whenever the suite ran near local midnight.
        let now = Self.fixedNoon
        let today1 = makeDownload(startedAt: now.addingTimeInterval(-60))
        let today2 = makeDownload(startedAt: now.addingTimeInterval(-3600))
        let yesterday = makeDownload(startedAt: calendar.date(byAdding: .day, value: -1, to: now)!)

        let groups = LibraryDateGrouping.group([yesterday, today2, today1], now: now, date: \.startedAt)

        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(groups[0].items.map(\.id), [today1.id, today2.id], "newest download in the Today bucket must render first")
        XCTAssertEqual(groups[1].items.map(\.id), [yesterday.id])
    }

    // MARK: Grouping order, against the real `Tab` model (Archived Tabs)

    func test_group_bucketsArchivedTabsByArchivedDate() {
        let now = Date()
        let spaceID = SpaceID()
        let recentlyArchived = makeTab(spaceID: spaceID, archivedAt: now.addingTimeInterval(-120))
        let olderArchive = makeTab(spaceID: spaceID, archivedAt: calendar.date(byAdding: .day, value: -10, to: now)!)

        let groups = LibraryDateGrouping.group(
            [olderArchive, recentlyArchived],
            now: now,
            date: { $0.archivedAt ?? $0.lastAccessedAt }
        )

        XCTAssertEqual(groups.first?.items.first?.id, recentlyArchived.id, "most recently archived tab must sort into the newest bucket first")
        XCTAssertEqual(groups.count, 2)
    }

    // MARK: Palette fidelity — `refs/ARC_VISUAL_REFERENCE.md` §2 measured hex values

    func test_libraryPalette_sidebarBackground_matchesMeasuredArcHex() {
        // #2A2532
        let components = LibraryPalette.sidebarBackground.srgbComponents
        XCTAssertEqual(components.red, (0x2A).u8Fraction, accuracy: 0.01)
        XCTAssertEqual(components.green, (0x25).u8Fraction, accuracy: 0.01)
        XCTAssertEqual(components.blue, (0x32).u8Fraction, accuracy: 0.01)
    }

    func test_libraryPalette_contentBackground_matchesMeasuredArcHex() {
        // #332C3A
        let components = LibraryPalette.contentBackground.srgbComponents
        XCTAssertEqual(components.red, (0x33).u8Fraction, accuracy: 0.01)
        XCTAssertEqual(components.green, (0x2C).u8Fraction, accuracy: 0.01)
        XCTAssertEqual(components.blue, (0x3A).u8Fraction, accuracy: 0.01)
    }

    func test_libraryPalette_contentIsSlightlyLighterThanSidebar() {
        let sidebarLuma = LibraryPalette.sidebarBackground.approximateLuminance
        let contentLuma = LibraryPalette.contentBackground.approximateLuminance
        XCTAssertGreaterThan(contentLuma, sidebarLuma)
    }

    // MARK: - Fixtures

    private static let fixedNoon: Date = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12, minute: 0, second: 0))!

    private func makeDownload(startedAt: Date) -> DownloadItem {
        DownloadItem(
            sourceURL: URL(string: "https://example.com/file.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file-\(UUID().uuidString).zip"),
            suggestedFileName: "file.zip",
            startedAt: startedAt
        )
    }

    private func makeTab(spaceID: SpaceID, archivedAt: Date) -> Tab {
        Tab(
            spaceID: spaceID,
            section: .archived,
            url: URL(string: "https://example.com")!,
            archivedAt: archivedAt
        )
    }
}

private extension Int {
    /// `0xNN` treated as an 8-bit sRGB channel, as the `0...1` fraction `ThemeColor`/`Color` store.
    var u8Fraction: Double { Double(self) / 255.0 }
}
