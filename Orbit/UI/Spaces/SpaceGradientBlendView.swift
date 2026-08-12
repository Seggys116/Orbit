import SwiftUI

struct SpaceGradientBlendView: View {
    var theme: SpaceTheme
    var opacity: Double
    var blur: Double = 0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ThemePaintView(theme: theme, colorScheme: colorScheme)
                .blur(radius: CGFloat(blur * 46))
            GrainOverlay(opacity: theme.grain)
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}
