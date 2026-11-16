import Foundation

/// The origin a login is saved for: `scheme://host[:port]` in lower case, with no path, credentials, or default port.
nonisolated struct PasswordOrigin: Equatable, Sendable {
    let origin: String
    /// The registrable domain of the host by the Public Suffix List, so tenants of a shared suffix such as github.io are separate sites.
    let siteKey: String

    var isHTTPS: Bool { origin.hasPrefix("https://") }

    /// Nil unless `url` is http or https and has a usable host.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased()
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // A rooted name and its unrooted form are the same site.
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty,
              !host.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0 == "%" || CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        var origin = "\(scheme)://" + (host.contains(":") ? "[\(host)]" : host)
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { origin += ":\(port)" }
        self.origin = origin
        self.siteKey = PublicSuffixList.registrableDomain(ofHost: host)
    }

    init?(origin string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }
}

/// The logins of a vault with the matching and replacement rules, free of any storage. Both vaults hold one and persist the `Change` each mutation reports.
nonisolated struct LoginBook: Sendable {

    /// What a mutation did to the stored items, so a vault can write only that.
    struct Change: Sendable, Equatable {
        var upserted: [SavedLogin] = []
        var removed: [UUID] = []
        var isEmpty: Bool { upserted.isEmpty && removed.isEmpty }
    }

    private(set) var logins: [UUID: SavedLogin] = [:]

    init() {}

    /// For items read back from storage: a login whose origin cannot be parsed is dropped, and the rest get a site key recomputed from their origin.
    init(sanitizing stored: [SavedLogin]) {
        for var login in stored {
            guard let origin = PasswordOrigin(origin: login.origin) else { continue }
            login.origin = origin.origin
            login.siteKey = origin.siteKey
            logins[login.id] = login
        }
    }

    /// Ordered by site, then origin, then username, so a settings list is stable.
    func all() -> [SavedLogin] {
        logins.values.sorted { lhs, rhs in
            if lhs.siteKey != rhs.siteKey { return lhs.siteKey < rhs.siteKey }
            if lhs.origin != rhs.origin { return lhs.origin < rhs.origin }
            let leftName = lhs.username.lowercased(), rightName = rhs.username.lowercased()
            if leftName != rightName { return leftName < rightName }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func login(id: UUID) -> SavedLogin? { logins[id] }

    /// Same origin first, then another origin of the same registrable domain, each group most recently used first. Never crosses registrable domains and is empty for a page that is not http(s).
    /// A login saved on https is never matched for an http page, not even for the same site or the same host: it would hand a password chosen for an encrypted connection to one anyone on the network can read or rewrite.
    func matching(_ pageURL: URL) -> [SavedLogin] {
        guard let page = PasswordOrigin(url: pageURL) else { return [] }
        var sameOrigin: [SavedLogin] = []
        var sameSite: [SavedLogin] = []
        for login in logins.values {
            if !page.isHTTPS, login.origin.hasPrefix("https://") { continue }
            if login.origin == page.origin {
                sameOrigin.append(login)
            } else if login.siteKey == page.siteKey {
                sameSite.append(login)
            }
        }
        return sameOrigin.sorted(by: Self.isMoreRecent) + sameSite.sorted(by: Self.isMoreRecent)
    }

    /// A login that was never used counts from the moment it was saved or last changed.
    private static func isMoreRecent(_ lhs: SavedLogin, _ rhs: SavedLogin) -> Bool {
        let left = lhs.lastUsedAt ?? lhs.updatedAt
        let right = rhs.lastUsedAt ?? rhs.updatedAt
        if left != right { return left > right }
        if lhs.username != rhs.username { return lhs.username < rhs.username }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    // MARK: - Mutations

    mutating func save(
        origin pageURL: URL,
        username rawUsername: String,
        password: String,
        now: Date
    ) -> (outcome: LoginSaveOutcome, change: Change)? {
        guard let origin = PasswordOrigin(url: pageURL) else { return nil }
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else { return nil }

        let existing = logins.values
            .filter { $0.origin == origin.origin && $0.username == username }
            .min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }

        if var existing {
            if existing.password == password { return (.unchanged(existing), Change()) }
            existing.password = password
            existing.updatedAt = now
            logins[existing.id] = existing
            return (.updated(existing), Change(upserted: [existing]))
        }
        let login = SavedLogin(
            origin: origin.origin,
            siteKey: origin.siteKey,
            username: username,
            password: password,
            createdAt: now,
            updatedAt: now
        )
        logins[login.id] = login
        return (.added(login), Change(upserted: [login]))
    }

    /// Nil when no entry has that id, or the replacement has an unusable origin, an empty username after trimming, or an empty password. Another entry that already holds the new origin and username is removed so the pair stays unique.
    mutating func update(_ replacement: SavedLogin, now: Date) -> Change? {
        guard let existing = logins[replacement.id],
              let origin = PasswordOrigin(origin: replacement.origin)
        else { return nil }
        let username = replacement.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !replacement.password.isEmpty else { return nil }

        var updated = existing
        updated.origin = origin.origin
        updated.siteKey = origin.siteKey
        updated.username = username
        updated.password = replacement.password
        if updated == existing { return Change() }
        updated.updatedAt = now

        var change = Change(upserted: [updated])
        let duplicates = logins.values.filter {
            $0.id != updated.id && $0.origin == updated.origin && $0.username == updated.username
        }
        for duplicate in duplicates {
            logins[duplicate.id] = nil
            change.removed.append(duplicate.id)
        }
        logins[updated.id] = updated
        return change
    }

    mutating func markUsed(id: UUID, now: Date) -> Change? {
        guard var login = logins[id] else { return nil }
        login.lastUsedAt = now
        logins[id] = login
        return Change(upserted: [login])
    }

    mutating func delete(id: UUID) -> Change? {
        guard logins.removeValue(forKey: id) != nil else { return nil }
        return Change(removed: [id])
    }
}

/// Posts `.orbitPasswordVaultDidChange` on the main thread. Never synchronously, so an observer may call back into the vault, and a burst of changes such as an import produces one notification.
nonisolated final class PasswordVaultNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var isPending = false

    func notify(_ vault: any PasswordVault) {
        let shouldSchedule = lock.withLock { () -> Bool in
            if isPending { return false }
            isPending = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [self] in
            lock.withLock { isPending = false }
            NotificationCenter.default.post(name: .orbitPasswordVaultDidChange, object: vault)
        }
    }
}

/// The never-save list, normalised the same way by both vaults.
nonisolated enum NeverSaveList {
    static func normalized(_ siteKey: String) -> String {
        siteKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
