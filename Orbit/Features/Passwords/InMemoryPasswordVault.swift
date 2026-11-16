import Foundation

/// A vault that keeps everything in memory. Used by tests and by any run that must not reach the Keychain.
nonisolated final class InMemoryPasswordVault: PasswordVault, @unchecked Sendable {

    private let lock = NSLock()
    private var book = LoginBook()
    private var neverSave: Set<String> = []
    private let now: @Sendable () -> Date
    private let notifier = PasswordVaultNotifier()

    /// `now` stamps created, updated and last-used times; tests pass a controlled clock.
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func logins(matching pageURL: URL) -> [SavedLogin] {
        lock.withLock { book.matching(pageURL) }
    }

    func allLogins() -> [SavedLogin] {
        lock.withLock { book.all() }
    }

    func login(id: UUID) -> SavedLogin? {
        lock.withLock { book.login(id: id) }
    }

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

    func deleteAll() {
        let hadLogins: Bool = lock.withLock {
            let wasEmpty = book.logins.isEmpty
            book = LoginBook()
            return !wasEmpty
        }
        if hadLogins { notifier.notify(self) }
    }

    func markUsed(id: UUID) {
        let stamp = now()
        mutate { book in book.markUsed(id: id, now: stamp).map { ((), $0) } }
    }

    func neverSaveSiteKeys() -> [String] {
        lock.withLock { neverSave.sorted() }
    }

    func setNeverSave(_ neverSave: Bool, forSiteKey siteKey: String) {
        let key = NeverSaveList.normalized(siteKey)
        guard !key.isEmpty else { return }
        let changed: Bool = lock.withLock {
            neverSave ? self.neverSave.insert(key).inserted : self.neverSave.remove(key) != nil
        }
        if changed { notifier.notify(self) }
    }

    func isNeverSave(siteKey: String) -> Bool {
        let key = NeverSaveList.normalized(siteKey)
        return lock.withLock { neverSave.contains(key) }
    }

    @discardableResult
    private func mutate<Value>(_ body: (inout LoginBook) -> (Value, LoginBook.Change)?) -> Value? {
        var changed = false
        let value: Value? = lock.withLock {
            guard let result = body(&book) else { return nil }
            changed = !result.1.isEmpty
            return result.0
        }
        if changed { notifier.notify(self) }
        return value
    }
}
