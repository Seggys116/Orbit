import Foundation

/// The step picks the base palette, tilt and band count; live signals (import progress, the Space being themed, shortcuts tried) adjust it.
nonisolated struct OnboardingPlanetScene: Equatable, Sendable {
    var palette: GlyphPlanetPalette
    var tiltDegrees: Double
    var bands: Double
    var fill: Double

    static let tiltPerShortcut = 6.0

    static func scene(
        step: OnboardingStep,
        importPhase: OnboardingImportPhase,
        hasImportSource: Bool,
        importFraction: Double,
        spaceTint: PlanetColor?,
        shortcutsTried: Int
    ) -> OnboardingPlanetScene {
        switch step {
        case .welcome:
            return OnboardingPlanetScene(palette: .violet, tiltDegrees: -18, bands: 10, fill: 1)
        case .importBrowser:
            return OnboardingPlanetScene(
                palette: .cyan,
                tiltDegrees: -6,
                bands: 8,
                fill: importFill(phase: importPhase, hasSource: hasImportSource, fraction: importFraction)
            )
        case .spaces:
            let palette = spaceTint.map(GlyphPlanetPalette.tinted(by:)) ?? .violet
            return OnboardingPlanetScene(palette: palette, tiltDegrees: -18, bands: 11, fill: 1)
        case .shortcuts:
            return OnboardingPlanetScene(
                palette: .amber,
                tiltDegrees: 14 + tiltPerShortcut * Double(max(shortcutsTried, 0)),
                bands: 9,
                fill: 1
            )
        case .finish:
            return OnboardingPlanetScene(palette: .violet, tiltDegrees: -28, bands: 10, fill: 1)
        }
    }

    /// With nothing to import the planet stays whole; with a source chosen it waits dim, sweeps in with progress, and is whole when done.
    static func importFill(phase: OnboardingImportPhase, hasSource: Bool, fraction: Double) -> Double {
        guard hasSource else { return 1 }
        switch phase {
        case .idle, .failed: return 0
        case .running: return min(max(fraction, 0), 1)
        case .done: return 1
        }
    }
}
