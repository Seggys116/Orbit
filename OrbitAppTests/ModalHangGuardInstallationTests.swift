//  NSPrincipalClass misconfiguration fails silently (no test error, no watchdog
//  installed); this test turns that silent no-op into a red test.

import XCTest

final class ModalHangGuardInstallationTests: XCTestCase {

    func testTheModalHangGuardObserverIsInstalled() {
        XCTAssertTrue(
            ModalHangGuardObserver.isInstalled,
            """
            ModalHangGuardObserver.isInstalled is still false, which means \
            ModalHangGuardPrincipalClass.init() never ran for this bundle — the runtime watchdog \
            that turns a hung AppKit modal into a fast, diagnosed test failure is not protecting \
            any test in this run. Check this target's INFOPLIST_KEY_NSPrincipalClass build \
            setting (Debug and Release) still names \
            "<TARGET_NAME>.ModalHangGuardPrincipalClass", and that GENERATE_INFOPLIST_FILE is \
            still YES for this target.
            """
        )
    }
}
