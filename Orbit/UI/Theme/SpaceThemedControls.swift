import SwiftUI

/// Reports the pressed state to the label through the environment, so a tile inside the label can show it.
struct OrbitPressReportingButtonStyle: ButtonStyle {
    var dimsOnPress: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.orbitControlPressed, configuration.isPressed)
            .opacity(dimsOnPress && configuration.isPressed ? 0.6 : 1)
    }
}

struct OrbitThemedTileBackground: ViewModifier {
    var chrome: SpaceThemeChrome?
    var cornerRadius: CGFloat
    var dimsWhenDisabled = true

    static let legacyFill = Color.secondary.opacity(0.12)

    @Environment(\.orbitControlPressed) private var isPressed
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var fill: Color {
        guard let chrome else { return Self.legacyFill }
        if isPressed { return chrome.pressedFill }
        if isHovering && isEnabled { return chrome.hoverFill }
        return chrome.restFill
    }

    private var opacity: Double {
        guard dimsWhenDisabled, !isEnabled else { return 1 }
        return chrome?.disabledOpacity ?? OrbitControlMetrics.buttonDisabledOpacity
    }

    func body(content: Content) -> some View {
        let motion = OrbitThemeMotion.animation(reduceMotion: reduceMotion, token: OrbitMotion.quick)
        return content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .opacity(opacity)
            .onHover { hovering in
                if chrome != nil { isHovering = hovering }
            }
            .animation(motion, value: isHovering)
            .animation(motion, value: isPressed)
    }
}

/// Hover and pressed wash of a settings row; draws nothing without a theme, so the system look is untouched.
struct OrbitThemedRowHighlight: ViewModifier {
    var chrome: SpaceThemeChrome?
    var cornerRadius: CGFloat

    @Environment(\.orbitControlPressed) private var isPressed
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var fill: Color {
        guard let chrome, isEnabled else { return .clear }
        if isPressed { return chrome.pressedFill }
        return isHovering ? chrome.hoverFill : .clear
    }

    func body(content: Content) -> some View {
        let motion = OrbitThemeMotion.animation(reduceMotion: reduceMotion, token: OrbitMotion.quick)
        return content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .opacity(isEnabled ? 1 : chrome?.disabledOpacity ?? OrbitControlMetrics.buttonDisabledOpacity)
            .onHover { hovering in
                if chrome != nil { isHovering = hovering }
            }
            .animation(motion, value: isHovering)
            .animation(motion, value: isPressed)
    }
}

struct OrbitThemedSurface: ViewModifier {
    var chrome: SpaceThemeChrome?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let chrome {
            content
                .foregroundStyle(chrome.foreground)
                .background { chrome.surface.ignoresSafeArea() }
                .presentationBackground(chrome.surface)
        } else {
            content
        }
    }
}

extension OrbitMenuThemeSource {
    /// The menu panel inherits no SwiftUI environment, so it learns the Space theme through this provider.
    func adopt(environment: AppEnvironment, spaceID: SpaceID) {
        provider = { [weak environment] in
            environment?.space(spaceID)?.theme ?? environment?.activeSpace?.theme
        }
    }
}

extension View {
    func orbitThemedTile(_ chrome: SpaceThemeChrome?, cornerRadius: CGFloat, dimsWhenDisabled: Bool = true) -> some View {
        modifier(OrbitThemedTileBackground(chrome: chrome, cornerRadius: cornerRadius, dimsWhenDisabled: dimsWhenDisabled))
    }

    func orbitThemedRowHighlight(_ chrome: SpaceThemeChrome?, cornerRadius: CGFloat) -> some View {
        modifier(OrbitThemedRowHighlight(chrome: chrome, cornerRadius: cornerRadius))
    }

    func orbitThemedSurface(_ chrome: SpaceThemeChrome?) -> some View {
        modifier(OrbitThemedSurface(chrome: chrome))
    }
}
