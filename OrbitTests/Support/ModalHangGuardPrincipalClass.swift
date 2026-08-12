// This bundle's NSPrincipalClass, instantiated by XCTest exactly once before any test
// runs. Deliberately tiny: if init() never runs, ModalHangGuardInstallationTests fails.

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
