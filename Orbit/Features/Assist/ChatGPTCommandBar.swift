//  No AppKit, no SwiftUI, no AppEnvironment — symlinked into OrbitTests/ReusedAssistSources/.

import Foundation

nonisolated enum ChatGPTCommandBar {

    static let displayName = "ChatGPT"

    static let shortcutAliases: Set<String> = ["chatgpt", "gpt"]
    static let canonicalShortcut = "gpt"
    static let urlTemplate = "https://chatgpt.com/?q=%s&hints=search"

    /// Never written to `SiteSearchStore` — identifies the pseudo-engine without string-sniffing `engine.name`.
    static let virtualEngineID = UUID(uuidString: "5FF6C0DE-0000-4000-8000-00000000C6D7")!

    static func isShortcut(_ text: String) -> Bool {
        shortcutAliases.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func virtualEngine(createdAt: Date = Date()) -> SiteSearchEngine {
        SiteSearchEngine(id: virtualEngineID, name: displayName, shortcut: canonicalShortcut, urlTemplate: urlTemplate, createdAt: createdAt)
    }

    static func url(for query: String) -> URL? {
        SiteSearchMatcher.searchURL(for: query, using: virtualEngine())
    }

    static func isAvailable(featureEnabled: Bool, isIncognito: Bool) -> Bool {
        featureEnabled && !isIncognito
    }
}
