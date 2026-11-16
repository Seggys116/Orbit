import Foundation

/// A username and password the user saved for a site. Orbit keeps these in its own vault because WKWebView offers no system Password AutoFill.
nonisolated public struct SavedLogin: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Where it was saved, as `scheme://host[:port]` with no path.
    public var origin: String
    /// The registrable domain of `origin` by the Public Suffix List (`PublicSuffixList`).
    public var siteKey: String
    public var username: String
    public var password: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        origin: String,
        siteKey: String,
        username: String,
        password: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.origin = origin
        self.siteKey = siteKey
        self.username = username
        self.password = password
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }
}

nonisolated public enum LoginSaveOutcome: Equatable, Sendable {
    /// A new entry was stored.
    case added(SavedLogin)
    /// The same origin and username already existed with a different password, which was replaced.
    case updated(SavedLogin)
    /// The same origin, username and password was already stored.
    case unchanged(SavedLogin)
}

public extension Notification.Name {
    /// Posted on the main thread after any change to the vault's contents or its never-save list.
    static let orbitPasswordVaultDidChange = Notification.Name("OrbitPasswordVaultDidChange")
}

/// Thread-safe, synchronous. Implementations: the Keychain-backed vault used by the app and an in-memory one for tests.
public protocol PasswordVault: AnyObject, Sendable {
    /// Logins that may be offered on `pageURL`: those saved for the same origin first, then those for another origin of the same site, each group most recently used first. Empty for a non-http(s) page.
    /// A login saved on https is never returned for an http page, whatever its origin; on an http page only logins saved from an http origin are offered.
    func logins(matching pageURL: URL) -> [SavedLogin]
    func allLogins() -> [SavedLogin]
    func login(id: UUID) -> SavedLogin?
    /// Adds the login, or replaces the password of the entry with the same origin and username. Nil for an empty username or password or a URL with no http(s) origin.
    @discardableResult
    func save(origin pageURL: URL, username: String, password: String) -> LoginSaveOutcome?
    /// Replaces an existing entry's origin, username and password. False when no entry has that id.
    @discardableResult
    func update(_ login: SavedLogin) -> Bool
    func delete(id: UUID)
    func deleteAll()
    func markUsed(id: UUID)

    /// Sites the user chose "Never Save" for.
    func neverSaveSiteKeys() -> [String]
    func setNeverSave(_ neverSave: Bool, forSiteKey siteKey: String)
    func isNeverSave(siteKey: String) -> Bool
}
