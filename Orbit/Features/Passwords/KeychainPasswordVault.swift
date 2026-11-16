import Foundation
import OSLog
import Security

/// Saved logins in the file-based login keychain, one generic-password item per login. The item's value is the JSON of the whole login, password included. Orbit is not sandboxed, so the login keychain is reachable and the items show up in Keychain Access under a readable label.
///
/// Reads come from a cache that is filled on first use and replaced only by this vault's own writes, so a change made to the items by another process is not seen until the next launch. Passwords are never written to the log.
nonisolated final class KeychainPasswordVault: PasswordVault, @unchecked Sendable {

    static let productionService = "com.zak-noble-clarke.Orbit.saved-logins"

    /// Only the installed browser reaches the items holding the user's real passwords.
    static let defaultService: String = {
        switch OrbitRuntimeScope.current {
        case .production: return productionService
        case .development: return productionService + ".development"
        case .test: return productionService + ".test"
        }
    }()

    static let neverSaveDefaultsKey = "OrbitPasswordNeverSaveSiteKeys"

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "KeychainPasswordVault")

    private let service: String
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let notifier = PasswordVaultNotifier()
    private let lock = NSLock()
    // Nil until the items have been read; stays nil after a failed read so the next call tries again.
    private var cache: LoginBook?

    /// `defaults` holds the never-save list and is `OrbitDefaults.standard` unless a test supplies its own suite.
    init(
        service: String = KeychainPasswordVault.defaultService,
        defaults: UserDefaults? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.defaults = defaults ?? OrbitDefaults.standard
        self.now = now
    }

    // MARK: - PasswordVault

    func logins(matching pageURL: URL) -> [SavedLogin] {
        lock.withLock { loadedBook()?.matching(pageURL) ?? [] }
    }

    func allLogins() -> [SavedLogin] {
        lock.withLock { loadedBook()?.all() ?? [] }
    }

    func login(id: UUID) -> SavedLogin? {
        lock.withLock { loadedBook()?.login(id: id) }
    }

    /// Also nil when the item could not be written, for example because the keychain is locked or access was refused.
    @discardableResult
    func save(origin pageURL: URL, username: String, password: String) -> LoginSaveOutcome? {
        let stamp = now()
        return mutate { book in
            book.save(origin: pageURL, username: username, password: password, now: stamp).map { ($0.outcome, $0.change) }
        }
    }

    @discardableResult
    func update(_ login: SavedLogin) -> Bool {
        let stamp = now()
        return mutate { book in
            book.update(login, now: stamp).map { (true, $0) }
        } ?? false
    }

    func delete(id: UUID) {
        mutate { book in book.delete(id: id).map { ((), $0) } }
    }

    /// Removes every item under this vault's service, including any that could not be decoded.
    func deleteAll() {
        let deleted: Bool = lock.withLock {
            var query = baseQuery()
            // The file-based keychain deletes only the first match unless told otherwise.
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                Self.logger.error("could not delete the saved logins: status \(status, privacy: .public)")
                cache = nil
                return false
            }
            cache = LoginBook()
            return true
        }
        if deleted { notifier.notify(self) }
    }

    func markUsed(id: UUID) {
        let stamp = now()
        mutate { book in book.markUsed(id: id, now: stamp).map { ((), $0) } }
    }

    func neverSaveSiteKeys() -> [String] {
        lock.withLock { storedNeverSave().sorted() }
    }

    func setNeverSave(_ neverSave: Bool, forSiteKey siteKey: String) {
        let key = NeverSaveList.normalized(siteKey)
        guard !key.isEmpty else { return }
        let changed: Bool = lock.withLock {
            var keys = storedNeverSave()
            let didChange = neverSave ? keys.insert(key).inserted : keys.remove(key) != nil
            if didChange { defaults.set(keys.sorted(), forKey: Self.neverSaveDefaultsKey) }
            return didChange
        }
        if changed { notifier.notify(self) }
    }

    func isNeverSave(siteKey: String) -> Bool {
        let key = NeverSaveList.normalized(siteKey)
        return lock.withLock { storedNeverSave().contains(key) }
    }

    // MARK: - Mutation

    /// Applies `body` to a copy of the cache and keeps the copy only once every item it touched has been written, so the cache never claims a change the keychain refused.
    @discardableResult
    private func mutate<Value>(_ body: (inout LoginBook) -> (Value, LoginBook.Change)?) -> Value? {
        var changed = false
        let value: Value? = lock.withLock {
            guard var book = loadedBook(), let result = body(&book) else { return nil }
            let change = result.1
            if !change.isEmpty {
                guard persist(change) else {
                    // Some items may have been written; reread rather than guess which.
                    cache = nil
                    return nil
                }
                cache = book
                changed = true
            }
            return result.0
        }
        if changed { notifier.notify(self) }
        return value
    }

    // MARK: - Never-save list

    private func storedNeverSave() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.neverSaveDefaultsKey) ?? [])
    }

    // MARK: - Cache

    /// The caller holds `lock`.
    private func loadedBook() -> LoginBook? {
        if let cache { return cache }
        guard let loaded = readAll() else { return nil }
        cache = loaded
        return loaded
    }

    // MARK: - Keychain

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Nil when the keychain could not be read, as opposed to holding nothing.
    private func readAll() -> LoginBook? {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return LoginBook() }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            Self.logger.error("could not list the saved logins: status \(status, privacy: .public)")
            return nil
        }

        var stored: [SavedLogin] = []
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String else { continue }
            // The file-based keychain refuses to return the data of several items in one query.
            var dataQuery = baseQuery(account: account)
            dataQuery[kSecReturnData as String] = true
            dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let itemStatus = SecItemCopyMatching(dataQuery as CFDictionary, &item)
            if itemStatus == errSecItemNotFound { continue }
            guard itemStatus == errSecSuccess else {
                Self.logger.error("could not read a saved login: status \(itemStatus, privacy: .public)")
                return nil
            }
            // An item that does not decode is left alone rather than deleted.
            guard let data = item as? Data,
                  let record = try? JSONDecoder().decode(StoredLogin.self, from: data)
            else { continue }
            stored.append(record.login)
        }
        return LoginBook(sanitizing: stored)
    }

    private func persist(_ change: LoginBook.Change) -> Bool {
        for login in change.upserted where !write(login) { return false }
        for id in change.removed where !remove(id: id) { return false }
        return true
    }

    private func write(_ login: SavedLogin) -> Bool {
        guard let data = try? JSONEncoder().encode(StoredLogin(login)) else { return false }
        let query = baseQuery(account: login.id.uuidString)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: Self.label(for: login),
            kSecAttrDescription as String: "Orbit saved login",
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Self.logger.error("could not write a saved login: status \(status, privacy: .public)")
            return false
        }
        return true
    }

    private func remove(id: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(account: id.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.logger.error("could not delete a saved login: status \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// What Keychain Access shows in its Name column.
    static func label(for login: SavedLogin) -> String {
        "\(login.origin) (\(login.username))"
    }
}

/// The JSON kept in an item's value. A separate type so the stored format does not follow `SavedLogin` if that gains properties.
nonisolated private struct StoredLogin: Codable, Sendable {
    var id: UUID
    var origin: String
    var siteKey: String
    var username: String
    var password: String
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    init(_ login: SavedLogin) {
        id = login.id
        origin = login.origin
        siteKey = login.siteKey
        username = login.username
        password = login.password
        createdAt = login.createdAt
        updatedAt = login.updatedAt
        lastUsedAt = login.lastUsedAt
    }

    var login: SavedLogin {
        SavedLogin(
            id: id,
            origin: origin,
            siteKey: siteKey,
            username: username,
            password: password,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt
        )
    }
}
