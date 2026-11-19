import SwiftUI

// Surfaces use OrbitNeutral; every shadow is neutral black.


enum OnboardingButtonVariant {
    case primary
    case raised
    case plain
}

struct OnboardingButtonStyle: ButtonStyle {
    var variant: OnboardingButtonVariant = .primary

    func makeBody(configuration: Configuration) -> some View {
        OnboardingButtonBody(configuration: configuration, variant: variant)
    }
}

private struct OnboardingButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: OnboardingButtonVariant

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var isPressed: Bool { configuration.isPressed }

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: variant == .plain ? .regular : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, variant == .plain ? 10 : 16)
            .padding(.vertical, 7)
            .background(background)
            .overlay(bevel)
            .offset(y: isPressed && variant != .plain ? 1 : 0)
            .shadow(
                color: variant == .plain ? .clear : .black.opacity(isPressed ? 0.18 : 0.30),
                radius: isPressed ? 0.5 : 2,
                x: 0,
                y: isPressed ? 0.5 : 2
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .orbitAnimation(OrbitMotion.quick, value: isPressed)
            .orbitAnimation(OrbitMotion.fade, value: isHovering)
    }

    private var foreground: Color {
        switch variant {
        case .primary: OrbitNeutral.card
        case .raised: OrbitNeutral.ink
        case .plain: isHovering ? OrbitNeutral.ink : OrbitNeutral.muted
        }
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .primary:
            Capsule().fill(
                LinearGradient(
                    colors: [OrbitNeutral.ink, OrbitNeutral.ink.opacity(0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .brightness(isHovering && isEnabled ? (colorScheme == .dark ? -0.04 : 0.08) : 0)
        case .raised:
            Capsule().fill(isHovering ? OrbitNeutral.chipStrong : OrbitNeutral.chip)
        case .plain:
            Capsule().fill(isPressed ? OrbitNeutral.chipStrong : (isHovering ? OrbitNeutral.chip : .clear))
        }
    }

    // Inset top highlight plus a hairline: the bevel. Plain buttons carry neither.
    @ViewBuilder
    private var bevel: some View {
        if variant != .plain {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(variant == .primary ? (colorScheme == .dark ? 0.9 : 0.22) : 0.10),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 1
                )
            Capsule()
                .strokeBorder(variant == .primary ? Color.black.opacity(0.4) : OrbitNeutral.line, lineWidth: 0.5)
        }
    }
}


/// Falls back to a horizontal scroll when the column is too narrow for every pill, so the rail never clips.
struct OnboardingStepRail: View {
    let state: OnboardingFlowState
    var onSelect: ((OnboardingStep) -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            pills
            ScrollView(.horizontal, showsIndicators: false) { pills }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup steps")
    }

    private var pills: some View {
        HStack(spacing: 4) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                pill(step)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func pill(_ step: OnboardingStep) -> some View {
        let status = state.status(of: step)
        let label = Text(step.title)
            .font(.system(size: 11.5, weight: status == .current ? .semibold : .regular))
            .foregroundStyle(foreground(for: status))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(status == .current ? OrbitNeutral.accent : .clear))
            .orbitAnimation(OrbitMotion.dramatic, value: status)
        if status == .done, !state.isBusy, let onSelect {
            Button { onSelect(step) } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to \(step.title)")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.title)
                .accessibilityValue(accessibilityValue(for: status))
        }
    }

    private func foreground(for status: OnboardingRailStatus) -> Color {
        switch status {
        case .current: OrbitNeutral.onAccent
        case .done: OrbitNeutral.muted
        case .upcoming: OrbitNeutral.muted2
        }
    }

    private func accessibilityValue(for status: OnboardingRailStatus) -> String {
        switch status {
        case .current: "Current step"
        case .done: "Done"
        case .upcoming: "Not yet"
        }
    }
}


struct OnboardingHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(OrbitNeutral.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
