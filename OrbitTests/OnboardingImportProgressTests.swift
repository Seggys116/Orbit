import XCTest

// ImportProgress.swift is compiled into the test bundle (see ORBIT_TESTS_REUSED_SOURCES).

final class OnboardingImportProgressTests: XCTestCase {

    private func progress(_ events: [ImportProgressEvent]) -> ImportProgress {
        var value = ImportProgress()
        for event in events { value.apply(event) }
        return value
    }

    func test_nothingPlanned_readsZero() {
        let value = ImportProgress()
        XCTAssertTrue(value.isEmpty)
        XCTAssertEqual(value.overallFraction, 0)
        XCTAssertFalse(value.isFinished, "an empty import is not a finished one")
    }

    func test_plannedItems_startAtZero() {
        let value = progress([.planned(.history, total: 100), .planned(.tabs, total: 10)])

        XCTAssertEqual(value.items.map(\.kind), [.history, .tabs], "items keep the order they were announced in")
        XCTAssertEqual(value.overallFraction, 0)
    }

    func test_overall_isWeightedByItemKind() {
        // History weighs 4 and tabs 2, so half of history is 2 of 6 and a finished tabs item adds 2 more.
        var value = progress([.planned(.history, total: 100), .planned(.tabs, total: 10)])

        value.apply(.advanced(.history, completed: 50))
        XCTAssertEqual(value.overallFraction, 2.0 / 6.0, accuracy: 1e-12)

        value.apply(.finished(.tabs, completed: 10))
        XCTAssertEqual(value.overallFraction, 4.0 / 6.0, accuracy: 1e-12)

        value.apply(.finished(.history, completed: 100))
        XCTAssertEqual(value.overallFraction, 1, accuracy: 1e-12)
        XCTAssertTrue(value.isFinished)
    }

    func test_advance_neverMovesBackwards() {
        var value = progress([.planned(.history, total: 100), .advanced(.history, completed: 60)])

        value.apply(.advanced(.history, completed: 20))

        XCTAssertEqual(value.item(.history)?.completed, 60)
        XCTAssertEqual(value.item(.history)?.fraction ?? 0, 0.6, accuracy: 1e-12)
    }

    func test_finished_countsAsWholeEvenWhenFewerLanded() {
        let value = progress([.planned(.history, total: 100), .finished(.history, completed: 93)])

        let item = value.item(.history)
        XCTAssertEqual(item?.fraction, 1, "rejected visits must not leave the bar short of done")
        XCTAssertEqual(item?.completed, 93, "the count still reports what actually landed")
    }

    func test_unknownTotal_readsZeroUntilFinished() {
        var value = progress([.planned(.sessions, total: nil), .advanced(.sessions, completed: 5)])
        XCTAssertEqual(value.item(.sessions)?.fraction, 0)

        value.apply(.finished(.sessions, completed: 12))
        XCTAssertEqual(value.item(.sessions)?.fraction, 1)
        XCTAssertEqual(value.item(.sessions)?.completed, 12)
    }

    func test_zeroTotal_doesNotDivideByZero() {
        var value = progress([.planned(.extensions, total: 0)])
        XCTAssertEqual(value.item(.extensions)?.fraction, 0)

        value.apply(.finished(.extensions, completed: 0))
        XCTAssertEqual(value.item(.extensions)?.fraction, 1)
    }

    func test_completedBeyondTotal_clampsTheFraction() {
        let value = progress([.planned(.tabs, total: 10), .advanced(.tabs, completed: 14)])
        XCTAssertEqual(value.item(.tabs)?.fraction, 1)
        XCTAssertLessThanOrEqual(value.overallFraction, 1)
    }

    func test_reportForAnUnplannedItem_createsIt() {
        let value = progress([.advanced(.bookmarks, completed: 3)])

        XCTAssertEqual(value.item(.bookmarks)?.completed, 3)
        XCTAssertNil(value.item(.bookmarks)?.total)
    }

    func test_replanning_updatesTheTotalWithoutLosingProgress() {
        var value = progress([.planned(.history, total: 50), .advanced(.history, completed: 25)])

        value.apply(.planned(.history, total: 100))

        XCTAssertEqual(value.items.count, 1)
        XCTAssertEqual(value.item(.history)?.completed, 25)
        XCTAssertEqual(value.item(.history)?.fraction ?? 0, 0.25, accuracy: 1e-12)
    }

    func test_finishAll_marksEveryAnnouncedItemDone() {
        var value = progress([.planned(.history, total: 100), .planned(.tabs, total: 10)])

        value.finishAll()

        XCTAssertTrue(value.isFinished)
        XCTAssertEqual(value.overallFraction, 1, accuracy: 1e-12)
    }

    func test_overall_isMonotonicAcrossARealisticRun() {
        var value = ImportProgress()
        var previous = 0.0
        let events: [ImportProgressEvent] = [
            .planned(.spaces, total: 3), .planned(.tabs, total: 40), .planned(.history, total: 500),
            .finished(.spaces, completed: 3), .finished(.tabs, completed: 40),
            .advanced(.history, completed: 50), .advanced(.history, completed: 250),
            .advanced(.history, completed: 100), .advanced(.history, completed: 500),
            .finished(.history, completed: 497),
        ]
        for event in events {
            value.apply(event)
            XCTAssertGreaterThanOrEqual(value.overallFraction, previous, "\(event) moved the overall bar backwards")
            previous = value.overallFraction
        }
        XCTAssertEqual(value.overallFraction, 1, accuracy: 1e-12)
    }

    func test_itemTitles_areSentenceCase() {
        for kind in ImportItemKind.allCases {
            XCTAssertNotEqual(kind.title, kind.title.uppercased(), "\(kind) title is all caps")
        }
    }
}
