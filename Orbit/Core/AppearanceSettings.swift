import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppearanceSettings {

    // Raw values are the persisted representation — changing one silently resets every existing user to .automatic.
    enum Appearance: String, CaseIterable, Sendable {
        case automatic
        case light
        case dark

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    static let captionTitle = "Websites, Easels, and Notes will use:"

    #if DEBUG
    static var shared = AppearanceSettings()
    #else
    static let shared = AppearanceSettings()
    #endif

    static let defaultsKey = "OrbitContentAppearance"

    @ObservationIgnored private let defaults: UserDefaults

    // Persists but does not push to live renderers — call choose(_:), not this, from anywhere but init.
    var selection: Appearance {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: Self.defaultsKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey)
        self.selection = stored.flatMap(Appearance.init(rawValue:)) ?? .automatic
    }

    // MARK: - What the preference resolves to

    /// nil means no override.
    var engineColorScheme: ContentColorScheme? {
        switch selection {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func documentColorScheme(system: ColorScheme) -> ColorScheme {
        switch selection {
        case .automatic: return system
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: - Choosing

    func choose(_ appearance: Appearance) {
        selection = appearance
        AppEnvironment.applyContentAppearanceEverywhere()
        EngineAppearance.apply()
    }
}

// MARK: - The document surfaces

// Must be applied at the root of every host of a Note/Easel, not just one —
// reading AppearanceSettings.shared here is also what registers @Observable tracking for the subtree.
private struct OrbitDocumentAppearanceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(
            \.colorScheme,
            OrbitInternalPageChrome.documentColorScheme(system: colorScheme)
        )
    }
}

extension View {
    func orbitDocumentAppearance() -> some View {
        modifier(OrbitDocumentAppearanceModifier())
    }
}
