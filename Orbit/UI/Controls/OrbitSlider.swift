import SwiftUI

struct OrbitSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    /// nil means continuous; otherwise rounds committed values to a multiple of step.
    var step: Double? = nil
    var accessibilityLabel: String
    var accentColor: Color = .accentColor

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, OrbitControlMetrics.sliderKnobDiameter)
            let usableWidth = width - OrbitControlMetrics.sliderKnobDiameter
            let knobX = OrbitControlMetrics.sliderKnobDiameter / 2 + CGFloat(fraction) * usableWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(OrbitControlColor.fill(for: colorScheme))
                    .frame(height: OrbitControlMetrics.sliderTrackHeight)

                Capsule()
                    .fill(accentColor.opacity(0.85))
                    .frame(width: max(knobX, OrbitControlMetrics.sliderKnobDiameter / 2), height: OrbitControlMetrics.sliderTrackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: OrbitControlMetrics.sliderKnobDiameter, height: OrbitControlMetrics.sliderKnobDiameter)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .overlay(
                        Circle().strokeBorder(isFocused ? accentColor.opacity(0.9) : .clear, lineWidth: OrbitControlMetrics.sliderFocusRingWidth)
                            .padding(-2)
                    )
                    .position(x: knobX, y: OrbitControlMetrics.sliderTrackHeight / 2)
            }
            .frame(height: OrbitControlMetrics.sliderKnobDiameter)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedX = min(max(drag.location.x - OrbitControlMetrics.sliderKnobDiameter / 2, 0), usableWidth)
                        let newFraction = usableWidth > 0 ? clampedX / usableWidth : 0
                        commit(range.lowerBound + newFraction * (range.upperBound - range.lowerBound))
                    }
            )
        }
        .frame(height: OrbitControlMetrics.sliderKnobDiameter)
        .opacity(isEnabled ? 1 : OrbitControlMetrics.buttonDisabledOpacity)
        .focusable(true)
        .focused($isFocused)
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func commit(_ newValue: Double) {
        var clamped = min(max(newValue, range.lowerBound), range.upperBound)
        if let step, step > 0 {
            clamped = (clamped / step).rounded() * step
            clamped = min(max(clamped, range.lowerBound), range.upperBound)
        }
        value = clamped
    }

    private func nudge(_ direction: Double) {
        let increment = step ?? (range.upperBound - range.lowerBound) / 20
        commit(value + direction * increment)
    }
}

#if DEBUG
#Preview {
    OrbitSlider(value: .constant(0.4), accessibilityLabel: "Grain")
        .padding()
        .frame(width: 220)
}
#endif
