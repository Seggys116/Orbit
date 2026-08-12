import SwiftUI

struct SpaceIconView: View {
    var icon: SpaceIcon
    var size: CGFloat
    var foregroundColor: Color = .primary
    var opacity: Double = 1

    // Optional: this view also renders in hosting contexts with no injected
    // environment (menus, drag previews), where the process root owns the
    // same store the injected environment would have handed over.
    @Environment(AppEnvironment.self) private var injectedEnvironment: AppEnvironment?

    private var imageStore: SpaceIconImageStore {
        injectedEnvironment?.spaceIconImages ?? AppEnvironment.processRoot.spaceIconImages
    }

    var body: some View {
        content.opacity(opacity)
    }

    @ViewBuilder
    private var content: some View {
        switch icon {
        case .none:
            dot
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: size * OrbitMetrics.spaceIconEmojiScaleFraction))
                .lineLimit(1)
                .frame(width: size, height: size, alignment: .center)
        case .symbol(let symbol):
            // Falls back to `dot`: `Image(systemName:)` draws nothing for an unresolvable name.
            if OrbitSymbolName.isResolvable(symbol) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(foregroundColor)
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
            .fill(foregroundColor)
            .frame(width: size * SpaceIconView.dotDiameterFraction, height: size * SpaceIconView.dotDiameterFraction)
    }

    static let dotDiameterFraction: CGFloat = 0.45
    static let imageCornerRadiusFraction: CGFloat = 0.22
}
