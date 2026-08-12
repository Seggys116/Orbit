import Foundation
import XCTest

final class ModalHangGuardPrincipalClass: NSObject {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(ModalHangGuardObserver.shared)
        ModalHangGuardObserver.isInstalled = true
        NSLog(
            "[ModalHangGuard] ModalHangGuardPrincipalClass.init() ran — observer registered for %@.",
            Bundle(for: Self.self).bundleURL.lastPathComponent
        )
    }
}
