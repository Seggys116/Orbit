import Foundation
import Security

// MARK: - Feature switches

enum AssistSettings {

    // Namespaced so a `defaults read` of the app shows them together.
    static let enabledKey = "OrbitAssistEnabled"
    static let providerKindKey = "OrbitAssistProviderKind"
    static let providerBaseURLKey = "OrbitAssistProviderBaseURL"
    /// Pre-provider-kind key: a single full chat-completions URL. Read once, to migrate.
    static let providerEndpointKey = "OrbitAssistProviderEndpoint"
    static let providerModelKey = "OrbitAssistProviderModel"
    static let askOnPageEnabledKey = "OrbitAssistAskOnPageEnabled"
    static let tidyTabsEnabledKey = "OrbitAssistTidyTabsEnabled"
    static let tidyTabTitlesEnabledKey = "OrbitAssistTidyTabTitlesEnabled"
    static let tidyDownloadsEnabledKey = "OrbitAssistTidyDownloadsEnabled"
    static let fiveSecondPreviewsEnabledKey = "OrbitAssistFiveSecondPreviewsEnabled"
    static let chatGPTCommandBarEnabledKey = "OrbitAssistChatGPTCommandBarEnabled"
    static let instantLinksEnabledKey = "OrbitAssistInstantLinksEnabled"

    #if DEBUG
    static var defaults: UserDefaults = .standard
    #else
    static let defaults: UserDefaults = .standard
    #endif

    // MARK: Master switch — Assist ships off and stays off until it is turned on here

    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    // MARK: Provider

    static var providerKind: AssistProviderKind {
        get { AssistProviderKind(rawValue: defaults.string(forKey: providerKindKey) ?? "") ?? .anthropic }
        set { defaults.set(newValue.rawValue, forKey: providerKindKey) }
    }

    static var baseURLString: String {
        get {
            if let stored = defaults.string(forKey: providerBaseURLKey),
               !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored
            }
            return defaults.string(forKey: providerEndpointKey) ?? ""
        }
        set { defaults.set(newValue, forKey: providerBaseURLKey) }
    }

    static var model: String {
        get { defaults.string(forKey: providerModelKey) ?? "" }
        set { defaults.set(newValue, forKey: providerModelKey) }
    }

    static var apiKey: String {
        get { AssistKeychain.read(for: providerKind) ?? "" }
        set { AssistKeychain.write(newValue, for: providerKind) }
    }

    static var providerConfig: AssistProviderConfig {
        AssistProviderConfig(
            kind: providerKind,
            baseURLString: baseURLString,
            model: model,
            apiKey: apiKey
        )
    }

    static var isProviderConfigured: Bool { providerConfig.isConfigured }

    // MARK: Per-feature switches — every one defaults to `false`, and every one is dead while `isEnabled` is false

    static var isAskOnPageEnabled: Bool {
        get { isEnabled && storedFlag(askOnPageEnabledKey) }
        set { defaults.set(newValue, forKey: askOnPageEnabledKey) }
    }

    /// The broom itself isn't gated on this switch — off, it still groups Today tabs by host via `AppEnvironment.tidyTodayTabsByHost`.
    static var isTidyTabsEnabled: Bool {
        get { isEnabled && storedFlag(tidyTabsEnabledKey) }
        set { defaults.set(newValue, forKey: tidyTabsEnabledKey) }
    }

    static var isTidyTabTitlesEnabled: Bool {
        get { isEnabled && storedFlag(tidyTabTitlesEnabledKey) }
        set { defaults.set(newValue, forKey: tidyTabTitlesEnabledKey) }
    }

    static var isTidyDownloadsEnabled: Bool {
        get { isEnabled && storedFlag(tidyDownloadsEnabledKey) }
        set { defaults.set(newValue, forKey: tidyDownloadsEnabledKey) }
    }

    static var isFiveSecondPreviewsEnabled: Bool {
        get { isEnabled && storedFlag(fiveSecondPreviewsEnabledKey) }
        set { defaults.set(newValue, forKey: fiveSecondPreviewsEnabledKey) }
    }

    // MARK: Per-feature switches that need no provider

    /// Deliberately excluded from `isAnyFeatureLive`, which means "a model will be called" — neither of these two calls one.
    static var isChatGPTCommandBarEnabled: Bool {
        get { isEnabled && storedFlag(chatGPTCommandBarEnabledKey) }
        set { defaults.set(newValue, forKey: chatGPTCommandBarEnabledKey) }
    }

    static var isInstantLinksEnabled: Bool {
        get { isEnabled && storedFlag(instantLinksEnabledKey) }
        set { defaults.set(newValue, forKey: instantLinksEnabledKey) }
    }

    /// The switch as the user left it, ignoring the master switch — what the Settings pane shows so turning Assist back on restores their choices.
    static func storedFlag(_ key: String) -> Bool { defaults.bool(forKey: key) }

    static var isAnyFeatureLive: Bool {
        isEnabled
            && isProviderConfigured
            && (isAskOnPageEnabled
                || isTidyTabsEnabled
                || isTidyTabTitlesEnabled
                || isTidyDownloadsEnabled
                || isFiveSecondPreviewsEnabled)
    }
}

// MARK: - Keychain

enum AssistKeychain {

    static let service = "com.zak-noble-clarke.Orbit.assist-provider"

    /// One entry per provider kind, so switching providers doesn't destroy the other one's key.
    static func account(for kind: AssistProviderKind) -> String { "api-key-\(kind.rawValue)" }

    #if DEBUG
    /// Non-nil only under test — reads/writes go here instead of the real Keychain.
    nonisolated(unsafe) static var inMemoryOverride: [String: String]?
    #endif

    static func read(for kind: AssistProviderKind) -> String? {
        #if DEBUG
        if let inMemoryOverride {
            let value = inMemoryOverride[account(for: kind)]
            return (value?.isEmpty ?? true) ? nil : value
        }
        #endif
        var query: [String: Any] = baseQuery(for: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    static func write(_ value: String, for kind: AssistProviderKind) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        if inMemoryOverride != nil {
            if trimmed.isEmpty {
                inMemoryOverride?.removeValue(forKey: account(for: kind))
            } else {
                inMemoryOverride?[account(for: kind)] = trimmed
            }
            return
        }
        #endif
        let query = baseQuery(for: kind)
        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private static func baseQuery(for kind: AssistProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: kind),
        ]
    }
}
