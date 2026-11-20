import AppKit
import Observation

/// What page autofill needs from the system password manager. The app uses `SystemPasswords.shared`; a test supplies its own.
@MainActor
protocol SystemPasswordsProviding: AnyObject {
    var state: SystemPasswordsState { get }
    var canFillOneTimeCodes: Bool { get }
    /// Usernames listed for `host` a moment ago, if any; never a password.
    func cachedLogins(forHost host: String) -> [SystemPasswordLogin]?
    func logins(forHost host: String) async throws -> [SystemPasswordLogin]
    func password(forUsername username: String, host: String) async throws -> String
    func save(username: String, password: String, host: String) async throws -> SystemPasswordsSaveOutcome
    func oneTimeCodes(pageURL: URL, username: String?) async throws -> [SystemPasswordOneTimeCode]
    /// The code behind a list entry whose code was not handed over.
    func revealOneTimeCode(pageURL: URL, username: String?) async throws -> String
    func didFillOneTimeCode(pageURL: URL, username: String) async
    func requestPairing(over window: NSWindow?)
    func openPasswordsApp()
}

/// Orbit's link to the passwords and passkeys in iCloud Keychain: the helper session's state for the UI, and the requests page autofill makes.
@MainActor
@Observable
final class SystemPasswords: SystemPasswordsProviding {

    static let shared = SystemPasswords()

    static let passwordsAppBundleIdentifier = "com.apple.Passwords"
    static let loginCacheLifetime: TimeInterval = 60

    private(set) var state: SystemPasswordsState = .notStarted
    private(set) var canFillOneTimeCodes = false
    private(set) var passkeyState: PasskeyAuthorizationState = .unavailable
    /// A sentence for the person about the last thing that went wrong, cleared by the next attempt.
    private(set) var lastError: String?

    @ObservationIgnored private let session: SystemPasswordsSession
    @ObservationIgnored private var cache: [String: (logins: [SystemPasswordLogin], fetched: Date)] = [:]
    @ObservationIgnored private var started = false

    init(session: SystemPasswordsSession = SystemPasswordsSession()) {
        self.session = session
        passkeyState = PasskeyAuthorization.state
        let updates = session.updates
        Task { [weak self] in
            for await update in updates {
                self?.apply(update)
            }
        }
    }

    private func apply(_ update: SystemPasswordsUpdate) {
        state = update.state
        canFillOneTimeCodes = update.canFillOneTimeCodes
        if update.state != .paired { cache.removeAll() }
    }

    /// Launches and probes the helper once per app launch. Never under test.
    func start() {
        guard !started, OrbitRuntimeScope.current != .test else { return }
        started = true
        let entitled = PasskeyAuthorization.hasBrowserEntitlement
        let session = self.session
        Task { await session.start(isEntitled: entitled) }
    }

    /// Pairing can start from here: the helper is up, or it stopped for a reason a fresh launch may cure.
    var canPair: Bool {
        switch state {
        case .notPaired, .unavailable: return true
        default: return false
        }
    }

    // MARK: - Pairing

    func beginPairing() async {
        lastError = nil
        do {
            try await session.beginPairing()
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// True once paired. A wrong code starts a new pairing at once, so macOS shows a fresh code.
    func submitPIN(_ pin: String) async -> Bool {
        lastError = nil
        do {
            try await session.submitPIN(pin)
            return true
        } catch SystemPasswordsError.wrongPIN {
            await beginPairing()
            if lastError == nil { lastError = "That code was not right. Enter the new code macOS is showing." }
            return false
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    func cancelPairing() {
        let session = self.session
        Task { await session.cancelPairing() }
    }

    func requestPairing(over window: NSWindow?) {
        SystemPasswordsPairingPresenter.shared.present(over: window, passwords: self)
    }

    // MARK: - Requests

    func cachedLogins(forHost host: String) -> [SystemPasswordLogin]? {
        guard state == .paired, let entry = cache[host], Date().timeIntervalSince(entry.fetched) < Self.loginCacheLifetime else { return nil }
        return entry.logins
    }

    func logins(forHost host: String) async throws -> [SystemPasswordLogin] {
        let logins = try await session.logins(host: host)
        cache[host] = (logins, Date())
        return logins
    }

    func password(forUsername username: String, host: String) async throws -> String {
        try await session.password(username: username, host: host)
    }

    func save(username: String, password: String, host: String) async throws -> SystemPasswordsSaveOutcome {
        cache[host] = nil
        return try await session.save(username: username, password: password, host: host)
    }

    func oneTimeCodes(pageURL: URL, username: String?) async throws -> [SystemPasswordOneTimeCode] {
        try await session.oneTimeCodes(pageURL: pageURL.absoluteString, username: username)
    }

    func revealOneTimeCode(pageURL: URL, username: String?) async throws -> String {
        try await session.revealOneTimeCode(pageURL: pageURL.absoluteString, username: username)
    }

    func didFillOneTimeCode(pageURL: URL, username: String) async {
        await session.didFillOneTimeCode(pageURL: pageURL.absoluteString, username: username)
    }

    // MARK: - Passwords app and passkeys

    func openPasswordsApp() {
        let workspace = NSWorkspace.shared
        if let app = workspace.urlForApplication(withBundleIdentifier: Self.passwordsAppBundleIdentifier) {
            workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else if let settings = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
            workspace.open(settings)
        }
    }

    func refreshPasskeyState() {
        passkeyState = PasskeyAuthorization.state
    }

    func enablePasskeys() async {
        passkeyState = await PasskeyAuthorization.request()
    }

    // MARK: - Wording

    static func message(for error: Error) -> String? {
        guard let error = error as? SystemPasswordsError else { return "Passwords could not do that: \(error.localizedDescription)" }
        switch error {
        case .helperMissing: return "This Mac has no Passwords helper for browsers."
        case .unentitledBuild: return "This build of Orbit is not signed to use Passwords."
        case .waitingForMacOS: return "macOS does not let Orbit use Passwords yet."
        case .notPaired, .sessionEnded: return "The connection to Passwords ended. Pair again to continue."
        case .timedOut: return "Passwords did not answer in time."
        case .cancelled: return nil
        case .wrongPIN: return "That code was not right."
        case .notFound: return "Passwords has no password for that account."
        case .helperFailed(let detail), .protocolFailure(let detail): return "Passwords could not do that (\(detail))."
        }
    }

    static func summary(of state: SystemPasswordsState) -> (title: String, detail: String) {
        switch state {
        case .notStarted, .starting:
            return ("Checking", "Orbit is looking for the Passwords helper.")
        case .helperMissing:
            return ("Helper missing", "This Mac has no Passwords helper for browsers. It comes with macOS; update macOS to get it.")
        case .unentitledBuild:
            return ("Not available in this build", "Only signed release builds of Orbit can use Passwords and passkeys.")
        case .waitingForMacOS:
            return (
                "Not allowed by macOS yet",
                "macOS only lets browsers on Apple's list use Passwords, and Orbit is not on it yet. It turns on by itself after the macOS update that adds Orbit."
            )
        case .notPaired:
            return ("Not paired", "Pair Orbit with Passwords to fill and save passwords. macOS shows a code to type in.")
        case .pairing:
            return ("Pairing", "Waiting for macOS to show a code.")
        case .awaitingPIN, .verifyingPIN:
            return ("Pairing", "Enter the code macOS is showing.")
        case .paired:
            return ("Paired", "Orbit fills sign-in fields from Passwords and offers to save new passwords there.")
        case .unavailable(let reason):
            return ("Unavailable", reason)
        }
    }
}
