//  Cancel must leave the panel idle. A cancelled run keeps going until it next checks for the cancel, and every step it passes on
//  the way used to put the panel back to running, with nothing left to end it.

import XCTest
@testable import Orbit

@MainActor
final class LighthouseCancelStateTests: XCTestCase {

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func test_aRunCancelledWhileItWaitsIsNotRunningAfterItWakes() async {
        let model = OrbitLighthouseModel()
        model.runMode = .navigation
        model.startRun()
        await settle(0.3)
        XCTAssertTrue(model.isRunning, "the run is under way before it is cancelled")

        model.cancelRun()
        XCTAssertFalse(model.isRunning, "cancel ends the run at once")

        // the cancelled run wakes, finds the cancel and finishes the step it was in
        await settle(0.6)
        XCTAssertFalse(model.isRunning, "the cancelled run put the panel back to running: \(model.runState)")
    }

    func test_aRunCancelledRightAfterItStartsIsNotRunningAfterItWakes() async {
        let model = OrbitLighthouseModel()
        model.startRun()
        model.cancelRun()
        await settle(0.6)
        XCTAssertFalse(model.isRunning, "the cancelled run put the panel back to running: \(model.runState)")
    }

    func test_aRunStartedAfterACancelStillRuns() async {
        let model = OrbitLighthouseModel()
        model.startRun()
        model.cancelRun()
        model.startRun()
        await settle(0.3)
        XCTAssertTrue(model.isRunning, "a new run is not cut short by the cancel before it")
        model.cancelRun()
    }
}
