import AppKit
import XCTest
@testable import Orbit

final class LinkPreviewHoverMonitorTests: XCTestCase {

    // MARK: - The pure decision

    func test_isShiftDown_trueWhenShiftIsAmongTheFlags() {
        XCTAssertTrue(LinkPreviewHoverMonitor.isShiftDown(in: [.shift]))
        XCTAssertTrue(LinkPreviewHoverMonitor.isShiftDown(in: [.shift, .command]))
    }

    func test_isShiftDown_falseWithoutShift() {
        XCTAssertFalse(LinkPreviewHoverMonitor.isShiftDown(in: []))
        XCTAssertFalse(LinkPreviewHoverMonitor.isShiftDown(in: [.command, .option]))
    }

    // MARK: - Install/teardown

    @MainActor
    func test_start_installsTheMonitorExactlyOnce() {
        let monitor = LinkPreviewHoverMonitor()
        XCTAssertFalse(monitor.isMonitoring, "A freshly constructed monitor must not already be installed")

        monitor.start()
        XCTAssertTrue(monitor.isMonitoring)

        monitor.start()
        XCTAssertTrue(monitor.isMonitoring)

        monitor.stop()
    }

    @MainActor
    func test_stop_removesTheMonitorAndResetsShiftState() {
        let monitor = LinkPreviewHoverMonitor()
        monitor.start()
        XCTAssertTrue(monitor.isMonitoring)

        monitor.stop()
        XCTAssertFalse(monitor.isMonitoring)
    }

    @MainActor
    func test_stop_beforeEverStarting_isANoOp() {
        let monitor = LinkPreviewHoverMonitor()
        monitor.stop()
        XCTAssertFalse(monitor.isMonitoring)
    }
}
