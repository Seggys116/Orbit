import SwiftUI

/// What the reload glyph does in response to a click, kept apart from the view so the rule can be tested.
struct ReloadGlyphMotion: Equatable {
    /// Full turns the glyph has made. Each one is a click that started a reload.
    private(set) var turns = 0

    static let turnDuration: TimeInterval = 0.55

    var degrees: Double { Double(turns) * 360 }

    /// A click on the stop button has nothing to reload and must not spin the glyph.
    mutating func clicked(isLoading: Bool) {
        guard !isLoading else { return }
        turns += 1
    }

    static func symbolName(isLoading: Bool) -> String {
        isLoading ? "xmark" : "arrow.clockwise"
    }

    /// Reduce Motion keeps the symbol change and drops the spin.
    static func turnAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.3, 0.0, 0.2, 1.0, duration: turnDuration)
    }

    static func swapAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.01) : OrbitMotion.quick
    }
}

/// Reload while idle, stop while loading. The glyph turns once when a reload starts and cross-fades into the stop mark, instead of changing between the two in a single frame.
struct ToolbarReloadButton: View {
    var isLoading: Bool
    var foreground: Color
    var hoverFill: Color
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = ReloadGlyphMotion()

    var body: some View {
        OrbitNSActionButton(action: {
            motion.clicked(isLoading: isLoading)
            action()
        }) {
            Image(systemName: ReloadGlyphMotion.symbolName(isLoading: isLoading))
                .font(.system(size: OrbitToolbarMetrics.navGlyphSize, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .rotationEffect(.degrees(motion.degrees))
                .animation(ReloadGlyphMotion.turnAnimation(reduceMotion: reduceMotion), value: motion.turns)
                .animation(ReloadGlyphMotion.swapAnimation(reduceMotion: reduceMotion), value: isLoading)
                .frame(width: OrbitToolbarMetrics.navIconSize, height: OrbitToolbarMetrics.navIconSize)
        }
        .foregroundStyle(foreground)
        .orbitHoverHighlight(
            fill: hoverFill,
            cornerRadius: OrbitToolbarMetrics.hoverHighlightCornerRadius
        )
        .accessibilityLabel(isLoading ? "Stop Loading" : "Reload")
    }
}
