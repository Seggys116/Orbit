import SwiftUI
import XCTest
@testable import Orbit

// Library mode width, enter/exit and Escape handling are pure AppEnvironment state, so no window is needed.
@MainActor
final class LibraryModeTests: XCTestCase {

    private var env: AppEnvironment!

    override func setUp() {
        super.setUp()
        env = AppEnvironment.demo
        env.isSidebarVisible = true
        env.sidebarWidth = OrbitMetrics.sidebarDefaultWidth
    }

    override func tearDown() {
        env.isSidebarVisible = true
        env.sidebarWidth = OrbitMetrics.sidebarDefaultWidth
        env = nil
        super.tearDown()
    }

    // MARK: - Width resolution

    func testLibraryWidthIsAtLeast340ForEveryOrdinarySection() {
        for section in LibrarySection.allCases where section != .spaces {
            XCTAssertGreaterThanOrEqual(
                LibraryModeLayout.width(for: section, userWidth: OrbitMetrics.sidebarMinWidth), 340,
                "\(section.rawValue) must get at least 340pt even from the narrowest sidebar."
            )
        }
        XCTAssertEqual(LibraryModeLayout.baseWidth, 340)
    }

    func testSpacesNeedsMoreRoomThanAnyOtherSection() {
        let spaces = LibraryModeLayout.width(for: .spaces, userWidth: OrbitMetrics.sidebarDefaultWidth)
        for section in LibrarySection.allCases where section != .spaces {
            XCTAssertGreaterThan(
                spaces, LibraryModeLayout.width(for: section, userWidth: OrbitMetrics.sidebarDefaultWidth),
                "Spaces lays its columns out side by side and must be wider than \(section.rawValue)."
            )
        }
    }

    func testLibraryNeverNarrowsTheSidebarBelowTheUsersWidth() {
        for userWidth in stride(from: OrbitMetrics.sidebarMinWidth, through: OrbitMetrics.sidebarMaxWidth, by: 20) {
            for section in LibrarySection.allCases {
                XCTAssertGreaterThanOrEqual(
                    LibraryModeLayout.width(for: section, userWidth: userWidth), userWidth,
                    "\(section.rawValue) at a user width of \(userWidth) narrowed the sidebar."
                )
            }
        }
        XCTAssertEqual(
            LibraryModeLayout.width(for: .downloads, userWidth: 480), 480,
            "A sidebar the user made wider than the Library needs keeps its width."
        )
    }

    func testEffectiveWidthIsExactlyTheUsersWidthOutsideLibraryMode() {
        for userWidth in [OrbitMetrics.sidebarMinWidth, 237.5, OrbitMetrics.sidebarDefaultWidth, OrbitMetrics.sidebarMaxWidth] {
            for section in LibrarySection.allCases {
                XCTAssertEqual(
                    LibraryModeLayout.effectiveWidth(isLibraryMode: false, section: section, userWidth: userWidth), userWidth,
                    "Outside Library mode the sidebar must lay out at the user's own width, unchanged."
                )
            }
        }
    }

    // MARK: - Enter and exit on a window

    func testEnteringWidensTheSidebarWithoutTouchingTheUsersWidthAndExitRestoresItExactly() {
        env.sidebarWidth = 237.5
        XCTAssertEqual(env.effectiveSidebarWidth, 237.5, "precondition: Library mode starts off")

        env.openLibrary(section: .downloads)
        XCTAssertTrue(env.isLibraryMode)
        XCTAssertEqual(env.effectiveSidebarWidth, LibraryModeLayout.baseWidth)
        XCTAssertEqual(
            env.sidebarWidth, 237.5,
            "The user's width is the persisted one; Library mode must never write its temporary width into it."
        )

        env.closeLibrary()
        XCTAssertFalse(env.isLibraryMode)
        XCTAssertEqual(env.effectiveSidebarWidth, 237.5, "Exit must restore the user's exact width.")
        XCTAssertEqual(env.sidebarWidth, 237.5)
    }

