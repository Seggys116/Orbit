import SwiftUI

struct OrbitToggle: View {
    var accessibilityLabel: String
    @Binding var isOn: Bool
    var accentColor: Color = .accentColor
    var isCompact: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    private var width: CGFloat { isCompact ? OrbitControlMetrics.toggleCompactWidth : OrbitControlMetrics.toggleWidth }
    private var height: CGFloat { isCompact ? OrbitControlMetrics.toggleCompactHeight : OrbitControlMetrics.toggleHeight }
    private var knobDiameter: CGFloat { height - OrbitControlMetrics.toggleKnobPadding * 2 }

    var body: some View {
        Button {
            withAnimation(OrbitMotion.quick) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(trackFill)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: .black.opacity(OrbitControlMetrics.toggleKnobShadowOpacity), radius: 1.2, y: 0.5)
                    .padding(OrbitControlMetrics.toggleKnobPadding)
            }
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .strokeBorder(isFocused ? accentColor.opacity(0.85) : .clear, lineWidth: OrbitControlMetrics.textFieldFocusRingWidth)
                    .padding(-2)
            )
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .opacity(isEnabled ? 1 : OrbitControlMetrics.buttonDisabledOpacity)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }

    private var trackFill: Color {
        isOn
            ? accentColor.opacity(OrbitControlMetrics.toggleTrackOnOpacity)
            : (colorScheme == .dark
                ? Color.white.opacity(OrbitControlMetrics.toggleTrackOffOpacityDark)
                : Color.black.opacity(OrbitControlMetrics.toggleTrackOffOpacityLight))
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        OrbitToggle(accessibilityLabel: "Example on", isOn: .constant(true))
        OrbitToggle(accessibilityLabel: "Example off", isOn: .constant(false))
    }
    .padding()
}
#endif
