import AppKit
import Foundation

@MainActor
enum DefaultBrowser {

    private static let browserSchemes = ["http", "https"]

    static var isDefault: Bool {
        isDefault(forScheme: "https")
    }

    static func isDefault(forScheme scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme)://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    // Re-checks isDefault per scheme so macOS's own confirmation panel isn't shown twice when it moves both together.
    static func requestBecomingDefault(completion: ((Result<Void, Error>) -> Void)? = nil) {
        let bundleURL = Bundle.main.bundleURL
        Task { @MainActor in
            do {
                for scheme in browserSchemes where !isDefault(forScheme: scheme) {
                    try await NSWorkspace.shared.setDefaultApplication(
                        at: bundleURL,
                        toOpenURLsWithScheme: scheme
                    )
                }
                completion?(.success(()))
            } catch {
                completion?(.failure(error))
            }
        }
    }

    // The explicit Settings button ignores this — a button the user went looking for is not a prompt to suppress.
    static var shouldOfferToBecomeDefault: Bool {
        !isDefault && !defaults.bool(forKey: declinedKey)
    }

    static func recordDeclined() {
        defaults.set(true, forKey: declinedKey)
    }

    static let declinedKey = "com.orbit.defaultBrowserPromptDeclined"

    #if DEBUG
    static var defaults: UserDefaults = .standard
    #else
    static let defaults: UserDefaults = .standard
    #endif
}
