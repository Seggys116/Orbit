import AppKit
import Foundation

/// The engine never assigns a default `preferred_color_scheme`, so
/// `prefers-color-scheme` never fires for web content or DevTools unless set here.
/// Deliberately never writes the DevTools frontend's stored theme preference: a
/// theme picked inside DevTools is no longer "systemPreferred" and must keep winning.
@MainActor
enum EngineAppearance {

    /// Orbit's own appearance choice, not the system's raw value, so a forced
    /// light/dark stays consistent with the chrome — matches Chrome's own behaviour.
    static var isDark: Bool {
        switch AppearanceSettings.shared.selection {
        case .light: return false
        case .dark: return true
        case .automatic: return systemIsDark
        }
    }

    static var systemIsDark: Bool {
        guard let app = NSApp else { return false }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Pushes the current answer down to the engine. Cheap and idempotent --
    /// the engine ignores a value it already holds -- so callers do not have
    /// to track whether anything changed.
    static func apply() {
        OrbitChromiumBridge.shared.setColorScheme(isDark: isDark)
    }

    /// One process-wide observer, deliberately not one per surface: the value
    /// it maintains is process-global, so there is nothing to tear down when a
    /// tab or inspector closes and nothing that can fire into a dead one.
    static func startObserving() {
        guard observation == nil, let app = NSApp else { return }
        observation = app.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            MainActor.assumeIsolated { apply() }
        }
        apply()
    }

    private static var observation: NSKeyValueObservation?
}
