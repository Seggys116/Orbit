import SwiftUI

struct OrbitSecureField: View {
    var placeholder: String
    @Binding var text: String
    var systemImage: String? = nil
    var accentColor: Color = .accentColor
    var accessibilityLabel: String? = nil
    var externalFocus: FocusState<Bool>.Binding? = nil

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var internalFocus: Bool

    private var isFocused: Bool { externalFocus?.wrappedValue ?? internalFocus }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: OrbitControlMetrics.textFieldIconSize))
                    .foregroundStyle(OrbitControlColor.secondaryForeground(for: colorScheme))
            }
            Group {
                if let externalFocus {
                    SecureField(placeholder, text: $text).focused(externalFocus)
                } else {
                    SecureField(placeholder, text: $text).focused($internalFocus)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: OrbitControlMetrics.textFieldFontSize))
            .foregroundStyle(OrbitControlColor.primaryForeground(for: colorScheme))
        }
        .padding(.horizontal, OrbitControlMetrics.textFieldHorizontalPadding)
        .frame(height: OrbitControlMetrics.textFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.textFieldCornerRadius, style: .continuous)
                .fill(OrbitControlColor.fill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrbitControlMetrics.textFieldCornerRadius, style: .continuous)
                .strokeBorder(isFocused ? accentColor.opacity(0.9) : OrbitControlColor.border(for: colorScheme), lineWidth: isFocused ? OrbitControlMetrics.textFieldFocusRingWidth : 1)
        )
        .animation(OrbitMotion.quick, value: isFocused)
        .accessibilityLabel(accessibilityLabel ?? placeholder)
        // Deliberately no .accessibilityValue(text): would read the secret back out via VoiceOver.
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        OrbitSecureField(placeholder: "sk-…", text: .constant(""), accessibilityLabel: "API key")
        OrbitSecureField(placeholder: "sk-…", text: .constant("sk-abc123"), accessibilityLabel: "API key")
    }
    .padding()
    .frame(width: 280)
}
#endif
