import SwiftUI

struct OrbitSegmentedControl<Option: Hashable>: View {
    var options: [Option]
    var label: (Option) -> String
    @Binding var selection: Option
    var accessibilityLabel: String
    var accentColor: Color = .accentColor

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var highlightNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(OrbitControlMetrics.segmentedInset)
        .frame(height: OrbitControlMetrics.segmentedHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.segmentedCornerRadius, style: .continuous)
                .fill(OrbitControlColor.fill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.segmentedCornerRadius, style: .continuous)
                .strokeBorder(OrbitControlColor.border(for: colorScheme))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        Button {
            guard !isSelected else { return }
            withAnimation(OrbitMotion.quick) { selection = option }
        } label: {
            Text(label(option))
                .font(.system(size: OrbitControlMetrics.segmentedFontSize, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? OrbitControlColor.primaryForeground(for: colorScheme) : OrbitControlColor.secondaryForeground(for: colorScheme))
                .padding(.horizontal, OrbitControlMetrics.segmentedHorizontalPadding)
                .frame(maxWidth: .infinity)
                .frame(height: OrbitControlMetrics.segmentedHeight - OrbitControlMetrics.segmentedInset * 2)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: OrbitControlMetrics.segmentedCornerRadius - OrbitControlMetrics.segmentedInset, style: .continuous)
                            .fill(accentColor.opacity(0.85))
                            .matchedGeometryEffect(id: "orbitSegmentedSelection", in: highlightNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(option))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#if DEBUG
#Preview {
    OrbitSegmentedControl(
        options: ["Orbit", "System"],
        label: { $0 },
        selection: .constant("Orbit"),
        accessibilityLabel: "Default document app"
    )
    .padding()
    .frame(width: 260)
}
#endif
