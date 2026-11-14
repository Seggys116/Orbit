import SwiftUI

struct OnboardingStageArt: View {
    var scene: OnboardingPlanetScene

    var body: some View {
        GlyphPlanetView(
            palette: scene.palette,
            tiltDegrees: scene.tiltDegrees,
            bands: scene.bands,
            fill: scene.fill
        )
        .clipped()
    }
}
