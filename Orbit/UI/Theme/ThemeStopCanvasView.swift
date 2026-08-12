import SwiftUI

struct ThemeStopCanvasView<AppearanceRow: View>: View {
    @Binding var theme: SpaceTheme
    @Binding var selectedStopIndex: Int
    var previewScheme: ColorScheme
    var blur: Double
    var appearanceRow: () -> AppearanceRow

    @FocusState private var focusedStop: Int?

    // Without this, moveStop snaps the orb's centre to the pointer on grab.
    @State private var dragGrabOffset: CGSize?

    init(
        theme: Binding<SpaceTheme>,
        selectedStopIndex: Binding<Int>,
        previewScheme: ColorScheme,
        blur: Double,
        @ViewBuilder appearanceRow: @escaping () -> AppearanceRow
    ) {
        self._theme = theme
        self._selectedStopIndex = selectedStopIndex
        self.previewScheme = previewScheme
        self.blur = blur
        self.appearanceRow = appearanceRow
    }

    // Computed: generic types cannot have static stored properties.
    private static var coordinateSpaceName: String { "orbit.themeEditor.stopCanvas" }
    private static var cornerRadius: CGFloat { 16 }
    private static var height: CGFloat { 344 }
    private static var selectedDiameter: CGFloat { 62 }
    private static var unselectedDiameter: CGFloat { 34 }
    private static var selectedBorderWidth: CGFloat { 5 }
    private static var unselectedBorderWidth: CGFloat { 4 }
    private static var edgeInset: CGFloat { 6 }
    private static var keyboardNudgeStep: Double { 0.02 }
    private static var countControlSpacing: CGFloat { 44 }
    private static var countButtonBottomInset: CGFloat { 16 }
    private static var appearanceRowTopInset: CGFloat { 18 }
    private static var minimumStopCount: Int { 1 }
    private static var maximumStopCount: Int { 4 }

    private var isDarkSurface: Bool { theme.isDarkSurface(for: previewScheme) }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ThemePaintView(theme: theme, colorScheme: previewScheme)
                    .blur(radius: CGFloat(blur * 24))
                GrainOverlay(opacity: theme.grain, isDarkSurface: isDarkSurface)
                ThemeCanvasDotGrid(isDarkSurface: isDarkSurface)
                    .allowsHitTesting(false)

