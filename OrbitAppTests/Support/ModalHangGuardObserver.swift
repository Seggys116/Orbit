import AppKit
import XCTest

final class ModalHangGuardObserver: NSObject, XCTestObservation {

    static let shared = ModalHangGuardObserver()
    private override init() { super.init() }

    static var isInstalled = false

    // MARK: - Tuning

    static let graceInterval: TimeInterval = 5.0
    private static let pollInterval: TimeInterval = 0.1

    // MARK: - State

    private weak var currentTestCase: XCTestCase?
    private var timer: Timer?
    private weak var trackedModalWindow: NSWindow?
    private var trackedModalWindowFirstSeenAt: Date?
    private var trippedForTrackedModalWindow = false

    // MARK: - XCTestObservation

    func testCaseWillStart(_ testCase: XCTestCase) {
        currentTestCase = testCase
        trackedModalWindow = nil
        trackedModalWindowFirstSeenAt = nil
        trippedForTrackedModalWindow = false
        guard timer == nil else { return }
        let watchdog = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        timer = watchdog
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        currentTestCase = nil
        trackedModalWindow = nil
        trackedModalWindowFirstSeenAt = nil
        trippedForTrackedModalWindow = false
    }

    // MARK: - The watchdog

    private func poll() {
        guard currentTestCase != nil else {
            trackedModalWindow = nil
            trackedModalWindowFirstSeenAt = nil
            trippedForTrackedModalWindow = false
            return
        }

        // NSApp itself (not just .modalWindow) can be nil in a bare xctest process at odd moments
        // in its lifecycle; the global is an implicitly-unwrapped optional, so check it explicitly.
        guard let app = NSApp, let modalWindow = app.modalWindow else {
            trackedModalWindow = nil
            trackedModalWindowFirstSeenAt = nil
            trippedForTrackedModalWindow = false
            return
        }

        guard trackedModalWindow === modalWindow else {
            trackedModalWindow = modalWindow
            trackedModalWindowFirstSeenAt = Date()
            trippedForTrackedModalWindow = false
            return
        }

        guard !trippedForTrackedModalWindow else {
            forceCloseIfStillModal(modalWindow)
            return
        }

        guard let firstSeenAt = trackedModalWindowFirstSeenAt,
              Date().timeIntervalSince(firstSeenAt) >= Self.graceInterval
        else {
            return
        }

        trippedForTrackedModalWindow = true
        reportHangAndAbort(modalWindow)
    }

    private func reportHangAndAbort(_ modalWindow: NSWindow) {
        let windowClass = String(describing: type(of: modalWindow))
        let windowTitle = modalWindow.title.isEmpty ? "(no title)" : modalWindow.title
        let testName = currentTestCase?.name ?? "(no XCTestCase currently tracked)"

        let message = """
        ModalHangGuardObserver: a modal AppKit session (\(windowClass), title "\(windowTitle)") \
        has been open for at least \(Self.graceInterval)s during \(testName), with nothing in \
        this unattended process able to click it. This is the defect this guard exists to catch \
        — fix it the way this repository already does elsewhere: build the real control/menu and \
        invoke its target/action directly instead of presenting it (see \
        Orbit/UI/Content/OrbitContextMenu.swift's buildContextMenuEntries vs \
        presentContextMenu), or assert the pure decision function a delegate call would \
        consult instead of driving the delegate call itself (see \
        AppEnvironment.refusalWithoutPrompting(for:)). Aborting the modal session now so this run \
        does not hang, and failing \(testName) so the hazard is visible rather than silently absent.
        """
        NSLog("[ModalHangGuard] %@", message)

        if let testCase = currentTestCase {
            let location = XCTSourceCodeLocation(filePath: #filePath, lineNumber: #line)
            let issue = XCTIssue(
                type: .assertionFailure,
                compactDescription: message,
                detailedDescription: nil,
                sourceCodeContext: XCTSourceCodeContext(location: location),
                associatedError: nil,
                attachments: []
            )
            testCase.record(issue)
        }

        NSApp.abortModal()
    }

    private func forceCloseIfStillModal(_ modalWindow: NSWindow) {
        guard NSApp.modalWindow === modalWindow else { return }
        NSLog(
            "[ModalHangGuard] NSApp.abortModal() did not clear %@ ('%@') by the next poll — forcing it closed directly.",
            String(describing: type(of: modalWindow)),
            modalWindow.title
        )
        modalWindow.orderOut(nil)
        modalWindow.close()
    }
}
