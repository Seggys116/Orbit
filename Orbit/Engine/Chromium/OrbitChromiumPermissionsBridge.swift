//  Puts chrome.permissions.request to the user and answers the engine exactly
//  once, through the request id it was asked with.

import Foundation
import OSLog

struct OrbitPermissionsConsentDelegateLayout {
    var opaque: UnsafeMutableRawPointer?
    var requestConsent: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt64) -> Void)?
}

@MainActor
final class OrbitChromiumPermissionsBridge {

    static let shared = OrbitChromiumPermissionsBridge()

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "PermissionsBridge")

    private init() {}

    func install() {
        var layout = OrbitPermissionsConsentDelegateLayout()
        layout.opaque = Unmanaged.passUnretained(self).toOpaque()
        // Hops to a later main-actor turn rather than answering inline: the
        // engine's contract is that no response arrives before this returns.
        layout.requestConsent = { _, jsonPtr, requestID in
            let json = jsonPtr.map { String(cString: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let json else {
                        OrbitChromiumPermissionsBridge.shared.answer(requestID: requestID, approved: false)
                        return
                    }
                    OrbitChromiumPermissionsBridge.shared.requestConsent(json: json, requestID: requestID)
                }
            }
        }
        if !OrbitChromiumBridge.shared.setPermissionsConsentDelegate(layout) {
            Self.logger.notice("chrome.permissions consent is unavailable in this Orbit Framework build")
        }
    }

    private func answer(requestID: UInt64, approved: Bool) {
        OrbitChromiumBridge.shared.permissionsConsentResponse(requestID: requestID, approved: approved)
    }

    /// Refuses rather than queueing when there's nowhere to show the sheet:
    /// a queued request would sit invisible indefinitely.
    private func requestConsent(json: String, requestID: UInt64) {
        if let automatic = WebStoreInstallVerifyProbe.autoAnswerExtensionPermissionsConsent {
            answer(requestID: requestID, approved: automatic)
            return
        }
        // Resolved only by a SwiftUI click, so an unattended run has nobody to
        // answer it — same reasoning as the install consent sheet.
        guard !DebugFlags.isRunningUnderTests else {
            answer(requestID: requestID, approved: false)
            return
        }
        guard let request = ExtensionPermissionsConsentRequest(json: json, requestID: requestID) else {
            Self.logger.error("chrome.permissions consent request \(requestID) could not be decoded; refusing")
            answer(requestID: requestID, approved: false)
            return
        }
        // Process-wide, with no owning tab of its own: it usually comes from a
        // popup or an options page. The frontmost window's active tab is the
        // one surface the user is actually looking at.
        let environment = AppEnvironment.frontmost
        guard let tabID = environment.activeTabID,
              environment.pendingExtensionPermissionsConsent[tabID] == nil
        else {
            answer(requestID: requestID, approved: false)
            return
        }
        environment.pendingExtensionPermissionsConsent[tabID] = request
    }
}