                ForEach(Array(theme.colors.enumerated()), id: \.offset) { index, themeColor in
                    orb(index: index, themeColor: themeColor, canvasSize: proxy.size)
                }
            }
            .coordinateSpace(.named(Self.coordinateSpaceName))
            .overlay(alignment: .top) {
                appearanceRow()
                    .padding(.top, Self.appearanceRowTopInset)
            }
            .overlay(alignment: .bottom) {
                stopCountControls
                    .padding(.bottom, Self.countButtonBottomInset)
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .onChange(of: focusedStop) { _, newValue in
            if let newValue { selectedStopIndex = newValue }
        }
    }

    // MARK: Orbs

    // .position(point) must stay the very last modifier: it returns a view
    // that fills its parent, so anything chained after it applies to the
    // whole canvas instead of this orb.
    @ViewBuilder
    private func orb(index: Int, themeColor: ThemeColor, canvasSize: CGSize) -> some View {
        let positions = theme.resolvedStopPositions
        if positions.indices.contains(index) {
            let position = positions[index]
            let isSelected = index == selectedStopIndex
            let isKeyboardFocused = focusedStop == index
            let diameter = isSelected ? Self.selectedDiameter : Self.unselectedDiameter
            let borderWidth = isSelected ? Self.selectedBorderWidth : Self.unselectedBorderWidth
            let point = CGPoint(x: position.x * canvasSize.width, y: position.y * canvasSize.height)

            Circle()
                .fill(Color(themeColor.nsColor))
                .frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: borderWidth))
                .overlay(
                    Circle()
                        .strokeBorder(
                            isDarkSurface ? Color.white.opacity(0.45) : Color.black.opacity(0.30),
                            lineWidth: isKeyboardFocused ? 2 : 0
                        )
                        .padding(-5)
                )
                .shadow(
                    color: .black.opacity(isSelected ? 0.28 : 0.18),
                    radius: isSelected ? 6 : 3,
                    y: isSelected ? 2 : 1
                )
                .contentShape(Circle())
                .focusable(true)
                .focusEffectDisabled()
                .focused($focusedStop, equals: index)
                .onTapGesture {
                    withAnimation(OrbitMotion.quick) { selectedStopIndex = index }
                }
                .gesture(
                    // minimumDistance: 0 also fires once on mouse-down with
                    // translation == .zero; only write a position once
                    // translation is non-zero, or a click teleports the stop.
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                        .onChanged { drag in
                            selectedStopIndex = index
                            guard drag.translation != .zero else {
                                dragGrabOffset = CGSize(
                                    width: drag.startLocation.x - point.x,
                                    height: drag.startLocation.y - point.y
                                )
                                return
                            }
                            let grab = dragGrabOffset ?? .zero
                            moveStop(
                                index: index,
                                to: CGPoint(x: drag.location.x - grab.width, y: drag.location.y - grab.height),
                                canvasSize: canvasSize
                            )
                        }
                        .onEnded { _ in dragGrabOffset = nil }
                )
                .onKeyPress(.leftArrow) { nudgeStop(index: index, dx: -Self.keyboardNudgeStep, dy: 0); return .handled }
                .onKeyPress(.rightArrow) { nudgeStop(index: index, dx: Self.keyboardNudgeStep, dy: 0); return .handled }
                .onKeyPress(.upArrow) { nudgeStop(index: index, dx: 0, dy: -Self.keyboardNudgeStep); return .handled }
                .onKeyPress(.downArrow) { nudgeStop(index: index, dx: 0, dy: Self.keyboardNudgeStep); return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Colour stop \(index + 1)")
                .accessibilityValue(accessibilityValueDescription(color: themeColor, position: position))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .animation(OrbitMotion.quick, value: isSelected)
                .position(point)
        }
    }

    private func moveStop(index: Int, to location: CGPoint, canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let margin = Self.selectedDiameter / 2 + Self.edgeInset
        let minX = margin
        let maxX = max(canvasSize.width - margin, margin)
        let minY = margin
        let maxY = max(canvasSize.height - margin, margin)
        let clampedX = min(max(location.x, minX), maxX)
        let clampedY = min(max(location.y, minY), maxY)

        var positions = theme.resolvedStopPositions
        guard positions.indices.contains(index) else { return }
        positions[index] = ThemeStopPosition(x: clampedX / canvasSize.width, y: clampedY / canvasSize.height)
        theme.stopPositions = positions
    }

    private func nudgeStop(index: Int, dx: Double, dy: Double) {
        var positions = theme.resolvedStopPositions
        guard positions.indices.contains(index) else { return }
        let current = positions[index]
        positions[index] = ThemeStopPosition(x: current.x + dx, y: current.y + dy)
        theme.stopPositions = positions
        selectedStopIndex = index
    }

    private func accessibilityValueDescription(color: ThemeColor, position: ThemeStopPosition) -> String {
        let xPercent = Int((position.x * 100).rounded())
        let yPercent = Int((position.y * 100).rounded())
        return "\(hexString(color)), \(xPercent)% across, \(yPercent)% down"
    }

    private func hexString(_ color: ThemeColor) -> String {
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    // MARK: Stop count controls

    private var stopCountControls: some View {
        HStack(spacing: Self.countControlSpacing) {
            CanvasIconButton(
                systemName: "minus",
                isEnabled: theme.colors.count > Self.minimumStopCount,
                foreground: theme.readableSecondaryForeground,
                accessibilityLabel: "Remove colour stop",
                action: removeSelectedStop
            )
            CanvasIconButton(
                systemName: "plus",
                isEnabled: theme.colors.count < Self.maximumStopCount,
                foreground: theme.readableSecondaryForeground,
                accessibilityLabel: "Add colour stop",
                action: addStop
            )
        }
    }

    private func addStop() {
        guard theme.colors.count < Self.maximumStopCount else { return }
        let lastColor = theme.colors.last ?? SpaceTheme.defaultPalette[0]
        let hsb = lastColor.hsb
        let rotatedHue = (hsb.hue + 0.08).truncatingRemainder(dividingBy: 1.0)
        let newColor = ThemeColor(NSColor(
            hue: CGFloat(rotatedHue < 0 ? rotatedHue + 1 : rotatedHue),
            saturation: CGFloat(hsb.saturation),
            brightness: CGFloat(hsb.brightness),
            alpha: 1
        ))

        let existingPositions = theme.resolvedStopPositions
        let newCount = theme.colors.count + 1
        let newSlotPosition = SpaceTheme.defaultStopPositions(count: newCount).last ?? ThemeStopPosition(x: 0.5, y: 0.5)

        withAnimation(OrbitMotion.quick) {
            theme.colors.append(newColor)
            theme.stopPositions = existingPositions + [newSlotPosition]
            selectedStopIndex = theme.colors.count - 1
        }
        theme.normalizeStopPositions()
    }

    private func removeSelectedStop() {
        guard theme.colors.count > Self.minimumStopCount else { return }
        let indexToRemove = SpaceTheme.clampedStopIndex(selectedStopIndex, count: theme.colors.count)
        var positions = theme.resolvedStopPositions

        withAnimation(OrbitMotion.quick) {
            theme.colors.remove(at: indexToRemove)
            if positions.indices.contains(indexToRemove) {
                positions.remove(at: indexToRemove)
            }
            theme.stopPositions = positions
            selectedStopIndex = SpaceTheme.clampedStopIndex(indexToRemove, count: theme.colors.count)
        }
        theme.normalizeStopPositions()
    }
}

private struct CanvasIconButton: View {
    var systemName: String
    var isEnabled: Bool
    var foreground: Color
    var accessibilityLabel: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isHovering && isEnabled ? Color.white.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : OrbitControlMetrics.buttonDisabledOpacity)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ThemeCanvasDotGrid: View {
    var isDarkSurface: Bool

    private static let spacing: CGFloat = 7
    private static let dotDiameter: CGFloat = 1.4

    var body: some View {
        Canvas { context, size in
            let color = isDarkSurface ? Color.white.opacity(0.18) : Color.black.opacity(0.14)
            let radius = Self.dotDiameter / 2
            var y = Self.spacing / 2
            while y < size.height {
                var x = Self.spacing / 2
                while x < size.width {
                    let rect = CGRect(x: x - radius, y: y - radius, width: Self.dotDiameter, height: Self.dotDiameter)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    x += Self.spacing
                }
                y += Self.spacing
            }
        }
    }
}
