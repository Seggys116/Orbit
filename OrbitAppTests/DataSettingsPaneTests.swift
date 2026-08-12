import AppKit
import SwiftUI
import XCTest
@testable import Orbit

@MainActor
final class DataSettingsPaneTests: XCTestCase {

    private lazy var env: AppEnvironment = AppEnvironment.demo

    // MARK: - Pane registration

    func testDataPaneIsTheSecondPaneAndCarriesItsOwnUnusedSymbol() {
        XCTAssertEqual(SettingsPane.allCases.map(\.id).firstIndex(of: SettingsPane.data.id), 1)
        XCTAssertEqual(SettingsPane.data.title, "Data")
        XCTAssertEqual(SettingsPane.data.symbolName, "internaldrive")

        let others = SettingsPane.allCases.filter { $0 != .data }
        XCTAssertFalse(others.map(\.symbolName).contains(SettingsPane.data.symbolName))
        XCTAssertFalse(others.map(\.title).contains(SettingsPane.data.title))
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsPane.data.symbolName, accessibilityDescription: nil))
    }

    // MARK: - Selection and enablement

    func testRemoveSelectedIsDisabledUntilSomethingIsSelected() throws {
        let model = DataSettingsModel()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.canRemoveSelected)
        XCTAssertTrue(model.canResetEverything)

        let first = try XCTUnwrap(DataResetCategory.allCases.first)
        model.setSelected(first, true)
        XCTAssertTrue(model.isSelected(first))
        XCTAssertTrue(model.canRemoveSelected)

        model.setSelected(first, false)
        XCTAssertFalse(model.isSelected(first))
        XCTAssertFalse(model.canRemoveSelected)
    }

    func testOrderedTitlesFollowAllCasesOrderNotSetIterationOrder() throws {
        let categories = Set(DataResetCategory.allCases)
        XCTAssertEqual(DataSettingsModel.orderedTitles(categories), DataResetCategory.allCases.map(\.title))

        let last = try XCTUnwrap(DataResetCategory.allCases.last)
        let first = try XCTUnwrap(DataResetCategory.allCases.first)
        XCTAssertEqual(DataSettingsModel.orderedTitles([last, first]), [first.title, last.title])
    }

    func testSentenceListJoinsWithCommasAndATrailingAnd() {
        XCTAssertEqual(DataSettingsModel.sentenceList([]), "")
        XCTAssertEqual(DataSettingsModel.sentenceList(["History"]), "History")
        XCTAssertEqual(DataSettingsModel.sentenceList(["History", "Cache"]), "History and Cache")
        XCTAssertEqual(DataSettingsModel.sentenceList(["History", "Cache", "Downloads"]), "History, Cache and Downloads")
    }

    // MARK: - Confirmation wording

    func testSelectionConfirmationNamesExactlyWhatWillBeRemoved() throws {
        let selected = Set(DataResetCategory.allCases.prefix(3))
        XCTAssertEqual(selected.count, 3, "This suite assumes at least three reset categories exist.")
        let message = DataSettingsModel.selectionConfirmationMessage(selected)

        for category in selected {
            XCTAssertTrue(message.contains(category.title), "\(category.title) is selected but the confirmation never names it: \(message)")
        }
        let selectedTitles = selected.map(\.title)
        for category in DataResetCategory.allCases where !selected.contains(category) {
            guard !selectedTitles.contains(where: { $0.contains(category.title) }) else { continue }
            XCTAssertFalse(message.contains(category.title), "\(category.title) is not selected but the confirmation names it: \(message)")
        }
        XCTAssertTrue(message.contains("cannot be undone"))

        XCTAssertEqual(DataSettingsModel.selectionConfirmationTitle(Set(selected.prefix(1))), "Remove this data?")
        XCTAssertTrue(DataSettingsModel.selectionConfirmationTitle(selected).contains("3"))
    }

    func testConfirmationMentionsRestartOnlyWhenACategoryNeedsOne() throws {
        let needsRelaunch = try XCTUnwrap(
            DataResetCategory.allCases.first(where: \.requiresRelaunch),
            "No reset category reports requiresRelaunch — the relaunch follow-up is unreachable."
        )
        let doesNotNeedRelaunch = try XCTUnwrap(
            DataResetCategory.allCases.first(where: { !$0.requiresRelaunch }),
            "Every reset category reports requiresRelaunch — the non-relaunch wording is unreachable."
        )
        XCTAssertTrue(DataSettingsModel.selectionConfirmationMessage([needsRelaunch]).contains("restart"))
        XCTAssertFalse(DataSettingsModel.selectionConfirmationMessage([doesNotNeedRelaunch]).contains("restart"))
    }

    func testResetEverythingConfirmationNamesEveryCategoryAndTheRestart() {
        let message = DataSettingsModel.everythingConfirmationMessage
        for category in DataResetCategory.allCases {
            XCTAssertTrue(message.contains(category.title), "Reset-everything confirmation never names \(category.title): \(message)")
        }
        XCTAssertTrue(message.contains("cannot be undone"))
        XCTAssertTrue(message.contains("restart"))
        XCTAssertEqual(DataSettingsModel.everythingConfirmationTitle, "Reset Orbit to a fresh install?")
    }

    // MARK: - Outcome reporting

    func testOutcomeReportsFailuresRatherThanClaimingSuccess() throws {
        XCTAssertGreaterThanOrEqual(DataResetCategory.allCases.count, 2)
        let cleared = try XCTUnwrap(DataResetCategory.allCases.first)
        let failed = try XCTUnwrap(DataResetCategory.allCases.last)
        XCTAssertNotEqual(cleared, failed)

        let partial = DataResetOutcome(clearedCategories: [cleared], failedCategories: [failed], needsRelaunch: false)
        XCTAssertEqual(DataSettingsModel.outcomeTitle(partial), "Some data could not be removed")
        let partialMessage = DataSettingsModel.outcomeMessage(partial)
        XCTAssertTrue(partialMessage.contains("Could not remove"))
        XCTAssertTrue(partialMessage.contains(failed.title))

        let allFailed = DataResetOutcome(clearedCategories: [], failedCategories: [failed], needsRelaunch: false)
        XCTAssertEqual(DataSettingsModel.outcomeTitle(allFailed), "Nothing could be removed")
        XCTAssertFalse(DataSettingsModel.outcomeMessage(allFailed).contains("Removed "))

        let succeeded = DataResetOutcome(clearedCategories: [cleared], failedCategories: [], needsRelaunch: false)
        XCTAssertEqual(DataSettingsModel.outcomeTitle(succeeded), "Data removed")
        XCTAssertFalse(DataSettingsModel.outcomeMessage(succeeded).contains("Could not remove"))

        let nothing = DataResetOutcome(clearedCategories: [], failedCategories: [], needsRelaunch: false)
        XCTAssertEqual(DataSettingsModel.outcomeTitle(nothing), "Nothing was removed")
        XCTAssertTrue(DataSettingsModel.outcomeMessage(nothing).contains("nothing changed"))
    }

    func testRelaunchPromptsSettleThemselvesUnderATestRun() {
        XCTAssertTrue(DebugFlags.isRunningUnderTests, "This suite is running without XCTestConfigurationFilePath set, so the modal guards it checks are not in force.")
        XCTAssertFalse(DataResetPrompt.confirmRelaunch(title: DataSettingsModel.relaunchTitle, message: DataSettingsModel.relaunchMessage))
        DataResetPrompt.report(title: "Data removed", message: "Removed History.")
    }

    // MARK: - Render

    func testPaneRendersEveryCategoryRowAndTheImportSection() {
        let size = CGSize(width: SettingsMetrics.contentMaxWidth, height: 1400)
        let rendered = render(DataSettingsPane().environment(env), size: size)
        let content = rendered.boundingBoxOfContent()
        XCTAssertNotNil(content, "DataSettingsPane rendered nothing — the pane is not renderable off-screen.")
        XCTAssertGreaterThan(
            content?.height ?? 0, 400,
            "DataSettingsPane painted only \(content?.height ?? 0)pt of content — its four sections and \(DataResetCategory.allCases.count) category rows are not all laying out."
        )
    }
}
