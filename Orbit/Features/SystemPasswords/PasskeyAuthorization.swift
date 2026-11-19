import AuthenticationServices
import Foundation
import Security

nonisolated enum PasskeyAuthorizationState: Sendable, Equatable {
    /// This build is not signed with the web browser public key credential entitlement.
    case unavailable
    case notDetermined
    case authorized
    case denied
}

extension Notification.Name {
    static let orbitPasskeyAuthorizationDidChange = Notification.Name("OrbitPasskeyAuthorizationDidChange")
}

/// Whether WKWebView's WebAuthn may use the passkeys in iCloud Keychain. macOS asks the person once; release builds carry the
/// entitlement that makes the question possible.
@MainActor
enum PasskeyAuthorization {

    nonisolated static let entitlement = "com.apple.developer.web-browser.public-key-credential"
    static let probeHandlerName = "orbitPasskeyProbe"

    nonisolated static let hasBrowserEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        return (value as? Bool) == true
    }()

    private static var didRequestThisLaunch = false

    static var state: PasskeyAuthorizationState {
        guard hasBrowserEntitlement else { return .unavailable }
        return map(ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials)
    }

    /// Pages get the first-use probe only while the answer is still open.
    static var wantsFirstUseProbe: Bool { !didRequestThisLaunch && state == .notDetermined }

    static func requestOnFirstUse() {
        guard !didRequestThisLaunch, state == .notDetermined else { return }
        Task { await request() }
    }

    @discardableResult
    static func request() async -> PasskeyAuthorizationState {
        guard hasBrowserEntitlement else { return .unavailable }
        didRequestThisLaunch = true
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        let answer = await withCheckedContinuation { continuation in
            manager.requestAuthorizationForPublicKeyCredentials { state in
                continuation.resume(returning: state)
            }
        }
        NotificationCenter.default.post(name: .orbitPasskeyAuthorizationDidChange, object: nil)
        return map(answer)
    }

    private static func map(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> PasskeyAuthorizationState {
        switch state {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Runs in the page world, because only there is the page's own navigator.credentials. It tells Orbit about the first WebAuthn call
    /// and passes every call through unchanged.
    static let probeSource = """
    (function () {
      'use strict';
      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.\(probeHandlerName);
      var credentials = navigator.credentials;
      if (!handler || !credentials || typeof credentials.get !== 'function' || typeof credentials.create !== 'function') { return; }
      var told = false;
      function note(options) {
        if (told || !options || !options.publicKey) { return; }
        told = true;
        try { handler.postMessage('webauthn'); } catch (e) {}
      }
      var get = credentials.get;
      var create = credentials.create;
      try {
        credentials.get = function (options) { note(options); return get.apply(this, arguments); };
        credentials.create = function (options) { note(options); return create.apply(this, arguments); };
      } catch (e) {}
    })();
    """
}
