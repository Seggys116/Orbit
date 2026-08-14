import XCTest
@testable import Orbit

// The source-scanning tests in OrbitTests/UpdaterStatusTests can only prove the
// statements are present. These call the real methods on the real type.
@MainActor
final class UpdaterRecoveryTests: XCTestCase {

    private var updater: UpdaterController { UpdaterController.shared }

    override func tearDown() {
        updater.clearPendingState()
        updater.status = .idle
        super.tearDown()
    }

    // The reported bug: stuck on "Checking for updates…" with a Cancel button
    // that did nothing, because Sparkle never handed over a cancellation block.
    func test_cancelCheck_returnsToIdleWhenSparkleLeftNoCancellationBlock() {
        updater.status = .checking
        updater.checkCancellation = nil

        updater.cancelCheck()

        XCTAssertEqual(updater.status, .idle, "Cancel must recover the updater even with no Sparkle block to invoke — this is the state that needed a relaunch.")
    }

    func test_cancelCheck_invokesSparklesBlockAndStillReturnsToIdle() {
        var cancelled = false
        updater.status = .checking
        updater.checkCancellation = { cancelled = true }

        updater.cancelCheck()

        XCTAssertTrue(cancelled, "a real in-flight Sparkle check must still be aborted, not just forgotten")
        XCTAssertEqual(updater.status, .idle)
        XCTAssertNil(updater.checkCancellation, "the spent block must not survive into the next check")
    }

    func test_cancelDownload_returnsToIdleAndAbortsTheDownload() {
        var cancelled = false
        updater.status = .downloading(fractionCompleted: 0.5)
        updater.downloadCancellation = { cancelled = true }

        updater.cancelDownload()

        XCTAssertTrue(cancelled)
        XCTAssertEqual(updater.status, .idle)
        XCTAssertNil(updater.downloadCancellation)
    }

    func test_clearPendingState_drainsEverySessionScopedValue() {
        updater.checkCancellation = {}
        updater.downloadCancellation = {}
        updater.pendingChoiceReply = { _ in }
        updater.pendingRetryTerminatingApplication = {}
        updater.expectedDownloadLength = 1_000
        updater.receivedDownloadLength = 500

        updater.clearPendingState()

        XCTAssertNil(updater.checkCancellation)
        XCTAssertNil(updater.downloadCancellation)
        XCTAssertNil(updater.pendingChoiceReply)
        XCTAssertNil(updater.pendingAppcastItem)
        XCTAssertNil(updater.pendingRetryTerminatingApplication)
        XCTAssertEqual(updater.expectedDownloadLength, 0)
        XCTAssertEqual(updater.receivedDownloadLength, 0)
    }

    // Cancel then check again: the second check must not inherit the first's
    // spent closures, which is what made the wedge survive a retry.
    func test_aCancelledCheckLeavesNothingBehindForTheNextOne() {
        updater.status = .checking
        updater.checkCancellation = {}
        updater.downloadCancellation = {}

        updater.cancelCheck()

        XCTAssertEqual(updater.status, .idle)
        XCTAssertNil(updater.checkCancellation)
        XCTAssertNil(updater.downloadCancellation)
    }
}