    func testSwitchingToSpacesWidensFurtherAndBackNarrowsAgain() {
        env.openLibrary(section: .downloads)
        let ordinary = env.effectiveSidebarWidth

        env.openLibrary(section: .spaces)
        XCTAssertEqual(env.effectiveSidebarWidth, LibraryModeLayout.spacesWidth)
        XCTAssertGreaterThan(env.effectiveSidebarWidth, ordinary)

        env.openLibrary(section: .media)
        XCTAssertEqual(env.effectiveSidebarWidth, ordinary, "Leaving Spaces gives the extra room back.")
        XCTAssertEqual(env.sidebarWidth, OrbitMetrics.sidebarDefaultWidth)
    }

    func testEnteringWhileTheSidebarIsHiddenShowsItAndExitHidesItAgain() {
        env.isSidebarVisible = false

        env.openLibrary(section: .boosts)
        XCTAssertTrue(env.isSidebarVisible, "The Library is in the sidebar, so entering it must show a hidden sidebar.")
        XCTAssertEqual(env.libraryRouter.selectedSection, .boosts)

        env.closeLibrary()
        XCTAssertFalse(env.isSidebarVisible, "A sidebar the Library un-hid goes back to hidden on exit.")
    }

    func testExitLeavesAVisibleSidebarVisible() {
        env.isSidebarVisible = true
        env.openLibrary()
        env.closeLibrary()
        XCTAssertTrue(env.isSidebarVisible)
    }

    func testHidingTheSidebarWhileInLibraryModeLeavesLibraryModeWithoutRevealingItAgain() {
        env.isSidebarVisible = false
        env.openLibrary(section: .downloads)

        env.isSidebarVisible = false
        env.libraryModeSidebarWasHidden()

        XCTAssertFalse(env.isLibraryMode, "With the sidebar hidden there is nothing to show the Library in.")
        // The Library un-hid nothing here, so a stale flag from the first session must not hide the sidebar on exit.
        env.isSidebarVisible = true
        env.openLibrary(section: .downloads)
        env.closeLibrary()
        XCTAssertTrue(env.isSidebarVisible, "A stale 'I un-hid it' flag must not hide a sidebar the user showed.")
    }

    func testToggleClosesWhenOpenAndSwitchesSectionWhenAnotherIsAsked() {
        env.toggleLibrary()
        XCTAssertTrue(env.isLibraryMode, "The Library button opens Library mode.")

        env.toggleLibrary()
        XCTAssertFalse(env.isLibraryMode, "The Library button again closes it.")

        env.openLibrary(section: .downloads)
        env.toggleLibrary(section: .boosts)
        XCTAssertTrue(env.isLibraryMode, "Asking for another section while open switches to it, not closes.")
        XCTAssertEqual(env.libraryRouter.selectedSection, .boosts)

        env.toggleLibrary(section: .boosts)
        XCTAssertFalse(env.isLibraryMode, "The same section's command again closes the Library.")
    }

    func testExitClearsSelectionAndSearch() {
        env.openLibrary(section: .downloads)
        env.libraryRouter.select(.download(UUID()))
        env.libraryRouter.searchQuery = "report"

        env.closeLibrary()

        XCTAssertNil(env.libraryRouter.selection)
        XCTAssertEqual(env.libraryRouter.searchQuery, "")
    }

    func testEachWindowKeepsItsOwnLibraryState() {
        let other = AppEnvironment.demo
        env.openLibrary(section: .media)

        XCTAssertTrue(env.isLibraryMode)
        XCTAssertFalse(other.isLibraryMode, "Opening the Library in one window must not open it in another.")
        XCTAssertEqual(other.effectiveSidebarWidth, other.sidebarWidth)
    }

    // MARK: - Escape

    func testEscapeUnwindsSearchThenDetailThenTheLibrary() {
        func resolve(search: Bool, detail: Bool) -> LibraryEscapeAction {
            LibraryEscapeAction.resolve(isForegroundWindow: true, isOverlayPresented: false, hasSearchText: search, hasDetail: detail)
        }
        XCTAssertEqual(resolve(search: true, detail: true), .clearSearch)
        XCTAssertEqual(resolve(search: false, detail: true), .closeDetail)
        XCTAssertEqual(resolve(search: false, detail: false), .exitLibrary)
    }

