import Foundation

/// The vault the rest of the app uses: the Keychain one in the app, an in-memory one under test so a test run can never read or write saved logins.
nonisolated enum PasswordVaults {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: (any PasswordVault)?

    #if DEBUG
    /// Settable so a test can inject its own vault.
    static var shared: any PasswordVault {
        get { resolved() }
        set { lock.withLock { current = newValue } }
    }

    /// Drops an injected vault so the next read builds the default again.
    static func resetShared() {
        lock.withLock { current = nil }
    }
    #else
    static var shared: any PasswordVault { resolved() }
    #endif

    private static func resolved() -> any PasswordVault {
        lock.withLock {
            if let current { return current }
            let vault = makeDefault()
            current = vault
            return vault
        }
    }

    private static func makeDefault() -> any PasswordVault {
        switch OrbitRuntimeScope.current {
        case .test: return InMemoryPasswordVault()
        case .production, .development: return KeychainPasswordVault()
        }
    }
}
