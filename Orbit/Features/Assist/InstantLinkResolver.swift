//  No AppKit, no SwiftUI, no AppEnvironment — symlinked into OrbitTests/ReusedAssistSources/.
//  DuckDuckGo: leading `\` jumps to the first result. Google/Bing/Ecosia have no documented mechanism.

import Foundation

nonisolated enum InstantLinkResolver {

    static func instantURL(for query: String, engine: SearchEngine) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch engine {
        case .duckDuckGo:
            return duckDuckGoInstantURL(for: trimmed)
        case .google, .bing, .ecosia:
            return nil
        }
    }

    private static func duckDuckGoInstantURL(for query: String) -> URL? {
        let prefixed = query.hasPrefix("\\") ? query : "\\\(query)"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        guard let encoded = prefixed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://duckduckgo.com/?q=\(encoded)")
    }
}