    func testEscapeIsLeftAloneWhenAnotherWindowOrAnOverlayOwnsIt() {
        XCTAssertEqual(
            LibraryEscapeAction.resolve(isForegroundWindow: false, isOverlayPresented: false, hasSearchText: false, hasDetail: false),
            .ignore,
            "A background window's Library must not take Escape."
        )
        XCTAssertEqual(
            LibraryEscapeAction.resolve(isForegroundWindow: true, isOverlayPresented: true, hasSearchText: false, hasDetail: false),
            .ignore,
            "A menu, sheet or the Command Bar owns Escape while it is open."
        )
    }

    func testEscapeIsLeftAloneWhenTheFirstResponderOwnsIt() {
        XCTAssertEqual(
            LibraryEscapeAction.resolve(isForegroundWindow: true, isOverlayPresented: false, hasSearchText: true, hasDetail: true, firstResponderOwnsEscape: true),
            .ignore,
            "Focused content (a text view, a web page) keeps Escape."
        )
        XCTAssertEqual(
            LibraryEscapeAction.resolve(isForegroundWindow: true, isOverlayPresented: false, hasSearchText: false, hasDetail: false, firstResponderOwnsEscape: false),
            .exitLibrary
        )
        env.openLibrary(section: .downloads)
        XCTAssertFalse(env.handleLibraryEscape(firstResponderOwnsEscape: true))
        XCTAssertTrue(env.isLibraryMode, "Escape the first responder owns must not close the Library.")
    }

    func testHandlingEscapeExitsTheLibraryAndReportsItWasConsumed() {
        env.openLibrary(section: .downloads)

        XCTAssertFalse(env.handleLibraryEscape(isForegroundWindow: false), "A window that is not in front passes Escape on.")
        XCTAssertTrue(env.isLibraryMode)

        XCTAssertTrue(env.handleLibraryEscape(), "Escape in the front window is consumed.")
        XCTAssertFalse(env.isLibraryMode)
        XCTAssertFalse(env.handleLibraryEscape(), "With the Library closed, Escape is not ours.")
    }

    func testEscapeClearsSearchFirstAndDetailSecond() {
        env.openLibrary(section: .downloads)
        env.libraryRouter.select(.download(UUID()))
        env.libraryRouter.searchQuery = "zip"

        env.handleLibraryEscape()
        XCTAssertEqual(env.libraryRouter.searchQuery, "")
        XCTAssertNotNil(env.libraryRouter.selection)
        XCTAssertTrue(env.isLibraryMode)

        env.handleLibraryEscape()
        XCTAssertNil(env.libraryRouter.selection)
        XCTAssertTrue(env.isLibraryMode)

        env.handleLibraryEscape()
        XCTAssertFalse(env.isLibraryMode)
    }

    // MARK: - Commands reach the Library

    func testLibraryCommandsMapToTheirSections() {
        XCTAssertEqual(AppEnvironment.librarySection(for: .downloads), .downloads)
        XCTAssertEqual(AppEnvironment.librarySection(for: .archivedTabs), .archivedTabs)
        XCTAssertEqual(AppEnvironment.librarySection(for: .mediaLibrary), .media)
        XCTAssertEqual(AppEnvironment.librarySection(for: .easelsAndNotesLibrary), .easelsAndNotes)
        XCTAssertEqual(AppEnvironment.librarySection(for: .boostsLibrary), .boosts)
        XCTAssertNil(AppEnvironment.librarySection(for: .library), "View Library has no section of its own: it opens at the last one.")
    }

    func testPerformingALibraryCommandOpensTheLibraryInThatEnvironmentAndAgainCloses() {
        env.perform(.downloads)
        XCTAssertTrue(env.isLibraryMode)
        XCTAssertEqual(env.libraryRouter.selectedSection, .downloads)

        env.perform(.downloads)
        XCTAssertFalse(env.isLibraryMode)

        env.perform(.library)
        XCTAssertTrue(env.isLibraryMode, "View Library opens Library mode at the last section.")
    }

    // MARK: - Flyout "Show all downloads"

    func testShowAllDownloadsOpensLibraryModeAtDownloads() {
        env.openLibrary(section: .media)
        env.openLibrary(section: .downloads)
        XCTAssertEqual(env.libraryRouter.selectedSection, .downloads)
        XCTAssertTrue(env.isLibraryMode)
    }
}
