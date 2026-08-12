import SwiftUI

struct ThemeRotaryDial<InnerContent: View>: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var angleRange: ClosedRange<Double>
    var nudgeDegrees: Double = 5
    var accessibilityLabel: String
    var accessibilityValueDescription: (Double) -> String
    var helpText: String
    var colorScheme: ColorScheme
    var innerContent: () -> InnerContent

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        angleRange: ClosedRange<Double>,
        nudgeDegrees: Double = 5,
        accessibilityLabel: String,
        accessibilityValueDescription: @escaping (Double) -> String,
        helpText: String,
        colorScheme: ColorScheme,
        @ViewBuilder innerContent: @escaping () -> InnerContent
    ) {
        self._value = value
        self.range = range
        self.angleRange = angleRange
        self.nudgeDegrees = nudgeDegrees
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValueDescription = accessibilityValueDescription
        self.helpText = helpText
        self.colorScheme = colorScheme
        self.innerContent = innerContent
    }

    // Computed, not static let: Swift does not support static stored
    // properties on a generic type.
    private static var diameter: CGFloat { 52 }
    private static var ringRadius: CGFloat { 25 }
    private static var dotCount: Int { 32 }
    private static var dotDiameter: CGFloat { 1.6 }
    private static var innerDiameter: CGFloat { 36 }
    private static var indicatorWidth: CGFloat { 5 }
    private static var indicatorHeight: CGFloat { 9 }

    private var angleDegrees: Double {
        Self.angleDegrees(forValue: value, range: range, angleRange: angleRange)
    }

    private var ringColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.28)
    }
    private var innerFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }
    private var innerStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.14)
    }
    private var indicatorColor: Color {
        colorScheme == .dark ? Color.white : Color.black.opacity(0.72)
    }

    var body: some View {
        ZStack {
            ForEach(0..<Self.dotCount, id: \.self) { index in
                Circle()
                    .fill(ringColor)
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                    .offset(y: -Self.ringRadius)
                    .rotationEffect(.degrees(Double(index) / Double(Self.dotCount) * 360))
            }
            Circle()
                .fill(innerFill)
                .frame(width: Self.innerDiameter, height: Self.innerDiameter)
                .overlay(
                    innerContent()
                        .clipShape(Circle())
                        .allowsHitTesting(false)
                )
            Circle()
                .strokeBorder(innerStroke, lineWidth: 1)
                .frame(width: Self.innerDiameter, height: Self.innerDiameter)
            RoundedRectangle(cornerRadius: Self.indicatorWidth / 2, style: .continuous)
                .fill(indicatorColor)
                .frame(width: Self.indicatorWidth, height: Self.indicatorHeight)
                .offset(y: -Self.ringRadius)
                .rotationEffect(.degrees(angleDegrees))
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let center = CGPoint(x: Self.diameter / 2, y: Self.diameter / 2)
                    let vector = CGPoint(x: drag.location.x - center.x, y: drag.location.y - center.y)
                    guard vector.x != 0 || vector.y != 0 else { return }
                    let rawDegrees = atan2(vector.x, -vector.y) * 180 / .pi
                    commit(fromRawDegrees: rawDegrees < 0 ? rawDegrees + 360 : rawDegrees)
                }
        )
        .opacity(isEnabled ? 1 : OrbitControlMetrics.buttonDisabledOpacity)
        // .disabled(_:) does not silence a hand-attached .gesture()/.onKeyPress();
        // commit(_:)'s own isEnabled guard below is what actually stops the write.
        .focusable(isEnabled)
        .focused($isFocused)
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .orbitTooltip(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValueDescription(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func commit(fromRawDegrees rawDegrees: Double) {
        commit(Self.value(fromRawDegrees: rawDegrees, range: range, angleRange: angleRange))
    }

    static func value(fromRawDegrees rawDegrees: Double, range: ClosedRange<Double>, angleRange: ClosedRange<Double>) -> Double {
        var normalized = rawDegrees
        if angleRange.lowerBound < 0, normalized > 180 {
            normalized -= 360
        }
        let clampedDegrees = min(max(normalized, angleRange.lowerBound), angleRange.upperBound)
        let angleSpan = angleRange.upperBound - angleRange.lowerBound
        let angleFraction = angleSpan > 0 ? (clampedDegrees - angleRange.lowerBound) / angleSpan : 0
        let raw = range.lowerBound + angleFraction * (range.upperBound - range.lowerBound)
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    static func angleDegrees(forValue value: Double, range: ClosedRange<Double>, angleRange: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
        return angleRange.lowerBound + fraction * (angleRange.upperBound - angleRange.lowerBound)
    }

    private func commit(_ newValue: Double) {
        guard isEnabled else { return }
        value = min(max(newValue, range.lowerBound), range.upperBound)
    }

    private func nudge(_ direction: Double) {
        let angleSpan = angleRange.upperBound - angleRange.lowerBound
        let rangeSpan = range.upperBound - range.lowerBound
        let valuePerDegree = angleSpan > 0 ? rangeSpan / angleSpan : 0
        commit(value + direction * nudgeDegrees * valuePerDegree)
    }
}

extension ThemeRotaryDial where InnerContent == EmptyView {
    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        angleRange: ClosedRange<Double>,
        nudgeDegrees: Double = 5,
        accessibilityLabel: String,
        accessibilityValueDescription: @escaping (Double) -> String,
        helpText: String,
        colorScheme: ColorScheme
    ) {
        self.init(
            value: value,
            range: range,
            angleRange: angleRange,
            nudgeDegrees: nudgeDegrees,
            accessibilityLabel: accessibilityLabel,
            accessibilityValueDescription: accessibilityValueDescription,
            helpText: helpText,
            colorScheme: colorScheme,
            innerContent: { EmptyView() }
        )
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 20) {
        ThemeRotaryDial(
            value: .constant(45),
            range: 0...360,
            angleRange: 0...360,
            accessibilityLabel: "Rotation",
            accessibilityValueDescription: { "\(Int($0)) degrees" },
            helpText: "Gradient rotation",
            colorScheme: .dark
        )
        ThemeRotaryDial(
            value: .constant(0.3),
            range: 0...1,
            angleRange: -135...135,
            accessibilityLabel: "Softness",
            accessibilityValueDescription: { "\(Int($0 * 100))%" },
            helpText: "Background softness",
            colorScheme: .dark
        )
    }
    .padding()
    .background(Color.black)
}
#endif
