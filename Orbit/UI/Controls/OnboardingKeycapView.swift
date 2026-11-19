import SwiftUI

private enum OnboardingKeycapMetrics {
    static let faceHeight: CGFloat = 30
    static let edgeDepth: CGFloat = 3
    static let minWidth: CGFloat = 30
}

struct OnboardingKeycapView: View {
    let cap: OnboardingKeycap
    let isPressed: Bool

    private let faceHeight = OnboardingKeycapMetrics.faceHeight
    private let edgeDepth = OnboardingKeycapMetrics.edgeDepth

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous)
        ZStack(alignment: .top) {
            shape
                .fill(Color.black.opacity(0.35))
                .frame(height: faceHeight)
                .offset(y: edgeDepth)
            shape
                .fill(isPressed ? OrbitNeutral.chipStrong : OrbitNeutral.raised)
                .overlay(shape.fill(OrbitNeutral.chip))
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                )
                .overlay(shape.strokeBorder(OrbitNeutral.line, lineWidth: 0.5))
                .frame(height: faceHeight)
                .overlay(
                    Text(cap.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OrbitNeutral.ink)
                        .padding(.horizontal, 8)
                )
                .offset(y: isPressed ? edgeDepth - 1 : 0)
        }
        .frame(minWidth: OnboardingKeycapMetrics.minWidth, idealHeight: faceHeight + edgeDepth)
        .fixedSize()
        .orbitAnimation(OrbitMotion.quick, value: isPressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cap.spokenName)
    }
}

struct OnboardingKeycapPlaceholderView: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OrbitRadius.md, style: .continuous)
        ZStack(alignment: .top) {
            shape
                .strokeBorder(OrbitNeutral.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: OnboardingKeycapMetrics.faceHeight)
        }
        .frame(
            minWidth: OnboardingKeycapMetrics.minWidth,
            idealHeight: OnboardingKeycapMetrics.faceHeight + OnboardingKeycapMetrics.edgeDepth
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No shortcut")
    }
}
