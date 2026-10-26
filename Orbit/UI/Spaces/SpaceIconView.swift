import SwiftUI

struct SpaceIconView: View {
    var icon: SpaceIcon
    var size: CGFloat
    var foregroundColor: Color = .primary
    var dim: Double = 0
    var emojiScale: CGFloat = OrbitMetrics.spaceIconEmojiScaleFraction
    var symbolScale: CGFloat = OrbitMetrics.spaceIconSymbolScaleFraction

    // Optional: this view also renders in hosting contexts with no injected
    // environment (menus, drag previews), where the process root owns the
    // same store the injected environment would have handed over.
    @Environment(AppEnvironment.self) private var injectedEnvironment: AppEnvironment?

    private var imageStore: SpaceIconImageStore {
        injectedEnvironment?.spaceIconImages ?? AppEnvironment.processRoot.spaceIconImages
    }

    var body: some View {
        content.brightness(-OrbitMetrics.spacePagerInactiveBrightnessDrop * dim)
    }

    private var glyphColor: Color {
        foregroundColor.opacity(1 - (1 - OrbitMetrics.spacePagerInactiveOpacity) * dim)
    }

    @ViewBuilder
    private var content: some View {
        switch icon {
        case .none:
            dot
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: size * emojiScale))
                .lineLimit(1)
                .frame(width: size, height: size, alignment: .center)
        case .symbol(let symbol):
            // Falls back to `dot`: `Image(systemName:)` draws nothing for an unresolvable name.
            if OrbitSymbolName.isResolvable(symbol) {
                // .resizable() + .aspectRatio(.fit), not a fixed .font(size:): some symbols (a display
                // or tv glyph, for instance) are natively wider than tall, so a point-size scale alone
                // still overflows a square box on the long axis. Fitting guarantees every symbol's own
                // aspect ratio stays inside the size x size box the hosting layer clips to.
                Image(systemName: symbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.semibold)
                    .foregroundStyle(glyphColor)
                    .frame(
                        width: size * symbolScale,
                        height: size * symbolScale
                    )
                    // Every sibling case below frames itself to size x size; without this the glyph's own
                    // tight bounding box (which varies per symbol) becomes what the caller centers, not size.
                    .frame(width: size, height: size, alignment: .center)
            } else {
                dot
            }
        case .image(let imageID):
            if let nsImage = imageStore.cachedImage(for: imageID) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * SpaceIconView.imageCornerRadiusFraction))
            } else {
                dot // Evicted, or synced in before the source upload finished.
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(glyphColor)
            .frame(width: size * SpaceIconView.dotDiameterFraction, height: size * SpaceIconView.dotDiameterFraction)
    }

    static let dotDiameterFraction: CGFloat = 0.45
    static let imageCornerRadiusFraction: CGFloat = 0.22
}
