//  A preview that opens beside a sidebar row lands over the page. While a button is held or a drag from the sidebar is running it
//  must not open, and one already open must close when a drag begins, or the drop lands on the preview and no split opens.

import AppKit
import XCTest
@testable import Orbit

@MainActor
final class SidebarHoverPreviewGateTests: XCTestCase {

    private var savedButton: (() -> Bool)!

    override func setUp() {
        super.setUp()
        savedButton = SidebarHoverPreviewGate.primaryButtonIsDown
        SidebarDragSession.discardStaleRecord()
    }

    override func tearDown() {
        SidebarHoverPreviewGate.primaryButtonIsDown = savedButton
        SidebarDragSession.discardStaleRecord()
        super.tearDown()
    }

    private func payload() -> SidebarDragPayload {
        SidebarDragPayload(nodeID: UUID(), kind: .todayTab, spaceID: UUID())
    }

    func test_aPreviewMayOpen_whenNothingIsPressedAndNoDragIsRunning() {
        SidebarHoverPreviewGate.primaryButtonIsDown = { false }
        XCTAssertTrue(SidebarHoverPreviewGate.mayOpen)
    }

    func test_aPreviewMayNotOpen_whileTheButtonIsHeld() {
        SidebarHoverPreviewGate.primaryButtonIsDown = { true }
        XCTAssertFalse(SidebarHoverPreviewGate.mayOpen)
    }

    func test_aPreviewMayNotOpen_whileADragFromTheSidebarIsRunning() {
        SidebarHoverPreviewGate.primaryButtonIsDown = { false }
        SidebarDragSession.begin(payload())
        XCTAssertFalse(SidebarHoverPreviewGate.mayOpen)
        SidebarDragSession.end()
        XCTAssertTrue(SidebarHoverPreviewGate.mayOpen, "the gate stays shut after the drag is over")
    }

    func test_beginningADragTellsOpenPreviewsToClose() {
        var heard = 0
        let token = NotificationCenter.default.addObserver(forName: .orbitSidebarDragBegan, object: nil, queue: nil) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        SidebarDragSession.begin(payload())
        SidebarDragSession.end()
        XCTAssertEqual(heard, 1)
    }
}
