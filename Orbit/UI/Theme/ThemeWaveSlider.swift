import SwiftUI

struct ThemeWaveSlider: View {
    @Binding var value: Double
    var colorScheme: ColorScheme

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    private static let height: CGFloat = 48
    private static let thumbWidth: CGFloat = 16
    private static let thumbHeight: CGFloat = 44
    private static let thumbCornerRadius: CGFloat = 8
    private static let nudgeStep: Double = 0.05

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.38)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, Self.thumbWidth)
            let thumbX = min(max(CGFloat(value) * width, Self.thumbWidth / 2), width - Self.thumbWidth / 2)

            ZStack(alignment: .leading) {
                GrainWaveShape(thumbFraction: value)
                    .stroke(trackColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                RoundedRectangle(cornerRadius: Self.thumbCornerRadius, style: .continuous)
                    .fill(Color.white)
                    .frame(width: Self.thumbWidth, height: Self.thumbHeight)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.thumbCornerRadius, style: .continuous)
                            .strokeBorder(isFocused ? Color.accentColor.opacity(0.9) : .clear, lineWidth: 2)
                            .padding(-2)
                    )
                    .position(x: thumbX, y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        commit(Double(drag.location.x / width))
                    }
            )
        }
        .frame(height: Self.height)
        .opacity(isEnabled ? 1 : OrbitControlMetrics.buttonDisabledOpacity)
        .focusable(isEnabled)
        .focused($isFocused)
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Grain")
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func commit(_ fraction: Double) {
        guard isEnabled else { return }
        value = Self.clampedValue(fraction)
    }

    private func nudge(_ direction: Double) {
        commit(Self.nudgedValue(value, direction: direction))
    }

    static func clampedValue(_ raw: Double) -> Double {
        min(max(raw, 0), 1)
    }

    static func nudgedValue(_ value: Double, direction: Double) -> Double {
        clampedValue(value + direction * nudgeStep)
    }
}

private struct GrainWaveShape: Shape {
    var thumbFraction: Double

    private static let cycles: CGFloat = 4.5
    private static let leftAmplitude: CGFloat = 15
    private static let rightAmplitude: CGFloat = 4
    private static let transitionWidth: CGFloat = 30
    private static let sampleCount = 160

    var animatableData: Double {
        get { thumbFraction }
        set { thumbFraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 else { return path }
        let thumbX = CGFloat(thumbFraction) * rect.width

        for step in 0...Self.sampleCount {
            let fraction = CGFloat(step) / CGFloat(Self.sampleCount)
            let x = fraction * rect.width

            let normalized = min(max((x - thumbX) / Self.transitionWidth, -1), 1)
            let blend = (normalized + 1) / 2
            let smoothed = blend * blend * (3 - 2 * blend)
            let amplitude = Self.leftAmplitude + (Self.rightAmplitude - Self.leftAmplitude) * smoothed

            let y = rect.midY + amplitude * sin(fraction * Self.cycles * 2 * .pi)
            let point = CGPoint(x: x, y: y)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

#if DEBUG
#Preview {
    ThemeWaveSlider(value: .constant(0.35), colorScheme: .dark)
        .padding()
        .frame(width: 320)
        .background(Color.black)
}
#endif
