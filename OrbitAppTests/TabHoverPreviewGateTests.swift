import XCTest
@testable import Orbit

@MainActor
final class TabHoverPreviewGateTests: XCTestCase {

    func test_everyRowWithALivePageMayAttemptAPreview() {
        for section in [TabSection.pinned, .favorite, .today] {
            XCTAssertTrue(
                TabRowView.shouldAttemptHoverPreview(section: section),
                "A \(section.rawValue) row refuses to even attempt a preview. Requiring a capability here is what made this feature dead app-wide."
            )
        }
    }

    func test_archivedRowsDoNotAttemptAPreview() {
        XCTAssertFalse(TabRowView.shouldAttemptHoverPreview(section: .archived))
    }

    func test_thePopoverIsOnlyPresentedOnceARealImageExists() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Orbit/UI/Sidebar/TabRowView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("guard !Task.isCancelled, let image else { return }"),
            "handleHoverPreview must refuse to present without an image; without it, opening the section gate would show a spinner that never resolves on any tab Chromium cannot capture."
        )
        XCTAssertTrue(
            source.contains("2_500_000_000"),
            "The capture must be bounded. capturePreview awaits a DevTools round trip a surfaceless renderer can simply never answer, and hovering down a list would otherwise leave one suspended task per row."
        )
    }
}
