import Foundation
import WebKit

// HTTP Basic, Digest and NTLM. WKWebView never shows its own password prompt on macOS: a challenge nobody answers
// continues without credentials, so a protected page just looks like it refused.
extension WebKitWebContents {

    nonisolated static let passwordAuthenticationMethods: Set<String> = [
        NSURLAuthenticationMethodHTTPBasic,
        NSURLAuthenticationMethodHTTPDigest,
        NSURLAuthenticationMethodNTLM,
    ]

    nonisolated static func asksForPassword(_ space: URLProtectionSpace) -> Bool {
        passwordAuthenticationMethods.contains(space.authenticationMethod)
    }

    /// A server may only prompt for the page the user is on. A script, image or frame from elsewhere that answers
    /// 401 would otherwise put a login box over a site that has nothing to do with it. A proxy blocks every request, so it is always the user's business.
    static func challengeIsForNavigation(_ space: URLProtectionSpace, documentURLs: [URL?]) -> Bool {
        if space.isProxy() { return true }
        return documentURLs.contains { candidate in
            guard let url = candidate, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
            guard scheme == (space.protocol ?? scheme).lowercased() else { return false }
            let defaultPort = scheme == "https" ? 443 : 80
            return normalisedHost(url.host) == normalisedHost(space.host) && (url.port ?? defaultPort) == space.port
        }
    }

    private static func normalisedHost(_ host: String?) -> String {
        var host = (host ?? "").lowercased()
        while host.last == "." {
            host.removeLast()
        }
        return host
    }

    /// Stored credentials first, so a saved login signs in without a prompt. A refused one is dropped, and the user is asked again.
    func httpCredentialDecision(for challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let storage = URLCredentialStorage.shared
        let isPersistent = webView.configuration.websiteDataStore.isPersistent
        let previousAttemptFailed = challenge.previousFailureCount > 0

        if previousAttemptFailed {
            if let refused = challenge.proposedCredential { storage.remove(refused, for: space) }
        } else if let stored = Self.storedCredential(for: challenge, in: storage, isPersistent: isPersistent) {
            return (.useCredential, stored)
        }

        let isForNavigation = Self.challengeIsForNavigation(
            space,
            documentURLs: [navigationState.url, inFlightURL(), privateWebViewURL("_provisionalURL"), extras.requestedLoadURL]
        )
        guard isForNavigation, !isClosed, delegate != nil else { return (.performDefaultHandling, nil) }

        let request = HTTPCredentialRequest(
            host: space.host,
            port: space.port,
            realm: space.realm,
            isProxy: space.isProxy(),
            previousAttemptFailed: previousAttemptFailed,
            canRemember: isPersistent
        )
        guard let response = await credentialResponse(for: request, space: space), !isClosed else {
            // Declining is not an error. The page shows what the server sent without credentials.
            return (.performDefaultHandling, nil)
        }

        let remember = response.remember && isPersistent
        let credential = URLCredential(
            user: response.username,
            password: response.password,
            persistence: remember ? .permanent : .forSession
        )
        if remember { storage.set(credential, for: space) }
        return (.useCredential, credential)
    }

    private static func storedCredential(
        for challenge: URLAuthenticationChallenge,
        in storage: URLCredentialStorage,
        isPersistent: Bool
    ) -> URLCredential? {
        if let proposed = challenge.proposedCredential, proposed.hasPassword { return proposed }
        guard isPersistent else { return nil }
        let space = challenge.protectionSpace
        if let preferred = storage.defaultCredential(for: space), preferred.hasPassword { return preferred }
        return storage.credentials(for: space)?.values.first { $0.hasPassword }
    }

    private func credentialResponse(for request: HTTPCredentialRequest, space: URLProtectionSpace) async -> HTTPCredentialResponse? {
        let key = "\(Self.credentialPromptKey(for: space)):\(request.previousAttemptFailed)"
        if let showing = extras.credentialPrompts[key] { return await showing.value }
        let task = Task { @MainActor [weak self] () -> HTTPCredentialResponse? in
            guard let self else { return nil }
            return await self.delegate?.webContents(self, requestsHTTPCredentials: request)
        }
        extras.credentialPrompts[key] = task
        let response = await task.value
        extras.credentialPrompts[key] = nil
        return response
    }

    private static func credentialPromptKey(for space: URLProtectionSpace) -> String {
        "\(normalisedHost(space.host)):\(space.port):\(space.realm ?? ""):\(space.isProxy())"
    }
}
