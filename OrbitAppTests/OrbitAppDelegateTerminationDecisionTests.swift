import XCTest
@testable import Orbit

final class OrbitAppDelegateTerminationDecisionTests: XCTestCase {

    // MARK: - No warning needed (fewer than two tabs, or the switch is off)

    func test_noWarning_engineRunning_resolvesToTerminateLater() {
        let decision = OrbitAppDelegate.terminationDecision(
            shouldWarn: false,
            userConfirmedQuit: true,
            isEngineRunning: true
        )
        XCTAssertEqual(
            decision,
            .terminateLater,
            "A running engine must never resolve directly to .terminateNow: the browser process cannot safely be torn down " +
                "on the stack applicationShouldTerminate can be reached on. See that method's own header."
        )
    }

    func test_noWarning_engineAbsent_resolvesToTerminateNowWithNoWaiting() {
        let decision = OrbitAppDelegate.terminationDecision(
            shouldWarn: false,
            userConfirmedQuit: true,
            isEngineRunning: false
        )
        XCTAssertEqual(
            decision,
            .terminateNow,
            "Nothing to get off the engine's stack for when there is no engine running at all -- an immediate quit, " +
                "not a .terminateLater round trip."
        )
    }

    // MARK: - Warning shown and declined: Cancel must still cancel

    func test_warningDeclined_cancelsRegardlessOfWhetherTheEngineIsRunning() {
        for isEngineRunning in [true, false] {
            let decision = OrbitAppDelegate.terminationDecision(
                shouldWarn: true,
                userConfirmedQuit: false,
                isEngineRunning: isEngineRunning
            )
            XCTAssertEqual(
                decision,
                .terminateCancel,
                "Clicking Cancel on the quit-confirmation alert must cancel the quit outright -- the engine's " +
                    "state must never override that (isEngineRunning: \(isEngineRunning))."
            )
        }
    }

    // MARK: - Warning shown and confirmed: falls through to the engine check

    func test_warningConfirmed_engineRunning_resolvesToTerminateLater() {
        let decision = OrbitAppDelegate.terminationDecision(
            shouldWarn: true,
            userConfirmedQuit: true,
            isEngineRunning: true
        )
        XCTAssertEqual(decision, .terminateLater)
    }

    func test_warningConfirmed_engineAbsent_resolvesToTerminateNow() {
        let decision = OrbitAppDelegate.terminationDecision(
            shouldWarn: true,
            userConfirmedQuit: true,
            isEngineRunning: false
        )
        XCTAssertEqual(decision, .terminateNow)
    }

    // MARK: - Delivering the .terminateLater reply

    func test_terminationReplyReachesTheRunLoopWhileTheMainQueueIsBlocked() {
        let recorder = ScheduledWorkRecorder()
        let nestedLoopFinished = expectation(description: "the block simulating an async quit finished")

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                OrbitAppDelegate.performOnMainRunLoop { recorder.runLoopBlockRan = true }
            }
            DispatchQueue.main.async { recorder.mainQueueBlockRan = true }

            // AppKit's -[NSApplication _shouldTerminate] wait, in miniature.
            let deadline = Date().addingTimeInterval(3.0)
            while !recorder.runLoopBlockRan, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            recorder.secondsWaited = 3.0 - deadline.timeIntervalSinceNow

            // Snapshot in here; the queued block runs the instant this returns.
            recorder.runLoopBlockRanWhileBlocked = recorder.runLoopBlockRan
            recorder.mainQueueBlockRanWhileBlocked = recorder.mainQueueBlockRan
            nestedLoopFinished.fulfill()
        }

        wait(for: [nestedLoopFinished], timeout: 10)

        XCTAssertTrue(
            recorder.runLoopBlockRanWhileBlocked,
            """
            OrbitAppDelegate.performOnMainRunLoop did not run its block inside a nested run loop \
            while a main-queue block was on the stack. That is the exact shape of \
            applicationShouldTerminate's .terminateLater reply, so this failing means quitting from \
            any Swift async / @MainActor context (DemoCaptureDriver, DemoEngineProbe) hangs in \
            -[NSApplication _shouldTerminate] forever.
            """
        )

        XCTAssertFalse(
            recorder.mainQueueBlockRanWhileBlocked,
            """
            A DispatchQueue.main.async block ran while another main-queue block was still on the \
            stack, which the serial main queue cannot do. Either this test no longer reproduces the \
            deadlock it exists to pin down, or GCD's semantics changed -- do not "fix" it by \
            putting the termination reply back on the main queue.
            """
        )

        XCTAssertLessThan(
            recorder.secondsWaited,
            1.0,
            "The reply arrived, but only after \(recorder.secondsWaited)s. It is supposed to land on the very next turn of the run loop."
        )
    }

    private final class ScheduledWorkRecorder: @unchecked Sendable {
        var runLoopBlockRan = false
        var mainQueueBlockRan = false
        var runLoopBlockRanWhileBlocked = false
        var mainQueueBlockRanWhileBlocked = false
        var secondsWaited: TimeInterval = 0
    }
}
