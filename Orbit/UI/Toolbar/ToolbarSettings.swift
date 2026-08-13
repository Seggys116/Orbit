//  isVisible defaults to true, deliberately diverging from Arc's own off default — do not "fix" this to match Arc.

import Foundation
import Observation

@MainActor
@Observable
final class ToolbarSettings {

    #if DEBUG
    static var shared = ToolbarSettings()
    #else
    static let shared = ToolbarSettings()
    #endif

    static let visibilityKeyEquivalent = "d"

    static let visibilityDefaultsKey = "OrbitToolbarVisible"
    static let fullURLDefaultsKey = "OrbitToolbarShowsFullURL"

    @ObservationIgnored private let defaults: UserDefaults

    // object(forKey:), not bool(forKey:): bool(forKey:) returns false for both "never set" and "explicitly set to false", which would silently make the default off.
    var isVisible: Bool {
        didSet {
            guard isVisible != oldValue else { return }
            defaults.set(isVisible, forKey: Self.visibilityDefaultsKey)
        }
    }

    // ToolbarView.addressText ORs this with DeveloperModeSettings.isEnabled, so the address bar can show the full URL because of either preference independently; this property's own meaning stays "the user opted in to Toolbar's Advanced setting".
    var showsFullURL: Bool {
        didSet {
            guard showsFullURL != oldValue else { return }
            defaults.set(showsFullURL, forKey: Self.fullURLDefaultsKey)
        }
    }

    init(defaults: UserDefaults = OrbitDefaults.standard) {
        self.defaults = defaults
        self.isVisible = (defaults.object(forKey: Self.visibilityDefaultsKey) as? Bool) ?? true
        self.showsFullURL = (defaults.object(forKey: Self.fullURLDefaultsKey) as? Bool) ?? false
    }

    @discardableResult
    func toggleVisible() -> Bool {
        isVisible.toggle()
        return isVisible
    }

    @discardableResult
    func toggleFullURL() -> Bool {
        showsFullURL.toggle()
        return showsFullURL
    }

    var visibilityMenuTitle: String {
        isVisible ? "Hide Toolbar" : "Show Toolbar"
    }

    var fullURLMenuTitle: String {
        showsFullURL ? "Hide Full URL" : "Show Full URL"
    }
}

enum ToolbarAddressText {

    static let placeholder = "Search or Enter URL..."

    static func text(for url: URL, showsFullURL: Bool) -> String? {
        // Checked before the internal-surface guard below: a document page is itself an orbit:// URL, so folding this into that guard would fall it back to the dim placeholder instead.
        if OrbitInternalPageChrome.isDocumentPage(url) {
            return OrbitInternalPageChrome.addressText
        }
        guard url.scheme != "orbit", url.scheme != "view-source" else { return nil }
        guard let host = url.host(), !host.isEmpty else { return nil }
        guard showsFullURL else { return host }

        var text = host
        let path = url.path()
        if !path.isEmpty, path != "/" {
            text += path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        if let query = url.query(), !query.isEmpty { text += "?" + query }
        if let fragment = url.fragment(), !fragment.isEmpty { text += "#" + fragment }
        return text
    }
}
