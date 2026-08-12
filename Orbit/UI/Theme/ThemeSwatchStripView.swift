import SwiftUI

struct ThemeSwatchStripView: View {
    @Binding var theme: SpaceTheme
    @Binding var selectedStopIndex: Int

    // ColorPicker's NSColorPanel would steal key status from the
    // transient NSPopover this view lives in and dismiss it; this is a
    // nested SwiftUI popover instead, which stays inside the same window.
    @State private var isCustomEditorPresented = false

    @State private var page: Page = .colours

    private static let swatchDiameter: CGFloat = 26
    private static let chevronWidth: CGFloat = 20
    private static let chevronHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                chevron(systemName: "chevron.left", label: "Previous colour page", action: pageBackward)
                HStack(spacing: innerSpacing) {
                    ForEach(0..<slotCount, id: \.self) { slot in
                        slotSwatch(slot)
                    }
                    customSwatch
                }
                chevron(systemName: "chevron.right", label: "Next colour page", action: pageForward)
            }
            Text(page.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var innerSpacing: CGFloat {
        page == .colours ? 4 : 7
    }

    // MARK: Paging

    private enum Page: Int, CaseIterable {
        case palettes, colours, muted

        var label: String {
            switch self {
            case .palettes: return "Palettes"
            case .colours: return "Colours"
            case .muted: return "Muted"
            }
        }
    }

    private var slotCount: Int {
        switch page {
        case .palettes: return ThemeSwatchStripView.curatedPalettes.count
        case .colours: return ThemeSwatchStripView.vividSwatchColors.count
        case .muted: return ThemeSwatchStripView.mutedSwatchColors.count
        }
    }

    private func pageForward() {
        withAnimation(OrbitMotion.quick) {
            page = Page(rawValue: Self.wrappedPageIndex(page.rawValue, by: 1, count: Page.allCases.count)) ?? .palettes
        }
    }

    private func pageBackward() {
        withAnimation(OrbitMotion.quick) {
            page = Page(rawValue: Self.wrappedPageIndex(page.rawValue, by: -1, count: Page.allCases.count)) ?? .palettes
        }
    }

    static func wrappedPageIndex(_ current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((current + delta) % count + count) % count
    }

    private func chevron(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.chevronWidth, height: Self.chevronHeight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Slots

    @ViewBuilder
    private func slotSwatch(_ slot: Int) -> some View {
        switch page {
        case .palettes:
            if ThemeSwatchStripView.curatedPalettes.indices.contains(slot) {
                paletteSwatch(ThemeSwatchStripView.curatedPalettes[slot], index: slot)
            }
        case .colours:
            if ThemeSwatchStripView.vividSwatchColors.indices.contains(slot) {
                singleColorSwatch(ThemeSwatchStripView.vividSwatchColors[slot])
            }
        case .muted:
            if ThemeSwatchStripView.mutedSwatchColors.indices.contains(slot) {
                singleColorSwatch(ThemeSwatchStripView.mutedSwatchColors[slot])
            }
        }
    }

    private func paletteSwatch(_ palette: [ThemeColor], index: Int) -> some View {
        let isSelected = theme.resolvedPalette == palette
        return Button {
            withAnimation(OrbitMotion.quick) {
                theme.applyPalette(palette)
            }
        } label: {
            Circle()
                .fill(
                    LinearGradient(
                        colors: palette.map { Color($0.nsColor) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: Self.swatchDiameter, height: Self.swatchDiameter)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Palette \(index + 1)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func singleColorSwatch(_ color: ThemeColor) -> some View {
        let isSelected = theme.colors.indices.contains(selectedStopIndex) && theme.colors[selectedStopIndex] == color
        return Button {
            withAnimation(OrbitMotion.quick) {
                theme.setColor(color, atStop: selectedStopIndex)
            }
        } label: {
            Circle()
                .fill(Color(color.nsColor))
                .frame(width: Self.swatchDiameter, height: Self.swatchDiameter)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assign this colour to the selected stop")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Custom colour well

    private var customSwatch: some View {
        Button {
            isCustomEditorPresented = true
        } label: {
            ZStack {
                Circle()
                    .fill(selectedStopColor)
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center
                        ),
                        lineWidth: 2.5
                    )
            }
            .frame(width: Self.swatchDiameter, height: Self.swatchDiameter)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isCustomEditorPresented, arrowEdge: .bottom) {
            ThemeCustomColorEditor(color: selectedColorBinding)
        }
        .orbitTooltip("Custom colour for the selected stop")
        .accessibilityLabel("Custom colour for the selected stop")
    }

    private var selectedStopColor: Color {
        guard theme.colors.indices.contains(selectedStopIndex) else {
            return Color(SpaceTheme.defaultPalette[0].nsColor)
        }
        return Color(theme.colors[selectedStopIndex].nsColor)
    }

    private var selectedColorBinding: Binding<Color> {
        Binding(
            get: { selectedStopColor },
            set: { newColor in
                theme.setColor(ThemeColor(NSColor(newColor)), atStop: selectedStopIndex)
            }
        )
    }

    // MARK: - Curated complementary palettes

    private static let curatedPalettes: [[ThemeColor]] = [
        SpaceTheme.defaultPalette,
        [ThemeColor(red: 0.157, green: 0.176, blue: 0.216), ThemeColor(red: 0.196, green: 0.216, blue: 0.251)],
        [ThemeColor(red: 0.145, green: 0.133, blue: 0.129), ThemeColor(red: 0.196, green: 0.180, blue: 0.173)],
        [ThemeColor(red: 0.145, green: 0.176, blue: 0.161), ThemeColor(red: 0.192, green: 0.220, blue: 0.204)],
        [ThemeColor(red: 0.192, green: 0.145, blue: 0.165), ThemeColor(red: 0.239, green: 0.188, blue: 0.208)],
        [ThemeColor(red: 0.157, green: 0.192, blue: 0.200)],
        [ThemeColor(red: 0.36, green: 0.42, blue: 0.95), ThemeColor(red: 0.62, green: 0.38, blue: 0.92), ThemeColor(red: 0.94, green: 0.47, blue: 0.66)],
        [ThemeColor(red: 0.98, green: 0.65, blue: 0.42), ThemeColor(red: 0.96, green: 0.42, blue: 0.42)],
    ]

    // MARK: - Generated single dark swatches ("Muted" page)

    private static let mutedHueArcLowDegrees = 140.0
    private static let mutedHueArcSpanDegrees = 250.0
    private static let mutedChromaRequest = 150.0

    private static let mutedSwatchColors: [ThemeColor] = (0..<8).map { index in
        let hue = (mutedHueArcLowDegrees + Double(index) / 8.0 * mutedHueArcSpanDegrees)
            .truncatingRemainder(dividingBy: 360)
        return gamutMappedSwatchColor(lightness: 24, hueDegrees: hue, chromaRequest: mutedChromaRequest)
    }

    private static func gamutMappedSwatchColor(lightness: Double, hueDegrees: Double, chromaRequest: Double) -> ThemeColor {
        func candidate(_ chroma: Double) -> ThemeColor {
            let radians = hueDegrees * .pi / 180
            return ThemeColor(lab: (lightness: lightness, a: chroma * cos(radians), b: chroma * sin(radians)))
        }
        let atRequestedChroma = candidate(chromaRequest)
        guard !atRequestedChroma.isWithinSRGBGamut else { return atRequestedChroma }

        var passing = 0.0
        var failing = chromaRequest
        for _ in 0..<32 {
            let midpoint = (passing + failing) / 2
            if candidate(midpoint).isWithinSRGBGamut {
                passing = midpoint
            } else {
                failing = midpoint
            }
        }
        return candidate(passing).clampedToUnitRange
    }

    // MARK: - Arc's own sampled palette ("Colours" page)

    private static let vividSwatchColors: [ThemeColor] = [
        ThemeColor(red: 0.945, green: 0.918, blue: 0.906), // cream / off-white
        ThemeColor(red: 0.871, green: 0.631, blue: 0.718), // pink
        ThemeColor(red: 0.600, green: 0.463, blue: 0.596), // mauve-purple
        ThemeColor(red: 0.835, green: 0.427, blue: 0.447), // red
        ThemeColor(red: 0.894, green: 0.557, blue: 0.424), // orange
        ThemeColor(red: 0.941, green: 0.839, blue: 0.514), // yellow
        ThemeColor(red: 0.565, green: 0.886, blue: 0.651), // green
        ThemeColor(red: 0.529, green: 0.718, blue: 0.820), // blue
        ThemeColor(red: 0.392, green: 0.404, blue: 0.514), // dark navy
    ]
}

private struct ThemeCustomColorEditor: View {
    @Binding var color: Color

    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double

    init(color: Binding<Color>) {
        _color = color
        let components = NSColor(color.wrappedValue).usingColorSpace(.sRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        components.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        _hue = State(initialValue: Double(h))
        _saturation = State(initialValue: Double(s))
        _brightness = State(initialValue: Double(b))
    }

    private var composed: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(composed)
                .frame(height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )

            channel(
                label: "Hue",
                value: $hue,
                track: LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
                        .map { Color(hue: $0, saturation: 1, brightness: 1) },
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            channel(
                label: "Saturation",
                value: $saturation,
                track: LinearGradient(
                    colors: [Color(hue: hue, saturation: 0, brightness: brightness),
                             Color(hue: hue, saturation: 1, brightness: brightness)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            channel(
                label: "Brightness",
                value: $brightness,
                track: LinearGradient(
                    colors: [Color(hue: hue, saturation: saturation, brightness: 0),
                             Color(hue: hue, saturation: saturation, brightness: 1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .padding(14)
        .frame(width: 240)
        .onChange(of: hue) { _, _ in color = composed }
        .onChange(of: saturation) { _, _ in color = composed }
        .onChange(of: brightness) { _, _ in color = composed }
    }

    private func channel(label: String, value: Binding<Double>, track: LinearGradient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                Capsule()
                    .fill(track)
                    .frame(height: 10)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                            .offset(x: CGFloat(value.wrappedValue) * width - 7)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                value.wrappedValue = min(max(Double(drag.location.x / width), 0), 1)
                            }
                    )
                    .frame(height: 14)
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let step = 0.05
                switch direction {
                case .increment: value.wrappedValue = min(value.wrappedValue + step, 1)
                case .decrement: value.wrappedValue = max(value.wrappedValue - step, 0)
                @unknown default: break
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    ThemeSwatchStripView(theme: .constant(SpaceTheme()), selectedStopIndex: .constant(0))
        .padding()
        .frame(width: 380)
        .background(Color.black)
}
#endif
