//  Answers chrome.management's enable/disable/uninstall through Orbit's own
//  ExtensionStore, so the on-disk record and the running engine stay in step.

import AppKit
import Foundation
import OSLog

struct OrbitManagementDelegateLayout {
    var opaque: UnsafeMutableRawPointer?
    var setEnabled: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32) -> Int32)?
    var confirmUninstall: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt64) -> Void)?
    var uninstall: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32)?
}

@MainActor
final class OrbitChromiumManagementBridge {

    static let shared = OrbitChromiumManagementBridge()

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "ManagementBridge")

    private init() {}

    func install() {
        var layout = OrbitManagementDelegateLayout()
        layout.opaque = Unmanaged.passUnretained(self).toOpaque()
        layout.setEnabled = { _, idPtr, enabled in
            guard let idPtr else { return 0 }
            return MainActor.assumeIsolated {
                OrbitChromiumManagementBridge.shared.setEnabled(enabled != 0, id: String(cString: idPtr)) ? 1 : 0
            }
        }
        layout.confirmUninstall = { _, idPtr, requestID in
            guard let idPtr else {
                OrbitChromiumBridge.shared.managementUninstallConsent(requestID: requestID, approved: false)
                return
            }
            let id = String(cString: idPtr)
            MainActor.assumeIsolated {
                OrbitChromiumManagementBridge.shared.requestUninstallConsent(id: id, requestID: requestID)
            }
        }
        layout.uninstall = { _, idPtr in
            guard let idPtr else { return 0 }
            return MainActor.assumeIsolated {
                OrbitChromiumManagementBridge.shared.uninstall(id: String(cString: idPtr)) ? 1 : 0
            }
        }
        OrbitChromiumBridge.shared.setManagementDelegate(layout)
    }

    private func setEnabled(_ enabled: Bool, id: String) -> Bool {
        do {
            try AppEnvironment.processRoot.extensionStore.setEnabled(enabled, id: id)
            return true
        } catch {
            Self.logger.error("chrome.management setEnabled failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func uninstall(id: String) -> Bool {
        do {
            try AppEnvironment.processRoot.extensionStore.remove(id: id)
            return true
        } catch {
            Self.logger.error("chrome.management uninstall failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // A page-initiated uninstall must be the user's decision, so this always
    // asks. The probe's own non-interactive path is the one exception,
    // matching how the install consent sheet is bypassed there.
    private func requestUninstallConsent(id: String, requestID: UInt64) {
        if ProcessInfo.processInfo.environment["ORBIT_WEBSTORE_PROBE"] == "1" {
            OrbitChromiumBridge.shared.managementUninstallConsent(requestID: requestID, approved: true)
            return
        }
        let name = AppEnvironment.processRoot.extensionStore.installed().first { $0.id == id }?.name ?? id
        let alert = NSAlert()
        alert.messageText = "Remove \(name)?"
        alert.informativeText = "This extension will be removed from Orbit."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let approved = alert.runModal() == .alertFirstButtonReturn
        OrbitChromiumBridge.shared.managementUninstallConsent(requestID: requestID, approved: approved)
    }
}
