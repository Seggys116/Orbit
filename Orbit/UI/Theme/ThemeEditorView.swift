import SwiftUI

struct ThemeEditorView: View {
    @Binding var theme: SpaceTheme
    var spaceID: SpaceID?
    var onDone: (() -> Void)?

    // Not part of the frozen SpaceTheme contract, so seeded from and written
    // back to SpaceVisualPrefsStore only when spaceID is non-nil.
    @State private var blur: Double
    // Always read/written through selectedStopIndexBinding below, so it
    // stays clamped into theme.colors's bounds after any palette change.
    @State private var selectedStopIndex = 0
    @State private var hoveredAppearanceScheme: ColorScheme?

    @Environment(\.colorScheme) private var colorScheme

    init(theme: Binding<SpaceTheme>, spaceID: SpaceID? = nil, onDone: (() -> Void)? = nil) {
        _theme = theme
        self.spaceID = spaceID
        self.onDone = onDone
        _blur = State(initialValue: spaceID.map { SpaceVisualPrefsStore.shared.blur(for: $0) } ?? 0)
    }

    private var effectiveScheme: ColorScheme {
        theme.followsSystemAppearance ? colorScheme : (theme.prefersDarkContent ? .dark : .light)
    }

    private var previewScheme: ColorScheme {
        hoveredAppearanceScheme ?? effectiveScheme
    }

    private var selectedStopIndexBinding: Binding<Int> {
        Binding(
            get: { SpaceTheme.clampedStopIndex(selectedStopIndex, count: theme.colors.count) },
            set: { selectedStopIndex = SpaceTheme.clampedStopIndex($0, count: theme.colors.count) }
        )
    }

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            ThemeStopCanvasView(
                theme: $theme,
                selectedStopIndex: selectedStopIndexBinding,
                previewScheme: previewScheme,
                blur: blur
            ) {
                appearanceRow
            }
            .frame(maxWidth: .infinity)

            ThemeSwatchStripView(theme: $theme, selectedStopIndex: selectedStopIndexBinding)

            controlsRow

            footer
        }
        .padding(14)
        .frame(width: 380)
        .onChange(of: blur) { _, newValue in
            if let spaceID { SpaceVisualPrefsStore.shared.setBlur(newValue, for: spaceID) }
        }
    }

    // MARK: Appearance row

    private var appearanceRow: some View {
        HStack(spacing: 6) {
            appearanceButton(
                symbol: "sparkles",
                isSelected: theme.followsSystemAppearance,
                previewScheme: nil,
                accessibilityLabel: "Follow system appearance"
            ) {
                withAnimation(OrbitMotion.quick) { theme.followsSystemAppearance = true }
            }
            appearanceButton(
                symbol: "sun.max",
                isSelected: !theme.followsSystemAppearance && !theme.prefersDarkContent,
                previewScheme: .light,
                accessibilityLabel: "Light appearance"
            ) {
                withAnimation(OrbitMotion.quick) {
                    theme.followsSystemAppearance = false
                    theme.prefersDarkContent = false
                }
            }
            appearanceButton(
                symbol: "moon",
                isSelected: !theme.followsSystemAppearance && theme.prefersDarkContent,
                previewScheme: .dark,
                accessibilityLabel: "Dark appearance"
            ) {
                withAnimation(OrbitMotion.quick) {
                    theme.followsSystemAppearance = false
                    theme.prefersDarkContent = true
                }
            }
        }
    }

    @ViewBuilder
    private func appearanceButton(
        symbol: String,
        isSelected: Bool,
        previewScheme: ColorScheme?,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        ThemeAppearanceIconButton(symbol: symbol, isSelected: isSelected, colorScheme: colorScheme, action: action)
            .onHover { hovering in
                guard let previewScheme else { return }
                withAnimation(OrbitMotion.quick) {
                    if hovering {
                        hoveredAppearanceScheme = previewScheme
                    } else if hoveredAppearanceScheme == previewScheme {
                        hoveredAppearanceScheme = nil
                    }
                }
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Wave slider + softness dial

    private var controlsRow: some View {
        HStack(spacing: 14) {
            ThemeWaveSlider(value: $theme.grain, colorScheme: colorScheme)
                .frame(maxWidth: .infinity)

            ThemeRotaryDial(
                value: $blur,
                range: 0...1,
                angleRange: -135...135,
                accessibilityLabel: "Softness",
                accessibilityValueDescription: { "\(Int(($0 * 100).rounded()))%" },
                helpText: "Background softness (blur). The knob's own grainy texture previews the theme's grain amount, not the softness value itself.",
                colorScheme: colorScheme
            ) {
                // A mid-grey backdrop plus grainPreviewLayerCount stacked
                // GrainOverlay copies make the deliberately faint grain
                // texture read at the dial's small inner diameter.
                ZStack {
                    Circle().fill(Color(white: 0.55))
                    ForEach(0..<Self.grainPreviewLayerCount, id: \.self) { _ in
                        GrainOverlay(opacity: theme.grain, isDarkSurface: theme.isDarkSurface(for: previewScheme))
                    }
                }
            }
        }
        .frame(height: 56)
    }

    private static let grainPreviewLayerCount = 5

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            OrbitSegmentedControl(
                options: SpaceTheme.Style.allCases,
                label: { $0.themeEditorLabel },
                selection: $theme.style,
                accessibilityLabel: "Gradient style"
            )
            .frame(maxWidth: .infinity)

            ThemeRotaryDial(
                value: $theme.angle,
                range: 0...360,
                angleRange: 0...360,
                accessibilityLabel: "Rotation",
                accessibilityValueDescription: { "\(Int($0.rounded())) degrees" },
                helpText: "Gradient rotation angle",
                colorScheme: colorScheme
            )
            .opacity(theme.style == .solid ? 0.35 : 1)
            .disabled(theme.style == .solid)

            if let onDone {
                Spacer(minLength: 10)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private extension SpaceTheme.Style {
    var themeEditorLabel: String {
        switch self {
        case .solid: return "Solid"
        case .linear: return "Linear"
        case .mesh: return "Mesh"
        }
    }
}

private struct ThemeAppearanceIconButton: View {
    var symbol: String
    var isSelected: Bool
    var colorScheme: ColorScheme
    var action: () -> Void

    @State private var isHovering = false

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.07)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 34, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? selectedFill : (isHovering ? selectedFill.opacity(0.5) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#if DEBUG
#Preview {
    ThemeEditorView(theme: .constant(SpaceTheme()), onDone: {})
}
#endif
